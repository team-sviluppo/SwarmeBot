// `swarme-harness push-relay …`: the iOS app's push relay, run by the same
// binary as the remote engine so a server that hosts it installs and updates
// one file (docs/push-relay.md).
//
//   push-relay configure                       {appId, apiKey} on stdin → <data>/push-relay.json (0600)
//   push-relay serve [--port 8920 | --socket <path>]
//
// The keys never go through the engine's secrets: those reach the agents.
import Foundation
import HarnessCore

nonisolated(unsafe) private var relayKeepAlive: Any?

func runPushRelayCommand(_ arguments: [String], paths: DataPaths, environment: [String: String]) -> Never {
    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    switch arguments.first {
    case "configure":
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let body = (try? JSON.parse(input))?.object else { fail("push-relay configure: a JSON object on stdin") }
        do { try RelayConfig.configure(body, paths: paths) } catch { fail(error.localizedDescription) }
        print("relay=configured")
        exit(0)
    case "serve":
        let config: RelayConfig
        do { config = try RelayConfig.load(environment, paths: paths) } catch { fail(error.localizedDescription) }
        signal(SIGPIPE, SIG_IGN)
        Task { @MainActor in
            let relay = Relay(config: config)
            let server = HTTPServer(gate: { _ in nil }) { request in await relay.handle(request) }
            server.maxBody = 16 * 1024
            do {
                if let socket = option("--socket") {
                    try server.start(unixSocket: socket, mode: 0o660)
                    print("swarme push relay on \(socket)")
                } else {
                    let port = try server.startLoopback(port: UInt16(option("--port") ?? "8920") ?? 8920)
                    print("swarme push relay on http://127.0.0.1:\(port)")
                }
            } catch {
                fail(error.localizedDescription)
            }
            relayKeepAlive = (relay, server)
        }
        dispatchMain()
    default:
        fail("usage: swarme-harness push-relay configure | serve [--port n | --socket path]")
    }
}
