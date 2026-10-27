// swarme-push-relay [--port 8920 | --socket <path>]
//
// Environment: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, SNS_APNS_APP_ARN and/or
// SNS_APNS_SANDBOX_APP_ARN, RELAY_SECRET (≥ 32 bytes), optional SNS_ENDPOINT,
// RELAY_HOURLY_LIMIT, RELAY_REGISTER_LIMIT. Listens on loopback or a unix
// socket only: put an HTTPS proxy (Caddy) in front, like the remote engine.
// The same relay runs as `swarme-harness push-relay` (HarnessCore/PushRelay.swift).
import Foundation
import HarnessCore

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("swarme-push-relay: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let config: RelayConfig
do { config = try RelayConfig.fromEnvironment(ProcessInfo.processInfo.environment) } catch { fail(error.localizedDescription) }

nonisolated(unsafe) var relayKeepAlive: Any?

Task { @MainActor in
    let relay = Relay(config: config)
    let server = HTTPServer(gate: { _ in nil }) { request in await relay.handle(request) }
    server.maxBody = 16 * 1024
    do {
        if let socket = option("--socket") {
            try server.start(unixSocket: socket, mode: 0o660)
            print("swarme-push-relay on \(socket)")
        } else {
            let port = try server.startLoopback(port: UInt16(option("--port") ?? "8920") ?? 8920)
            print("swarme-push-relay on http://127.0.0.1:\(port)")
        }
    } catch {
        fail(error.localizedDescription)
    }
    relayKeepAlive = (relay, server)
}
dispatchMain()
