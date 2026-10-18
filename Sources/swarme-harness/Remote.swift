// The remote engine: `swarme-harness serve --remote …` and `swarme-harness
// device …` — docs/plans/2026-10-16-bot-remoto.md §3–§4.
//
//   serve --remote --socket <path> [--webhook-socket <path>] [--public-url <url>] [--keepalive <s>]
//   device add --name <name> [--kind mac|ios|other]   prints the token once
//   device list
//   device revoke <id>
//
// Three listeners. The public unix socket, behind Caddy, takes device
// tokens and never serves /api/internal. A loopback TCP port on a free
// number serves only /api/internal, for the MCP proxies the CLIs spawn
// (they speak HTTP over URLSession, which cannot dial a unix socket). The
// webhook socket serves only /hooks, authenticated by each hook's secret.
import Foundation
import HarnessCore
import HarnessDrivers

struct RemoteOptions {
    var socket: String
    var webhookSocket: String?
    var publicURL: String?
    var keepalive: UInt64 = 15

    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(_ args: [String]) throws -> RemoteOptions {
        var values: [String: String] = [:]
        var index = 0
        while index < args.count {
            let key = args[index]
            guard key.hasPrefix("--") else { throw Invalid(message: "unexpected argument \(key)") }
            if key == "--remote" { index += 1; continue }
            guard index + 1 < args.count else { throw Invalid(message: "\(key) needs a value") }
            values[String(key.dropFirst(2))] = args[index + 1]
            index += 2
        }
        let known: Set<String> = ["socket", "webhook-socket", "public-url", "keepalive"]
        if let unknown = values.keys.first(where: { !known.contains($0) }) { throw Invalid(message: "unknown option --\(unknown)") }
        guard let socket = values["socket"] else { throw Invalid(message: "--socket is required") }
        var options = RemoteOptions(socket: Self.expand(socket), webhookSocket: values["webhook-socket"].map(Self.expand), publicURL: values["public-url"])
        if let raw = values["keepalive"] {
            guard let seconds = UInt64(raw), (5...120).contains(seconds) else { throw Invalid(message: "--keepalive must be 5…120 seconds") }
            options.keepalive = seconds
        }
        if let url = options.publicURL {
            guard let parsed = URL(string: url), parsed.scheme == "https" || parsed.scheme == "http", parsed.host != nil else {
                throw Invalid(message: "--public-url must be an http(s) URL")
            }
        }
        return options
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}

// not main.swift's globals: those are initialised only when the top-level
// code reaches them, and `serve` never returns before that line
nonisolated(unsafe) var remoteSignalSources: [DispatchSourceSignal] = []
nonisolated(unsafe) var remoteKeepAlive: Any?

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("swarme-harness: \(message)\n".utf8))
    exit(2)
}

/// `swarme-harness device …`, run over ssh on the server (also while the engine runs).
func runDeviceCommand(_ args: [String], paths: DataPaths) -> Never {
    paths.ensure()
    let registry = DeviceRegistry(paths: paths)
    func option(_ name: String) -> String? {
        guard let at = args.firstIndex(of: "--\(name)"), at + 1 < args.count else { return nil }
        return args[at + 1]
    }
    do {
        switch args.first {
        case "add":
            let added = try registry.add(name: option("name"), kind: option("kind"))
            let out: JSON = ["device": .object(DeviceRegistry.wire(added.device)), "token": .string(added.token)]
            print(out.serialized())
        case "list":
            print(JSON.object(["devices": .array(registry.list(includeRevoked: true).map { .object(DeviceRegistry.wire($0)) })]).serialized())
        case "revoke":
            guard args.count >= 2 else { fail("device revoke <id>") }
            guard try registry.revoke(args[1]) else { fail("no such device \(args[1])") }
            print(JSON.object(["ok": true]).serialized())
        default:
            fail("device add --name <name> [--kind mac|ios|other] | device list | device revoke <id>")
        }
    } catch {
        fail(error.localizedDescription)
    }
    exit(0)
}

@MainActor
func bootRemote(_ options: RemoteOptions, paths: DataPaths, environment: [String: String]) async {
    // a client that hangs up mid-write must not kill the engine
    signal(SIGPIPE, SIG_IGN)
    do {
        // 0750: the proxy's group may enter and reach the 0660 socket, nobody else
        for socket in [options.socket] + [options.webhookSocket].compactMap({ $0 }) {
            let dir = (socket as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
        }
        let harness = try Harness(paths: paths, environment: environment, drivers: HarnessDrivers.all)
        await harness.boot()
        let routes = Routes(harness: harness)
        let remote = RemoteAccess(paths: paths, publicURL: options.publicURL)
        harness.hub.keepaliveSeconds = options.keepalive
        harness.hub.proxyFriendly = true
        harness.routines.missedReason = "The engine was offline for more than 12 hours after the scheduled time"
        remote.onRevoke = { [weak harness] device in harness?.hub.close(deviceId: device) }

        // the proxies' door: loopback, boot token, nothing but /api/internal
        let proxies = HTTPServer { request in
            guard request.path.hasPrefix("/api/internal/") else { return .response(.error(404, "not found")) }
            return await routes.handle(request)
        }
        let internalPort = try proxies.startLoopback(port: 0)
        harness.harnessURL = "http://127.0.0.1:\(internalPort)"

        let server = HTTPServer(gate: { request in remote.gate(&request) }) { request in
            if let answer = remote.route(request) { return answer }
            return await routes.handle(request)
        }
        try server.start(unixSocket: options.socket, mode: 0o660)

        var ingress: HTTPServer?
        if let hooks = options.webhookSocket {
            // the proxy's Host is a public name: each hook's secret is the only gate
            let receiver = HTTPServer(gate: { _ in nil }) { request in WebhookIngress.handle(request, manager: harness.webhooks) }
            receiver.maxBody = 1024 * 1024
            do {
                try receiver.start(unixSocket: hooks, mode: 0o660)
                ingress = receiver
                harness.webhookIngressBaseUrl = options.publicURL ?? "unix:\(hooks)"
            } catch {
                harness.webhookIngressError = error.localizedDescription
                FileHandle.standardError.write(Data("swarmebot webhook receiver unavailable: \(error.localizedDescription)\n".utf8))
            }
        } else {
            harness.webhookIngressError = "no webhook socket configured on this remote engine"
        }
        print("swarmebot remote engine on \(options.socket) (internal 127.0.0.1:\(internalPort), data \(paths.root.path))")

        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    await harness.shutdown()
                    server.stop()
                    ingress?.stop()
                    proxies.stop()
                    exit(0)
                }
            }
            source.resume()
            remoteSignalSources.append(source)
        }
        remoteKeepAlive = (harness, routes, remote, server, proxies, ingress as Any)
    } catch {
        FileHandle.standardError.write(Data("swarme-harness: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
