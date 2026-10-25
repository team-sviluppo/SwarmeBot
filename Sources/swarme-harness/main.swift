// swarme-harness — the Swift engine, on the same port, data dir and HTTP
// contract as `node server/index.ts`. Started by the app's HarnessLauncher
// when Settings › Engine is Swift; runnable by hand for development:
//
//   OMB_PORT=8799 OMB_DATA_DIR=/tmp/swarme swift run swarme-harness
import Foundation
import HarnessCore
import HarnessDrivers

#if !canImport(Darwin)
// Linux has no per-descriptor SO_NOSIGPIPE: a peer hanging up must be an
// EPIPE, never a signal that kills the engine or a proxy (POSIXCompat.swift)
signal(SIGPIPE, SIG_IGN)
#endif

// `swarme-harness mcp-permission <socket>`: the MCP permission proxy a CLI
// spawns for --permission-prompt-tool (PermissionProxy.swift). Checked
// first, so the helper never touches the data dir or the port.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "mcp-permission" {
    PermissionProxy.run(socketPath: CommandLine.arguments[2])
}
// `swarme-harness mcp-agents`: peer comms tools for a bot's CLI (AgentsProxy.swift)
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "mcp-agents" {
    AgentsProxy.run()
}
// `swarme-harness mcp-connector <id>`: a connector for a bot's CLI (ConnectorProxy.swift)
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "mcp-connector" {
    ConnectorProxy.run(connector: CommandLine.arguments[2])
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "mcp-container" {
    McpBridge.runContainer(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "mcp-vps" {
    McpBridge.runVPS(Array(CommandLine.arguments.dropFirst(2)))
}
// `swarme-harness mcp-secrets`: the vault's run_with_secrets for a bot's CLI (SecretsProxy.swift)
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "mcp-secrets" {
    SecretsProxy.run()
}

let env = ProcessInfo.processInfo.environment
let port = UInt16(env["OMB_PORT"] ?? env["OGB_PORT"] ?? "8799") ?? 8799
let paths = DataPaths.fromEnvironment(env)

setvbuf(stdout, nil, _IOLBF, 0)

// the remote engine and its device tokens (Remote.swift)
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "device" {
    runDeviceCommand(Array(CommandLine.arguments.dropFirst(2)), paths: paths)
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "secret" {
    MainActor.assumeIsolated { runSecretCommand(Array(CommandLine.arguments.dropFirst(2)), paths: paths) }
}
// the vault of a remote engine, written over ssh by the Mac that administers it (VaultCommand.swift)
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "vault" {
    runVaultCommand(Array(CommandLine.arguments.dropFirst(2)), paths: paths, environment: env)
}
// the push relay for the iOS app, next to a remote engine (PushRelay.swift, PushRelayCommand.swift)
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "push-relay" {
    runPushRelayCommand(Array(CommandLine.arguments.dropFirst(2)), paths: paths, environment: env)
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "serve" {
    let rest = Array(CommandLine.arguments.dropFirst(2))
    guard rest.contains("--remote") else { fail("serve needs --remote (the local engine starts without arguments)") }
    let options: RemoteOptions
    do { options = try RemoteOptions.parse(rest) } catch { fail(error.localizedDescription) }
    Task { @MainActor in await bootRemote(options, paths: paths, environment: env) }
    dispatchMain()
}

@MainActor
func boot() async {
    do {
        let harness = try Harness(paths: paths, environment: env, drivers: HarnessDrivers.all)
        await harness.boot()
        let routes = Routes(harness: harness)
        let server = HTTPServer { request in await routes.handle(request) }
        try await server.start(port: port)
        harness.harnessURL = "http://127.0.0.1:\(port)"
        // webhook deliveries get their own loopback listener, never the control API
        let webhookPort = UInt16(env["OMB_WEBHOOK_PORT"] ?? "8800") ?? 8800
        harness.webhookIngressBaseUrl = "http://127.0.0.1:\(webhookPort)"
        let ingress = HTTPServer { request in WebhookIngress.handle(request, manager: harness.webhooks) }
        ingress.maxBody = 1024 * 1024 // the 256 KiB limit answers with its own message
        do {
            try await ingress.start(port: webhookPort)
            print("swarmebot webhook receiver on \(harness.webhookIngressBaseUrl)")
        } catch {
            harness.webhookIngressError = error.localizedDescription
            FileHandle.standardError.write(Data("swarmebot webhook receiver unavailable: \(error.localizedDescription)\n".utf8))
        }
        print("swarmebot server on http://127.0.0.1:\(port) (swift engine, data \(paths.root.path))")

        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    await harness.shutdown()
                    server.stop()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
        keepAlive = (harness, routes, server, ingress)
    } catch {
        FileHandle.standardError.write(Data("swarme-harness: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
nonisolated(unsafe) var keepAlive: Any?

Task { @MainActor in await boot() }
dispatchMain()
