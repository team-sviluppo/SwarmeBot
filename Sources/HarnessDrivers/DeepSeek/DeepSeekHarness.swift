// DeepSeek Harness — `server/drivers/deepseek-harness/index.ts`, ported.
//
// DSH is a server (default http://127.0.0.1:3080), reached directly or as a
// paired device. A turn is: wait for both downlinks, session.create (or
// resume an existing session id), session.selectModel — which must echo back
// exactly what was asked — then session.prompt in "queue" mode; output then
// arrives as frames on the mux downlink until `turn/end`.
//
// The subtle parts, each one a rule the Node driver learned the hard way:
// - frames that arrive while the prompt request is still in flight belong to
//   this turn but are held until the Host accepts the prompt (`queueing`);
// - frames from before this turn — a replayed terminal, a pending ask the
//   Host replays when mux opens — must never complete or leak into it: asks
//   are held in a bounded, generation-scoped "baseline" until a resume claims
//   them, and a resumed turn first waits (bounded) for them to settle;
// - an interrupt is a local terminal decision: the turn completes now, the
//   Host's own late frames for that host-turn number are ignored;
// - the resume cursor (`dsh1:` + base64url JSON) records whether the persona
//   was delivered, and is persisted only after the persona-bearing prompt
//   was accepted;
// - a lost stream fails running turns after a short grace instead of hanging.
import Foundation
import HarnessCore

public struct DeepSeekHarnessDriver: ProviderDriver {
    public static let kind = "deepseekHarness"
    public let driverKind = DeepSeekHarnessDriver.kind
    public let displayName = "DeepSeek Harness"
    public let access = "custom"

    public init() {}

    public func create(_ input: DriverCreateInput) async throws -> ProviderInstance {
        let config = try DeepSeekHarnessConfig(input.config)
        return try DeepSeekHarnessInstance(input: input, config: config)
    }
}

// MARK: - Turn state

@MainActor
final class Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !opened else { return }
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
final class ResumeBarrier {
    var pending = Set<String>()
    var terminalSeen = false
    private var settled = false
    private var result: Error??
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var timer: Task<Void, Never>?

    init(timeout: TimeInterval) {
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.release(RPCError(message: "DeepSeek Harness resumed turn did not settle"))
        }
    }

    func release(_ error: Error? = nil) {
        guard !settled else { return }
        settled = true
        timer?.cancel()
        result = .some(error)
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    func wait() async throws {
        if let result {
            if let error = result { throw error }
            return
        }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }
}

@MainActor
final class DSHTurn {
    enum Phase { case starting, selecting, resuming, queueing, queued, running }
    let generation = newId()
    let sessionKey: String
    var turnId: String
    var sessionId = ""
    var phase = Phase.starting
    var cancelled = false
    var completed = false
    let ready = Gate()
    let startupSettled = Gate()
    var cancelTask: Task<Void, Never>?
    var resumeBarrier: ResumeBarrier?
    var queueFrames: [JSON] = []
    var queueFrameBytes = 0
    var queueOverflowed = false
    var hostTurn: Int?
    var usage: RuntimeEvent.TokenUsage?

    init(sessionKey: String, turnId: String) {
        self.sessionKey = sessionKey
        self.turnId = turnId
    }
}

// MARK: - Instance

@MainActor
final class DeepSeekHarnessInstance: ProviderInstance, ProviderAdapter {
    static let streamGrace: TimeInterval = 0.75
    static let baselineMaxSessions = 64
    static let baselineMaxFrames = 256
    static let baselineMaxFramesPerSession = 16
    static let baselineMaxBytes = 256_000
    static let baselineMaxBytesPerSession = 32_000
    static let baselineTTL: TimeInterval = 10
    static let resumeBarrierTimeout: TimeInterval = 8
    static let queueMaxFrames = 256
    static let queueMaxBytes = 1_000_000

    let instanceId: InstanceID
    let driverKind = DeepSeekHarnessDriver.kind
    let provider = DeepSeekHarnessDriver.kind
    let displayName: String?
    let enabled: Bool
    private(set) var models = ModelCatalog.empty
    var adapter: ProviderAdapter { self }
    let capabilities: AdapterCapabilities = {
        var capabilities = AdapterCapabilities()
        capabilities.queueing = true
        return capabilities
    }()

    let config: DeepSeekHarnessConfig
    private let client: DSHClient
    private let events = EventEmitter()
    private var catalogUnavailable = false

    private struct SessionRecord {
        var sessionId: String
        var personaDelivered: Bool
    }
    private var sessions: [String: SessionRecord] = [:]
    private var sessionThreads = Set<String>()
    private var sessionOwners: [String: String] = [:]

    private struct BaselineFrame {
        var frame: JSON
        var bytes: Int
        var receivedAt: Date
        var generation: Int
    }
    private var baselineFrames: [String: [BaselineFrame]] = [:]
    private var baselineClaims: [String: (owner: String, frames: [BaselineFrame])] = [:]
    private var muxGeneration = 0
    private var active: [ThreadID: DSHTurn] = [:]
    /// sessions whose host turn was retired locally; nil = interrupted before its number was seen
    private var retiredHostTurns: [String: Int?] = [:]
    private var seenFrames: [String] = []
    private var seenSet = Set<String>()

    private final class PendingApproval {
        let threadId: String, turnId: String, sessionId: String, rpcId: String, approvalId: String, requestId: String
        var inFlight = false, cleanupRequested = false, settled = false
        init(threadId: String, turnId: String, sessionId: String, rpcId: String, approvalId: String, requestId: String) {
            (self.threadId, self.turnId, self.sessionId, self.rpcId, self.approvalId, self.requestId) = (threadId, turnId, sessionId, rpcId, approvalId, requestId)
        }
    }
    private struct QuestionAnswer {
        var selected: [String]
        var custom: String?
    }
    private struct QuestionEntry {
        var key: String
        var hostId: String
        var requestId: String
        var options: [String]
        var multiSelect: Bool
    }
    private final class QuestionBatch {
        let threadId: String, turnId: String, sessionId: String, rpcId: String
        var answers: [String: QuestionAnswer] = [:]
        var entries: [QuestionEntry] = []
        var inFlight = false, cleanupRequested = false, settled = false
        init(threadId: String, turnId: String, sessionId: String, rpcId: String) {
            (self.threadId, self.turnId, self.sessionId, self.rpcId) = (threadId, turnId, sessionId, rpcId)
        }
    }
    private var pendingApprovals: [String: PendingApproval] = [:]
    private var pendingApprovalOrder: [String] = []
    private var pendingQuestions: [String: QuestionBatch] = [:]
    private var pendingQuestionOrder: [String] = []
    private var requestKeysByPublicId: [String: (kind: String, key: String)] = [:]
    private var inFlightResponses: [UUID: Task<Void, Never>] = [:]
    private var streamLossTimer: Task<Void, Never>?
    private var streamHealthy: [DSHClient.StreamKind: Bool] = [.mux: false, .host: false]
    private var lifecycle = 0
    private var stopping = false
    private var disposed = false
    private var stopAllTask: Task<Void, Never>?
    private let requestIdNamespace = newId()
    private var requestIdSequence = 0
    private var unsubscribers: [() -> Void] = []

    init(input: DriverCreateInput, config: DeepSeekHarnessConfig) throws {
        instanceId = input.instanceId
        displayName = input.displayName
        enabled = input.enabled
        self.config = config
        client = try DSHClient(baseUrl: config.baseUrl, transport: config.transport, deviceCookie: config.deviceCookie)
        // generation tracking goes in before either socket can open and replay
        unsubscribers.append(client.subscribeHealth { [weak self] health in self?.onHealth(health) })
        unsubscribers.append(client.subscribe(.mux) { [weak self] frame in self?.handleFrame(frame) })
        unsubscribers.append(client.subscribe(.host) { [weak self] frame in self?.handleFrame(frame) })
    }

    // MARK: Events

    private func emit(_ threadId: String, _ turnId: String, requestId: String? = nil, _ body: RuntimeEvent.Body) {
        events.emit(RuntimeEvent(provider: provider, providerInstanceId: instanceId, threadId: threadId, turnId: turnId, requestId: requestId, body))
    }

    @discardableResult
    func onEvent(_ listener: @escaping RuntimeEventListener) -> () -> Void { events.add(listener) }

    // MARK: Catalog and health

    func refreshModels() async {
        do {
            let value = try await client.unary("llm.models", [:])
            guard let catalog = DSHProtocol.flattenCatalog(value).catalog else { throw RPCError(message: "catalog invalid") }
            models = catalog
            catalogUnavailable = false
        } catch {
            models = .empty
            catalogUnavailable = true
        }
    }

    func snapshot() async -> ProviderSnapshot {
        do {
            let value = try await client.unary("host.describe", [:])
            if models.options.isEmpty { await refreshModels() }
            if catalogUnavailable || models.options.isEmpty { return .unavailable("DeepSeek Harness model catalog is unavailable") }
            let version = value["version"]?.string.flatMap { $0.count <= 200 ? $0 : nil }
            return ProviderSnapshot(state: "available", reason: nil, authenticated: true, version: version, billing: nil)
        } catch {
            return .unavailable("DeepSeek Harness host is unavailable")
        }
    }

    // MARK: Helpers

    static func text(_ value: JSON?, _ limit: Int = 4_000) -> String {
        guard let text = value?.string, text.count <= limit else { return "" }
        return text
    }

    static func usage(_ value: JSON?) -> RuntimeEvent.TokenUsage? {
        guard let input = value?["inputTokens"]?.double, let output = value?["outputTokens"]?.double,
              input >= 0, output >= 0, input == input.rounded(), output == output.rounded(),
              input <= 9_007_199_254_740_991, output <= 9_007_199_254_740_991 else { return nil }
        return .init(input: input, output: output)
    }

    static func hostTurn(_ value: JSON?) -> Int? {
        guard let number = value?.double, number == number.rounded(), number > 0, number <= 9_007_199_254_740_991 else { return nil }
        return Int(number)
    }

    static let turnScopedMethods: Set<String> = [
        "turn/start", "turn/end", "assistant/chunk", "assistant/chunk.text-delta", "assistant/chunk.reasoning-delta",
        "assistant/message", "tool/call", "tool/result",
    ]

    private func retireHostTurn(_ running: DSHTurn) {
        guard !running.sessionId.isEmpty else { return }
        let previous = retiredHostTurns[running.sessionId]
        if let hostTurn = running.hostTurn {
            if let previous = previous, let previousTurn = previous { retiredHostTurns[running.sessionId] = max(previousTurn, hostTurn) }
            else { retiredHostTurns[running.sessionId] = .some(hostTurn) }
        } else if previous == nil {
            retiredHostTurns[running.sessionId] = .some(nil)
        }
    }

    private func activeForSession(_ sessionId: String) -> (threadId: String, running: DSHTurn)? {
        guard let sessionKey = sessionOwners[sessionId] else { return nil }
        for (threadId, running) in active where running.sessionKey == sessionKey && running.sessionId == sessionId {
            return (threadId, running)
        }
        return nil
    }

    private func requestKey(_ threadId: String, _ sessionId: String, _ requestId: String) -> String {
        "\(threadId)\u{0}\(sessionId)\u{0}\(requestId)"
    }

    private func publicRequestId(_ kind: String) -> String {
        requestIdSequence += 1
        return "\(kind):\(requestIdNamespace):\(requestIdSequence)"
    }

    static func frameBytes(_ frame: JSON) -> Int { frame.serialized().utf8.count }

    // MARK: Baseline (asks replayed before a resume claims them)

    private func clearUnclaimedBaseline() { baselineFrames.removeAll() }

    private var baselineFrameCount: Int { baselineFrames.values.reduce(0) { $0 + $1.count } }
    private var baselineByteCount: Int { baselineFrames.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.bytes } } }

    private func pruneBaseline(now: Date = Date()) {
        for (sessionId, frames) in baselineFrames {
            let kept = frames.filter { $0.generation == muxGeneration && now.timeIntervalSince($0.receivedAt) <= Self.baselineTTL }
            if kept.count == frames.count { continue }
            baselineFrames[sessionId] = kept.isEmpty ? nil : kept
        }
        while baselineFrames.count > Self.baselineMaxSessions || baselineFrameCount > Self.baselineMaxFrames || baselineByteCount > Self.baselineMaxBytes {
            guard let oldest = baselineFrames.min(by: { $0.value[0].receivedAt < $1.value[0].receivedAt }) else { break }
            baselineFrames[oldest.key] = nil
        }
    }

    private func bufferBaseline(_ sessionId: String, _ frame: JSON) {
        let bytes = Self.frameBytes(frame)
        if bytes > Self.baselineMaxBytesPerSession { return }
        let entry = BaselineFrame(frame: frame, bytes: bytes, receivedAt: Date(), generation: muxGeneration)
        if var claimed = baselineClaims[sessionId] {
            if claimed.frames.contains(where: { $0.frame["rpcId"] == frame["rpcId"] }) { return }
            let claimedBytes = claimed.frames.reduce(0) { $0 + $1.bytes }
            if claimed.frames.count >= Self.baselineMaxFramesPerSession || claimedBytes + bytes > Self.baselineMaxBytesPerSession { return }
            claimed.frames.append(entry)
            baselineClaims[sessionId] = claimed
            return
        }
        pruneBaseline()
        var existing = baselineFrames[sessionId] ?? []
        if existing.count >= Self.baselineMaxFramesPerSession || existing.reduce(0, { $0 + $1.bytes }) + bytes > Self.baselineMaxBytesPerSession { return }
        existing.append(entry)
        baselineFrames[sessionId] = existing
        pruneBaseline()
    }

    private func withdrawBaseline(_ sessionId: String, _ method: String, _ payload: JSON) {
        let claim = baselineClaims[sessionId]
        guard let frames = claim?.frames ?? baselineFrames[sessionId] else { return }
        let kept = frames.filter { entry in
            let candidate = entry.frame["payload"]
            if method == "approval/resolved" {
                return !(entry.frame["method"]?.string == "approval/requested" && Self.text(candidate?["approvalId"], 512) == Self.text(payload["approvalId"], 512))
            }
            return !(entry.frame["method"]?.string == "question/requested" && entry.frame["rpcId"]?.string == Self.text(payload["questionRpcId"], 128))
        }
        if var claim {
            claim.frames = kept
            baselineClaims[sessionId] = claim
            return
        }
        baselineFrames[sessionId] = kept.isEmpty ? nil : kept
    }

    private func claimBaseline(_ sessionId: String, _ generation: String) throws {
        if let claimed = baselineClaims[sessionId] {
            if claimed.owner != generation { throw RPCError(message: "DeepSeek Harness resume is already being claimed") }
            return
        }
        pruneBaseline()
        let frames = baselineFrames.removeValue(forKey: sessionId) ?? []
        baselineClaims[sessionId] = (generation, frames)
    }

    private func takeBaseline(_ sessionId: String, _ generation: String) -> [JSON] {
        guard let claim = baselineClaims[sessionId], claim.owner == generation else { return [] }
        baselineClaims[sessionId] = nil
        return claim.frames.map(\.frame)
    }

    private func releaseBaseline(_ sessionId: String, _ generation: String, drop: Bool) {
        guard let claim = baselineClaims[sessionId], claim.owner == generation else { return }
        baselineClaims[sessionId] = nil
        if !drop, !claim.frames.isEmpty {
            baselineFrames[sessionId] = claim.frames
            pruneBaseline()
        }
    }

    // MARK: Cursor

    func encodeCursor(_ sessionId: String, personaDelivered: Bool) -> String {
        let json: JSON = ["version": 1, "sessionId": .string(sessionId), "personaDelivered": .bool(personaDelivered)]
        return "dsh1:" + Data(json.serialized().utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decodeCursor(_ raw: JSON?) -> (sessionId: String, personaDelivered: Bool)? {
        guard let plain = raw?.string, !plain.isEmpty, plain.count <= 512 else { return nil }
        guard plain.hasPrefix("dsh1:") else { return (plain, false) }
        var base = String(plain.dropFirst(5)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        guard let data = Data(base64Encoded: base), let json = try? JSON.parse(data), let object = json.object,
              Set(object.keys) == ["version", "sessionId", "personaDelivered"], json["version"]?.double == 1,
              let sessionId = json["sessionId"]?.string, !sessionId.isEmpty, sessionId.count <= 512,
              let delivered = json["personaDelivered"]?.bool else { return nil }
        return (sessionId, delivered)
    }

    private func rememberFrame(_ id: String) -> Bool {
        guard seenSet.insert(id).inserted else { return false }
        seenFrames.append(id)
        if seenFrames.count > 4_096 { seenSet.remove(seenFrames.removeFirst()) }
        return true
    }

    private func bufferQueueFrame(_ running: DSHTurn, _ frame: JSON) {
        let bytes = Self.frameBytes(frame)
        if running.queueFrames.count >= Self.queueMaxFrames || running.queueFrameBytes + bytes > Self.queueMaxBytes {
            running.queueOverflowed = true
            return
        }
        running.queueFrames.append(frame)
        running.queueFrameBytes += bytes
    }

    private func isCurrent(_ threadId: String, _ running: DSHTurn, fence: Int? = nil) -> Bool {
        active[threadId] === running && !running.cancelled && !stopping && !disposed && (fence == nil || fence == lifecycle)
    }

    private func maybeReleaseResumeBarrier(_ running: DSHTurn) {
        if let barrier = running.resumeBarrier, barrier.terminalSeen, barrier.pending.isEmpty { barrier.release() }
    }

    private func settleResumeRequest(_ threadId: String, _ turnId: String, _ token: String) {
        guard let running = active[threadId], running.turnId == turnId, let barrier = running.resumeBarrier else { return }
        barrier.pending.remove(token)
        maybeReleaseResumeBarrier(running)
    }

    private func approvalToken(_ sessionId: String, _ approvalId: String) -> String { "approval\u{0}\(sessionId)\u{0}\(approvalId)" }
    private func questionToken(_ sessionId: String, _ rpcId: String) -> String { "question\u{0}\(sessionId)\u{0}\(rpcId)" }

    private func claimSession(_ sessionKey: String, _ sessionId: String) throws {
        if let owner = sessionOwners[sessionId], owner != sessionKey {
            throw RPCError(message: "DeepSeek Harness session is already active on another thread")
        }
        sessionOwners[sessionId] = sessionKey
    }

    // MARK: Turns

    static func promptText(_ turn: SendTurnInput, firstSession: Bool) -> String {
        guard firstSession, let system = turn.system, !system.isEmpty else { return turn.text }
        return "<swarmebot-persona>\n\(system)\n</swarmebot-persona>\n\n\(turn.text)"
    }

    private func resolveSession(_ turn: SendTurnInput, _ sessionKey: String) async throws -> String {
        if let remembered = sessions[sessionKey] {
            try claimSession(sessionKey, remembered.sessionId)
            sessionThreads.insert(turn.threadId)
            return remembered.sessionId
        }
        let hasCursor = turn.resumeCursor != nil && turn.resumeCursor?.isNull == false
        let cursor = Self.decodeCursor(turn.resumeCursor)
        if hasCursor, cursor == nil { throw RPCError(message: "DeepSeek Harness resume cursor is invalid") }
        let cwd = turn.cwd ?? NSHomeDirectory()
        if let cursor {
            let resumed = try await client.unary("session.create", ["sessionId": .string(cursor.sessionId), "cwd": .string(cwd)])
            guard let sessionId = resumed["sessionId"]?.string, !sessionId.isEmpty, sessionId.count <= 512 else {
                throw RPCError(message: "DeepSeek Harness resume response was invalid")
            }
            try claimSession(sessionKey, sessionId)
            // a cursor proves a host session exists, not that the persona was delivered
            sessions[sessionKey] = SessionRecord(sessionId: sessionId, personaDelivered: cursor.personaDelivered)
            sessionThreads.insert(turn.threadId)
            return sessionId
        }
        var payload: JSONObject = ["cwd": .string(cwd)]
        if let preset = config.agentPreset { payload["agentPreset"] = .string(preset) }
        let created = try await client.unary("session.create", .object(payload))
        guard let sessionId = created["sessionId"]?.string, !sessionId.isEmpty, sessionId.count <= 512 else {
            throw RPCError(message: "DeepSeek Harness did not return a session id")
        }
        try claimSession(sessionKey, sessionId)
        sessions[sessionKey] = SessionRecord(sessionId: sessionId, personaDelivered: false)
        sessionThreads.insert(turn.threadId)
        return sessionId
    }

    private func cancelled() -> RPCError { RPCError(message: "DeepSeek Harness turn was cancelled during startup") }

    func sendTurn(_ turn: SendTurnInput) async throws -> String {
        if stopping || disposed { throw RPCError(message: "DeepSeek Harness provider is stopping") }
        let fence = lifecycle
        let threadId = turn.threadId
        let sessionKey = turn.sessionKey ?? threadId
        let cursor = Self.decodeCursor(turn.resumeCursor)
        guard active[threadId] == nil else { throw RPCError(message: "a turn is already running on this thread") }
        // reserved before the first await: a concurrent turn cannot race session creation
        let running = DSHTurn(sessionKey: sessionKey, turnId: newId())
        let turnId = running.turnId
        active[threadId] = running
        emit(threadId, turnId, .turnStarted)
        do {
            if let cursor { try claimBaseline(cursor.sessionId, running.generation) }
            try await client.waitForStreamsOpen()
            guard isCurrent(threadId, running, fence: fence) else { throw cancelled() }
            let sessionId = try await resolveSession(turn, sessionKey)
            // remembered before the fence so a cancel can still compensate it
            running.sessionId = sessionId
            guard isCurrent(threadId, running, fence: fence) else { throw cancelled() }
            try claimBaseline(sessionId, running.generation)
            running.phase = .selecting
            guard let selection = DSHProtocol.decodeModelId(turn.model ?? models.default) else {
                throw RPCError(message: "DeepSeek Harness requires a valid DSH model selection")
            }
            var select: JSONObject = ["sessionId": .string(sessionId), "provider": .string(selection.provider), "model": .string(selection.model)]
            let effort = turn.effort.map { $0 == "none" ? "off" : $0 }
            if let effort { select["reasoningEffort"] = .string(effort) }
            try await client.waitForStreamsOpen()
            guard isCurrent(threadId, running, fence: fence) else { throw cancelled() }
            let selected = try await client.unary("session.selectModel", .object(select))["selected"]
            // an omitted effort lets the Host pick its default; only one we asked for must round-trip
            if selected?["provider"]?.string != selection.provider || selected?["model"]?.string != selection.model
                || (effort != nil && selected?["reasoningEffort"]?.string != effort) {
                throw RPCError(message: "DeepSeek Harness did not preserve the requested model and effort")
            }
            guard isCurrent(threadId, running, fence: fence) else { throw cancelled() }
            let replayed = takeBaseline(sessionId, running.generation)
            if let cursor, cursor.sessionId != sessionId { releaseBaseline(cursor.sessionId, running.generation, drop: true) }
            if !replayed.isEmpty {
                running.phase = .resuming
                let barrier = ResumeBarrier(timeout: Self.resumeBarrierTimeout)
                running.resumeBarrier = barrier
                for frame in replayed { handleFrame(frame) }
                if barrier.pending.isEmpty { barrier.release() } else {
                    try await barrier.wait()
                    guard isCurrent(threadId, running, fence: fence) else { throw cancelled() }
                }
                running.resumeBarrier = nil
                running.phase = .selecting
            }
            try await client.waitForStreamsOpen()
            guard isCurrent(threadId, running, fence: fence) else { throw cancelled() }
            let personaDelivered = sessions[sessionKey]?.personaDelivered ?? false
            // from here on new session frames belong to this turn, held until the Host accepts
            running.phase = .queueing
            _ = try await client.unary("session.prompt", [
                "sessionId": .string(sessionId), "mode": "queue",
                "content": [["type": "text", "text": .string(Self.promptText(turn, firstSession: !personaDelivered))]],
            ])
            guard isCurrent(threadId, running, fence: fence) else { throw cancelled() }
            if running.queueOverflowed {
                running.queueFrames = []
                running.queueFrameBytes = 0
                running.startupSettled.open()
                await cancelRunning(running)
                throw RPCError(message: "DeepSeek Harness queue submission event buffer overflowed")
            }
            sessions[sessionKey]?.personaDelivered = true
            running.phase = .queued
            // persisted only now: a crash after create/select re-delivers the persona on resume
            emit(threadId, turnId, .sessionStarted(sessionId: sessionId, model: turn.model, resumeCursor: encodeCursor(sessionId, personaDelivered: true)))
            running.ready.open()
            running.startupSettled.open()
            let queued = running.queueFrames
            running.queueFrames = []
            running.queueFrameBytes = 0
            for frame in queued {
                if running.completed { break }
                handleFrame(frame)
            }
            // a stream can drop while the queue response is held: arm the loss path now
            if streamHealthy[.mux] != true || streamHealthy[.host] != true { scheduleStreamFailure() }
            return turnId
        } catch {
            running.resumeBarrier?.release()
            running.resumeBarrier = nil
            running.queueFrames = []
            running.queueFrameBytes = 0
            if let cursor { releaseBaseline(cursor.sessionId, running.generation, drop: true) }
            if !running.sessionId.isEmpty { releaseBaseline(running.sessionId, running.generation, drop: true) }
            await resolvePendingUnavailable(threadId)
            running.ready.open()
            running.startupSettled.open()
            if active[threadId] === running {
                active[threadId] = nil
                if !running.completed {
                    running.completed = true
                    emit(threadId, turnId, .runtimeError(message: "DeepSeek Harness turn could not start", setup: nil))
                    emit(threadId, turnId, .turnCompleted(ok: false, stopReason: "start_failed", cost: nil, denials: nil, usage: nil))
                }
            }
            throw error
        }
    }

    /// Serialized after create/select/queue settle: if queue won the race this
    /// is the compensating cancel; otherwise no empty id or late prompt escapes.
    private func cancelRunning(_ running: DSHTurn) async {
        if let task = running.cancelTask { return await task.value }
        running.cancelled = true
        running.ready.open()
        running.resumeBarrier?.release()
        let task = Task { @MainActor in
            await running.startupSettled.wait()
            if !running.sessionId.isEmpty { _ = try? await self.client.unary("session.cancel", ["sessionId": .string(running.sessionId)]) }
        }
        running.cancelTask = task
        await task.value
    }

    func interruptTurn(threadId: ThreadID) async {
        guard let running = active[threadId], !running.completed else { return }
        // local terminal decision: fence and free the slot before the best-effort Host work
        running.completed = true
        retireHostTurn(running)
        if active[threadId] === running { active[threadId] = nil }
        async let cancel: Void = cancelRunning(running)
        async let cleanup: Void = resolvePendingUnavailable(threadId)
        _ = await (cancel, cleanup)
        emit(threadId, running.turnId, .turnCompleted(ok: true, stopReason: "cancelled", cost: nil, denials: nil, usage: running.usage))
    }

    private func failActiveTurnsForStream() async {
        streamLossTimer = nil
        let lost = active.filter { !$0.value.completed }
        // fence first: the cancel below can still cause a turn/end
        for (threadId, running) in lost {
            running.completed = true
            running.cancelled = true
            running.ready.open()
            if active[threadId] === running { active[threadId] = nil }
        }
        for (_, running) in lost where !running.sessionId.isEmpty {
            _ = try? await client.unary("session.cancel", ["sessionId": .string(running.sessionId)])
        }
        for (threadId, running) in lost {
            emit(threadId, running.turnId, .runtimeError(message: "DeepSeek Harness event stream was lost", setup: nil))
            emit(threadId, running.turnId, .turnCompleted(ok: false, stopReason: "stream_lost", cost: nil, denials: nil, usage: nil))
        }
        await resolvePendingUnavailable(nil)
    }

    private func scheduleStreamFailure() {
        guard streamLossTimer == nil, active.values.contains(where: { $0.phase == .queued || $0.phase == .running }) else { return }
        streamLossTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.streamGrace * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.failActiveTurnsForStream()
        }
    }

    private func recoverStream() {
        if streamHealthy[.mux] == true, streamHealthy[.host] == true {
            streamLossTimer?.cancel()
            streamLossTimer = nil
        }
    }

    private func onHealth(_ health: DSHClient.Health) {
        if health.kind == .mux {
            let changed = health.generation != muxGeneration
            if changed { muxGeneration = health.generation }
            // a lost generation's unclaimed frames go at once, not on the next open
            if !health.connected || changed { clearUnclaimedBaseline() }
        }
        streamHealthy[health.kind] = health.connected
        if health.connected { recoverStream() } else { scheduleStreamFailure() }
    }

    // MARK: Frames

    private func handleFrame(_ frame: JSON) {
        var payload = frame["payload"] ?? .null
        var method = frame["method"]?.string ?? ""
        let rpcId = frame["rpcId"]?.string ?? ""
        if method == "session/event" {
            guard let event = payload["event"], event.object != nil, var data = payload["event"]?["data"]?.object else { return }
            let sessionId = Self.text(payload["sessionId"], 512)
            guard !sessionId.isEmpty else { return }
            method = Self.text(event["type"], 160)
            data["sessionId"] = .string(sessionId)
            payload = .object(data)
        }
        // host-level and session-less by design
        if method == "stream/error" {
            scheduleStreamFailure()
            return
        }
        let sessionId = Self.text(payload["sessionId"], 512)
        guard let current = sessionId.isEmpty ? nil : activeForSession(sessionId) else {
            if !sessionId.isEmpty {
                if method == "approval/requested" || method == "question/requested" { bufferBaseline(sessionId, frame) }
                else if method == "approval/resolved" || method == "question/resolved" { withdrawBaseline(sessionId, method, payload) }
            }
            return
        }
        let threadId = current.threadId, running = current.running
        let turnId = running.turnId
        switch running.phase {
        case .queueing:
            bufferQueueFrame(running, frame)
            return
        case .starting, .selecting:
            if method == "approval/requested" || method == "question/requested" { bufferBaseline(sessionId, frame) }
            else if method == "approval/resolved" || method == "question/resolved" { withdrawBaseline(sessionId, method, payload) }
            // a replayed terminal must never complete the new turn
            return
        case .resuming:
            if method == "turn/end" {
                if let barrier = running.resumeBarrier {
                    barrier.terminalSeen = true
                    maybeReleaseResumeBarrier(running)
                }
                return
            }
            guard ["approval/requested", "approval/resolved", "question/requested", "question/resolved"].contains(method) else { return }
        case .queued, .running:
            break
        }
        let hostTurn = Self.hostTurn(payload["turn"])
        if let retired = retiredHostTurns[sessionId] {
            let replaces = hostTurn != nil && (retired == nil ? method == "turn/start" : hostTurn! > retired!)
            if replaces {
                retiredHostTurns[sessionId] = nil
                running.hostTurn = hostTurn
            } else if Self.turnScopedMethods.contains(method) {
                return
            }
        }
        if let hostTurn {
            if let known = running.hostTurn, known != hostTurn { return }
            running.hostTurn = hostTurn
        }
        guard rememberFrame("\(sessionId)\u{0}\(rpcId)") else { return }

        switch method {
        case "turn/start":
            running.phase = .running
        case "assistant/chunk.text-delta", "assistant/chunk":
            let chunk = payload["chunk"]
            let delta = Self.text(chunk?["text"] ?? payload["delta"], 100_000)
            let kind = Self.text(chunk?["type"], 80)
            if !delta.isEmpty { emit(threadId, turnId, .contentDelta(streamKind: kind == "reasoning-delta" ? "reasoning_text" : "assistant_text", delta: delta)) }
        case "assistant/chunk.reasoning-delta":
            let delta = Self.text(payload["chunk"]?["text"] ?? payload["delta"], 100_000)
            if !delta.isEmpty { emit(threadId, turnId, .contentDelta(streamKind: "reasoning_text", delta: delta)) }
        case "tool/call":
            let itemId = Self.text(payload["callId"], 512)
            guard !itemId.isEmpty else { return }
            let name = Self.text(payload["name"], 200)
            events.emit(RuntimeEvent(provider: provider, providerInstanceId: instanceId, threadId: threadId, turnId: turnId, itemId: itemId,
                                     .itemStarted(itemType: "tool", title: name.isEmpty ? "tool" : name)))
        case "tool/result":
            let itemId = Self.text(payload["message"]?["source"]?["callId"] ?? payload["callId"], 512)
            guard !itemId.isEmpty else { return }
            let first = payload["message"]?["content"]?.array?.first
            let isError = first?["isError"]?.bool == true
            events.emit(RuntimeEvent(provider: provider, providerInstanceId: instanceId, threadId: threadId, turnId: turnId, itemId: itemId,
                                     .toolCompleted(ok: payload["error"] == nil && !isError)))
        case "assistant/message":
            let content = payload["message"]?["content"] ?? payload["content"]
            let text = (content?.array ?? []).reduce("") { combined, block in
                block["type"]?.string == "text" ? combined + Self.text(block["text"], 100_000) : combined
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emit(threadId, turnId, .textCompleted(text: text)) }
            if let usage = Self.usage(payload["usage"]) {
                let input = (running.usage?.input ?? 0) + usage.input
                let output = (running.usage?.output ?? 0) + usage.output
                if input <= 9_007_199_254_740_991, output <= 9_007_199_254_740_991 {
                    running.usage = .init(input: input, output: output)
                    emit(threadId, turnId, .tokenUsage(input: usage.input, output: usage.output))
                }
            }
        case "turn/end":
            guard !running.completed else { return }
            running.completed = true
            let terminal = Self.usage(payload["usage"])
            let usage = terminal ?? running.usage
            if let terminal { emit(threadId, turnId, .tokenUsage(input: terminal.input, output: terminal.output)) }
            if active[threadId] === running { active[threadId] = nil }
            Task { @MainActor in await self.resolvePendingUnavailable(threadId) }
            let reason = Self.text(payload["reason"]?["kind"] ?? payload["reason"], 200)
            emit(threadId, turnId, .turnCompleted(ok: reason.isEmpty || reason == "completed", stopReason: reason.isEmpty ? nil : reason,
                                                 cost: nil, denials: nil, usage: usage))
        case "host/agent-error":
            emit(threadId, turnId, .runtimeError(message: "DeepSeek Harness agent failed", setup: nil))
        case "approval/resolved":
            let approvalId = Self.text(payload["approvalId"], 512)
            let key = requestKey(threadId, sessionId, approvalId)
            guard let approval = pendingApprovals[key] else { return }
            let outcome = Self.text(payload["outcome"], 80)
            approval.settled = true
            removeApproval(key)
            requestKeysByPublicId[approval.requestId] = nil
            emit(threadId, approval.turnId, requestId: approval.requestId,
                 .requestResolved(behavior: outcome == "allowed-once" ? "allow" : "deny", source: "system", approvalScope: nil))
            settleResumeRequest(threadId, approval.turnId, approvalToken(sessionId, approvalId))
        case "question/resolved":
            let questionRpcId = Self.text(payload["questionRpcId"], 128)
            guard !questionRpcId.isEmpty else { return }
            let batches = uniqueBatches().filter { $0.threadId == threadId && $0.sessionId == sessionId && $0.rpcId == questionRpcId }
            for batch in batches {
                batch.settled = true
                for entry in batch.entries {
                    removeQuestion(entry.key)
                    requestKeysByPublicId[entry.requestId] = nil
                    emit(threadId, batch.turnId, requestId: entry.requestId, .requestResolved(behavior: "answer", source: "system", approvalScope: nil))
                }
                settleResumeRequest(threadId, batch.turnId, questionToken(sessionId, questionRpcId))
            }
        case "approval/requested":
            let approvalId = Self.text(payload["approvalId"], 512)
            let key = requestKey(threadId, sessionId, approvalId)
            guard !approvalId.isEmpty, pendingApprovals[key] == nil else { return }
            let publicId = publicRequestId("approval")
            pendingApprovals[key] = PendingApproval(threadId: threadId, turnId: turnId, sessionId: sessionId, rpcId: rpcId,
                                                    approvalId: approvalId, requestId: publicId)
            pendingApprovalOrder.append(key)
            requestKeysByPublicId[publicId] = ("approval", key)
            if running.phase == .resuming { running.resumeBarrier?.pending.insert(approvalToken(sessionId, approvalId)) }
            // the wire allows an empty toolName: keep a marker so it never reads as a question
            let tool = Self.text(payload["toolName"], 200)
            let reason = Self.text(payload["reason"], 500)
            emit(threadId, turnId, requestId: publicId, .requestOpened(requestType: "permission", tool: tool.isEmpty ? "tool" : tool,
                                                                       summary: reason.isEmpty ? "Approval requested" : reason,
                                                                       choices: nil, multiSelect: nil, approvalScope: nil))
        case "question/requested":
            let rows = (payload["questions"]?.array ?? []).filter { $0.object != nil }
            let batch = QuestionBatch(threadId: threadId, turnId: turnId, sessionId: sessionId, rpcId: rpcId)
            for (position, row) in rows.enumerated() {
                guard let id = row["id"]?.string, id.count <= 512 else { continue }
                let publicId = publicRequestId("question")
                let choices = row["options"]?.array.map { $0.compactMap { option -> String? in
                    guard let label = option["label"]?.string, label.count <= 200 else { return nil }
                    return label
                } }
                let key = requestKey(threadId, sessionId, "\(rpcId):\(position)")
                let entry = QuestionEntry(key: key, hostId: id, requestId: publicId, options: choices ?? [], multiSelect: row["multiSelect"]?.bool == true)
                batch.entries.append(entry)
                pendingQuestions[key] = batch
                pendingQuestionOrder.append(key)
                requestKeysByPublicId[publicId] = ("question", key)
                let question = Self.text(row["question"], 500)
                emit(threadId, turnId, requestId: publicId, .requestOpened(
                    requestType: "question", tool: "ask_user", summary: question.isEmpty ? "Question requested" : question,
                    choices: (choices?.isEmpty == false) ? choices : nil, multiSelect: entry.multiSelect ? true : nil, approvalScope: nil
                ))
            }
            if batch.entries.isEmpty { return }
            if running.phase == .resuming { running.resumeBarrier?.pending.insert(questionToken(sessionId, rpcId)) }
        default:
            break
        }
    }

    private func removeApproval(_ key: String) {
        pendingApprovals[key] = nil
        pendingApprovalOrder.removeAll { $0 == key }
    }

    private func removeQuestion(_ key: String) {
        pendingQuestions[key] = nil
        pendingQuestionOrder.removeAll { $0 == key }
    }

    /// Batches in insertion order, each once.
    private func uniqueBatches() -> [QuestionBatch] {
        var seen = Set<ObjectIdentifier>()
        return pendingQuestionOrder.compactMap { pendingQuestions[$0] }.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    // MARK: Answers

    private func respondTracked(_ rpcId: String, _ result: JSON) async throws -> JSON {
        let id = UUID()
        let delivery = Task { @MainActor in try await self.client.respond(rpcId, result: result) }
        inFlightResponses[id] = Task { _ = try? await delivery.value }
        defer { inFlightResponses[id] = nil }
        return try await delivery.value
    }

    func respond(threadId: ThreadID, requestId: String, decision: RequestDecision) async -> RequestOutcome {
        let session = sessions[threadId]
        var routed = requestKeysByPublicId[requestId]
        if routed == nil, let session {
            let key = requestKey(threadId, session.sessionId, requestId)
            if pendingApprovals[key] != nil { routed = ("approval", key) } else if pendingQuestions[key] != nil { routed = ("question", key) }
        }
        let key = routed?.key ?? ""
        if routed?.kind == "approval", let approval = pendingApprovals[key], approval.threadId == threadId {
            if approval.inFlight { return .retryable }
            approval.inFlight = true
            do {
                let receipt = try await respondTracked(approval.rpcId, ["ok": true, "value": [
                    "sessionId": .string(approval.sessionId), "approvalId": .string(approval.approvalId),
                    "outcome": .string(decision.behavior == "allow" ? "allowed-once" : "rejected"),
                ]])
                if approval.settled { return .alreadyResolved }
                if receipt["accepted"]?.bool != true {
                    approval.inFlight = false
                    if approval.cleanupRequested { await resolvePendingUnavailable(threadId) }
                    return approval.cleanupRequested ? .unavailable : .retryable
                }
                // a Host resolved frame can beat the receipt: it owns the only resolution
                if approval.settled || pendingApprovals[key] !== approval { return .alreadyResolved }
                removeApproval(key)
                requestKeysByPublicId[approval.requestId] = nil
                emit(threadId, approval.turnId, requestId: approval.requestId,
                     .requestResolved(behavior: decision.behavior == "allow" ? "allow" : "deny", source: "user", approvalScope: nil))
                settleResumeRequest(threadId, approval.turnId, approvalToken(approval.sessionId, approval.approvalId))
                return decision.behavior == "allow" ? .allowedOnce : .rejected
            } catch {
                if approval.settled { return .alreadyResolved }
                approval.inFlight = false
                if approval.cleanupRequested { await resolvePendingUnavailable(threadId) }
                return approval.cleanupRequested ? .unavailable : .retryable
            }
        }
        guard routed?.kind == "question", let batch = pendingQuestions[key], batch.threadId == threadId else { return .unavailable }
        if batch.inFlight { return .retryable }
        guard let entry = batch.entries.first(where: { $0.key == key }) ?? batch.entries.first(where: { $0.requestId == requestId }) else {
            return .unavailable
        }
        let finish: (JSON, RequestOutcome) async -> RequestOutcome = { result, success in
            batch.inFlight = true
            do {
                let receipt = try await self.respondTracked(batch.rpcId, result)
                if batch.settled { return .alreadyResolved }
                if receipt["accepted"]?.bool != true {
                    batch.inFlight = false
                    if batch.cleanupRequested { await self.resolvePendingUnavailable(threadId) }
                    return batch.cleanupRequested ? .unavailable : .retryable
                }
                if success == .answered, batch.settled || !batch.entries.contains(where: { self.pendingQuestions[$0.key] === batch }) {
                    return .alreadyResolved
                }
                for item in batch.entries {
                    self.removeQuestion(item.key)
                    self.requestKeysByPublicId[item.requestId] = nil
                    self.emit(threadId, batch.turnId, requestId: item.requestId, .requestResolved(behavior: "answer", source: "user", approvalScope: nil))
                }
                self.settleResumeRequest(threadId, batch.turnId, self.questionToken(batch.sessionId, batch.rpcId))
                return success
            } catch {
                if batch.settled { return .alreadyResolved }
                batch.inFlight = false
                if batch.cleanupRequested { await self.resolvePendingUnavailable(threadId) }
                return batch.cleanupRequested ? .unavailable : .retryable
            }
        }
        if decision.behavior != "answer" {
            return await finish(["ok": false, "error": ["code": "cancelled", "message": "Question dismissed by the user", "details": [:]]], .rejected)
        }
        if batch.answers[entry.key] == nil {
            let message = decision.message
            let offered = { (label: String) in entry.options.contains(label) }
            let requested = decision.selected ?? (message.map { offered($0) ? [$0] : [] } ?? [])
            var selected: [String] = []
            for label in requested where offered(label) && !selected.contains(label) { selected.append(label) }
            let rawCustom = decision.custom ?? (message.flatMap { offered($0) ? nil : $0 })
            let custom = rawCustom?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            // single-select: at most the first offered label, and a custom only when no label
            var answer = QuestionAnswer(selected: entry.multiSelect ? selected : Array(selected.prefix(1)))
            if let custom, entry.multiSelect || answer.selected.isEmpty { answer.custom = custom }
            batch.answers[entry.key] = answer
        }
        if batch.answers.count != batch.entries.count { return .answered }
        let answers: [JSON] = batch.entries.map { item in
            let answer = batch.answers[item.key]!
            var row: JSONObject = ["id": .string(item.hostId), "selected": .strings(answer.selected)]
            if let custom = answer.custom { row["custom"] = .string(custom) }
            return .object(row)
        }
        return await finish(["ok": true, "value": ["sessionId": .string(batch.sessionId), "answer": ["answers": .array(answers)]]], .answered)
    }

    private func resolvePendingUnavailable(_ onlyThreadId: String?) async {
        var responses: [Task<Void, Never>] = []
        for key in pendingApprovalOrder {
            guard let approval = pendingApprovals[key], onlyThreadId == nil || approval.threadId == onlyThreadId else { continue }
            if approval.inFlight {
                approval.cleanupRequested = true
                continue
            }
            removeApproval(key)
            approval.settled = true
            requestKeysByPublicId[approval.requestId] = nil
            emit(approval.threadId, approval.turnId, requestId: approval.requestId, .requestResolved(behavior: "deny", source: "unavailable", approvalScope: nil))
            settleResumeRequest(approval.threadId, approval.turnId, approvalToken(approval.sessionId, approval.approvalId))
            let result: JSON = ["ok": true, "value": ["sessionId": .string(approval.sessionId), "approvalId": .string(approval.approvalId), "outcome": "rejected"]]
            responses.append(Task { @MainActor in _ = try? await self.respondTracked(approval.rpcId, result) })
        }
        let all = uniqueBatches()
        for batch in all where (onlyThreadId == nil || batch.threadId == onlyThreadId) && batch.inFlight { batch.cleanupRequested = true }
        let batches = all.filter { (onlyThreadId == nil || $0.threadId == onlyThreadId) && !$0.inFlight }
        for batch in batches { for entry in batch.entries { removeQuestion(entry.key) } }
        for batch in batches {
            batch.settled = true
            for entry in batch.entries {
                requestKeysByPublicId[entry.requestId] = nil
                emit(batch.threadId, batch.turnId, requestId: entry.requestId, .requestResolved(behavior: "answer", source: "unavailable", approvalScope: nil))
            }
            settleResumeRequest(batch.threadId, batch.turnId, questionToken(batch.sessionId, batch.rpcId))
            let result: JSON = ["ok": false, "error": ["code": "cancelled", "message": "SwarmeBot request cleanup", "details": [:]]]
            responses.append(Task { @MainActor in _ = try? await self.respondTracked(batch.rpcId, result) })
        }
        for response in responses { await response.value }
    }

    func hasSession(threadId: ThreadID) -> Bool { sessionThreads.contains(threadId) }

    func stopAll() async {
        if let task = stopAllTask { return await task.value }
        let task = Task { @MainActor in
            stopping = true
            lifecycle += 1
            let turns = Array(active)
            for (_, running) in turns {
                running.cancelled = true
                running.ready.open()
            }
            for approval in pendingApprovals.values { approval.cleanupRequested = true }
            for batch in pendingQuestions.values { batch.cleanupRequested = true }
            client.abortOperations()
            for response in Array(inFlightResponses.values) { await response.value }
            // startup may sit between create/select/prompt; its fences stop late Host calls
            for (_, running) in turns { await cancelRunning(running) }
            for (threadId, running) in turns where active[threadId] === running { active[threadId] = nil }
            await resolvePendingUnavailable(nil)
            sessions.removeAll()
            sessionThreads.removeAll()
            sessionOwners.removeAll()
            retiredHostTurns.removeAll()
            baselineFrames.removeAll()
            baselineClaims.removeAll()
            recoverStream()
            stopping = false
        }
        stopAllTask = task
        await task.value
        stopAllTask = nil
    }

    func dispose() async {
        disposed = true
        stopping = true
        lifecycle += 1
        await stopAll()
        for off in unsubscribers { off() }
        unsubscribers.removeAll()
        client.close()
        events.removeAll()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

