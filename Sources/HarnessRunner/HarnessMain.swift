// The engine's entry point: what `swarme-harness` does, as a library so that an
// executable can pass the plugins it is linked with (docs/plans/2026-10-28-code-mode-t3.md §12).
// Same port, data dir and HTTP contract as ever. Started by the app's
// HarnessLauncher; runnable by hand for development:
//
//   OMB_PORT=8799 OMB_DATA_DIR=/tmp/swarme swift run swarme-harness
//
// It lives next to HarnessDrivers, not in HarnessCore, because it needs the
// drivers and the drivers need the core.
import Foundation
import HarnessCore
import HarnessDrivers

public enum HarnessMain {
    /// Never returns: it serves until the process is told to stop, or does a
    /// subcommand (`device`, `secret`, an MCP helper, a plugin's) and exits.
    public static func run(plugins: [any EnginePlugin] = []) -> Never {
        #if !canImport(Darwin)
        // Linux has no per-descriptor SO_NOSIGPIPE: a peer hanging up must be an
        // EPIPE, never a signal that kills the engine or a proxy (POSIXCompat.swift)
        signal(SIGPIPE, SIG_IGN)
        #endif

        let arguments = CommandLine.arguments
        // `swarme-harness mcp-permission <socket>`: the MCP permission proxy a CLI
        // spawns for --permission-prompt-tool (PermissionProxy.swift). Checked
        // first, so the helper never touches the data dir or the port.
        if arguments.count >= 3, arguments[1] == "mcp-permission" {
            PermissionProxy.run(socketPath: arguments[2])
        }
        // `swarme-harness mcp-agents`: peer comms tools for a bot's CLI (AgentsProxy.swift)
        if arguments.count >= 2, arguments[1] == "mcp-agents" {
            AgentsProxy.run()
        }
        // `swarme-harness mcp-connector <id>`: a connector for a bot's CLI (ConnectorProxy.swift)
        if arguments.count >= 3, arguments[1] == "mcp-connector" {
            ConnectorProxy.run(connector: arguments[2])
        }
        if arguments.count >= 2, arguments[1] == "mcp-container" {
            McpBridge.runContainer(Array(arguments.dropFirst(2)))
        }
        if arguments.count >= 2, arguments[1] == "mcp-vps" {
            McpBridge.runVPS(Array(arguments.dropFirst(2)))
        }
        // `swarme-harness mcp-secrets`: the vault's run_with_secrets for a bot's CLI (SecretsProxy.swift)
        if arguments.count >= 2, arguments[1] == "mcp-secrets" {
            SecretsProxy.run()
        }

        let env = ProcessInfo.processInfo.environment
        let port = UInt16(env["OMB_PORT"] ?? env["OGB_PORT"] ?? "8799") ?? 8799
        let paths = DataPaths.fromEnvironment(env)

        setvbuf(stdout, nil, _IOLBF, 0)

        // the remote engine and its device tokens (Remote.swift)
        if arguments.count >= 2, arguments[1] == "device" {
            runDeviceCommand(Array(arguments.dropFirst(2)), paths: paths)
        }
        if arguments.count >= 2, arguments[1] == "secret" {
            MainActor.assumeIsolated { runSecretCommand(Array(arguments.dropFirst(2)), paths: paths) }
        }
        // the vault of a remote engine, written over ssh by the Mac that administers it (VaultCommand.swift)
        if arguments.count >= 2, arguments[1] == "vault" {
            runVaultCommand(Array(arguments.dropFirst(2)), paths: paths, environment: env)
        }
        // the push relay for the iOS app, next to a remote engine (PushRelay.swift, PushRelayCommand.swift)
        if arguments.count >= 2, arguments[1] == "push-relay" {
            runPushRelayCommand(Array(arguments.dropFirst(2)), paths: paths, environment: env)
        }
        // a plugin's own helper, like the MCP ones above
        if arguments.count >= 2, let command = PluginRegistry.subcommand(arguments[1], in: plugins) {
            command.run(Array(arguments.dropFirst(2)), paths, env)
        }
        if arguments.count >= 2, arguments[1] == "serve" {
            let rest = Array(arguments.dropFirst(2))
            guard rest.contains("--remote") else { fail("serve needs --remote (the local engine starts without arguments)") }
            let options: RemoteOptions
            do { options = try RemoteOptions.parse(rest) } catch { fail(error.localizedDescription) }
            Task { @MainActor in await bootRemote(options, paths: paths, environment: env, plugins: plugins) }
            dispatchMain()
        }

        Task { @MainActor in await boot(port: port, paths: paths, env: env, plugins: plugins) }
        dispatchMain()
    }

    @MainActor
    private static func boot(port: UInt16, paths: DataPaths, env: [String: String], plugins: [any EnginePlugin]) async {
        do {
            let harness = try Harness(paths: paths, environment: env, drivers: HarnessDrivers.all, plugins: plugins)
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
}

nonisolated(unsafe) private var signalSources: [DispatchSourceSignal] = []
nonisolated(unsafe) private var keepAlive: Any?
