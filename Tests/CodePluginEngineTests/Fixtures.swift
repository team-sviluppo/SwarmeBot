@testable import CodePluginEngine
@testable import HarnessCore
import XCTest

func temporaryPaths() -> DataPaths {
    DataPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("code-plugin-\(UUID().uuidString)", isDirectory: true))
}

/// A provider that answers from a script, so that what the plugin asks a model can be tested without one.
@MainActor
final class FakeAdapter: ProviderAdapter {
    let provider: String
    var capabilities = AdapterCapabilities()
    private let emitter = EventEmitter()
    private(set) var received: [SendTurnInput] = []
    private(set) var denied: [String] = []
    /// What the model does with a turn: emit events through `emit`.
    var script: (SendTurnInput, (RuntimeEvent.Body, String?) -> Void) -> Void = { _, _ in }
    var instanceId = "claude"

    init(driverKind: String) { provider = driverKind }

    func sendTurn(_ input: SendTurnInput) async throws -> String {
        received.append(input)
        script(input) { body, requestId in
            self.emitter.emit(RuntimeEvent(provider: self.provider, providerInstanceId: self.instanceId, threadId: input.threadId, requestId: requestId, body))
        }
        return "turn"
    }

    func interruptTurn(threadId: ThreadID) async {}

    func respond(threadId: ThreadID, requestId: String, decision: RequestDecision) async -> RequestOutcome {
        if decision.behavior == "deny" { denied.append(requestId) }
        return .rejected
    }

    func hasSession(threadId: ThreadID) -> Bool { false }
    func stopAll() async {}

    @discardableResult
    func onEvent(_ listener: @escaping RuntimeEventListener) -> () -> Void { emitter.add(listener) }
}

@MainActor
final class FakeInstance: ProviderInstance {
    let instanceId: InstanceID
    let driverKind: String
    let displayName: String? = "Fake"
    let enabled = true
    let models = ModelCatalog(default: "fake-1", options: [ModelOption(id: "fake-1", label: "Fake 1"), ModelOption(id: "fake-2", label: "Fake 2")])
    let adapter: ProviderAdapter

    init(instanceId: InstanceID, driverKind: String, adapter: ProviderAdapter) {
        self.instanceId = instanceId
        self.driverKind = driverKind
        self.adapter = adapter
    }

    func refreshModels() async {}
    func snapshot() async -> ProviderSnapshot { .available(version: "0") }
    func dispose() async {}
}

@MainActor
struct FakeDriver: ProviderDriver {
    let driverKind: String
    let adapter: FakeAdapter
    var displayName: String { "Fake" }
    var access: String { "subscription" }

    func create(_ input: DriverCreateInput) async throws -> ProviderInstance {
        adapter.instanceId = input.instanceId
        return FakeInstance(instanceId: input.instanceId, driverKind: driverKind, adapter: adapter)
    }
}

/// A git repository in a temporary folder, with a bot whose chat works in it.
@MainActor
final class RepoFixture {
    let paths = temporaryPaths()
    let harness: Harness
    let routes: Routes
    let folder: URL
    let threadId: String
    let botId: String

    init(drivers: [ProviderDriver] = [], boot: Bool = false) async throws {
        harness = try Harness(paths: paths, environment: ProcessInfo.processInfo.environment, drivers: drivers, plugins: [CodeEnginePlugin()])
        if boot { await harness.boot() }
        routes = Routes(harness: harness)
        let bot = harness.store.createBot(seedMessages: false)
        threadId = bot["threadId"]!.string!
        botId = bot["id"]!.string!
        folder = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        harness.store.patchBot(botId, ["cwd": .string(folder.path)])
    }

    @discardableResult
    func git(_ args: String..., in directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "user.name=Tester", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
        process.currentDirectoryURL = directory ?? folder
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ name: String, _ text: String) throws {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// `main` with one commit holding a.txt.
    func initRepo() throws {
        try git("init", "-q", "-b", "main")
        try write("a.txt", "one\n")
        try git("add", ".")
        try git("commit", "-qm", "first")
    }

    func call(_ method: String, _ suffix: String, query: [String: String] = [:], body: JSON? = nil) async -> (status: Int, json: JSON?) {
        let request = HTTPRequest(method: method, path: "/api/threads/\(threadId)/\(suffix)", query: query,
                                  headers: body == nil ? [:] : ["content-type": "application/json"], body: body?.data ?? Data())
        guard case let .response(response) = await routes.handle(request) else { return (-1, nil) }
        return (response.status, try? JSON.parse(response.body))
    }

    func callRaw(_ method: String, _ path: String, body: JSON? = nil) async -> (status: Int, json: JSON?) {
        let request = HTTPRequest(method: method, path: path, query: [:], headers: body == nil ? [:] : ["content-type": "application/json"], body: body?.data ?? Data())
        guard case let .response(response) = await routes.handle(request) else { return (-1, nil) }
        return (response.status, try? JSON.parse(response.body))
    }
}
