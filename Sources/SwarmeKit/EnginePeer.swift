// The engines the window is not showing, kept live for the sidebar.
//
// The window talks to one engine at a time (AppModel.client); the sidebar
// lists the bots of all of them — this Mac's sections, then one section per
// remote server. Each other engine gets a peer: its own event stream folded
// into a light `CompanionState` (bots, activity, a short tail of each
// transcript for the row preview). Opening one of its chats switches the
// window to that engine.
import CompanionCore
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.swarmebot.mac", category: "peer")

@MainActor
@Observable
public final class EnginePeer {
    public let choice: EngineChoice
    public internal(set) var state: CompanionState
    /// The stream is up; false while connecting or after a failure.
    public internal(set) var reachable = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var client: CompanionClient?

    init(choice: EngineChoice, state: CompanionState = CompanionState(), cursor: String? = nil) {
        self.choice = choice
        self.state = state
        self.cursor = cursor
        reachable = cursor != nil
    }

    /// Bots its sidebar section shows: not hidden, pinned first.
    public var visibleBots: [Bot] {
        let bots = state.bots.filter { $0.hidden != true }
        return bots.filter { $0.pinned == true } + bots.filter { $0.pinned != true }
    }

    public func isBusy(_ bot: Bot) -> Bool {
        bot.busy == true || ["working", "waiting-on-you", "no-signal"].contains(bot.activity ?? "")
    }

    func start(_ client: CompanionClient) {
        guard task == nil else { return }
        self.client = client
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// What the window needs to take this engine over without a blank sidebar.
    var snapshot: (state: CompanionState, cursor: String?) { (state, cursor) }

    private func run() async {
        var delay: UInt64 = 0
        while !Task.isCancelled {
            guard let client else { return }
            do {
                for try await frame in try client.events(since: cursor) {
                    if Task.isCancelled { return }
                    delay = 0
                    if case let .hello(helloCursor, resumed) = frame.frame {
                        if !resumed {
                            state.hydrate(try await client.fleet(messages: 20))
                            cursor = helloCursor
                        }
                        reachable = true
                        continue
                    }
                    if let seq = frame.seq, let cursor, let streamId = cursor.split(separator: ":").first {
                        self.cursor = "\(streamId):\(seq)"
                    }
                    // replies in flight are the shown engine's business
                    if case .runtime = frame.frame { continue }
                    state.apply(frame)
                }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                log.error("peer stream failed: \(error.localizedDescription, privacy: .public)")
            }
            reachable = false
            if Task.isCancelled { return }
            delay = delay == 0 ? 2 : min(delay * 2, 30)
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        }
    }
}
