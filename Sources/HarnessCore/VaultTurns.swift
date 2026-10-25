// The vault in a turn (docs/plans/2026-10-25-vault.md V1, V8, V10–V12):
//
// - which of the bot's secrets the turn can use, and how: "safe" ones only
//   through `run_with_secrets` (drivers that mount the engine's MCP helpers),
//   "env" ones in the CLI's environment (drivers that spawn one);
// - a grant per turn, like the connectors': the helper carries it back to
//   `/api/internal/secrets/run`, the engine runs the command with the values
//   and answers with the output masked. The helper never holds a value
//   (Codex copies every MCP server's env into its own process);
// - the paragraph that tells the bot what it has, never a value.
import Foundation

struct SecretsGrant {
    /// The header the helper carries its grant in.
    static let header = "x-secrets-grant"

    var botId: String
    var threadId: String
    var names: Set<String>
    var cwd: String?
    var created: Date
}

/// What a turn gets from the vault. Empty changes nothing.
struct TurnSecrets {
    var server: MCPServer?
    var environment: [String: String] = [:]
    var prompt = ""
}

/// The vault's tool as the drivers mount it.
public enum VaultTool {
    /// The MCP server name: not a connector id a user could pick.
    public static let serverName = "swarmebot_vault"
    public static let toolName = "run_with_secrets"
    /// The longest a command may run.
    public static let maxSeconds = 3600
}

extension Harness {
    /// Drivers without a CLI process of their own: no shell, no secrets.
    static let noShellDrivers: Set<String> = ["grok", "localEndpoint", "deepseekHarness", "boxAgent"]

    func turnSecrets(botId: String, threadId: String, instance: ProviderInstance, cwd: String?, computerKind: String?) -> TurnSecrets {
        turnSecrets(botId: botId, threadId: threadId, driverKind: instance.driverKind, canMount: instance.adapter.capabilities.agentsMcp,
                    cwd: cwd, computerKind: computerKind)
    }

    /// `canMount`: the driver mounts the engine's MCP helpers (`agentsMcp`).
    func turnSecrets(botId: String, threadId: String, driverKind: String, canMount: Bool, cwd: String?, computerKind: String?) -> TurnSecrets {
        vault.reload()
        let (grants, note) = vault.grants(botId: botId)
        guard !grants.isEmpty, !Self.noShellDrivers.contains(driverKind) else { return TurnSecrets() }
        if vault.locked {
            return TurnSecrets(prompt: "The user gave you secrets in the SwarmeBot vault, but the vault is locked on this engine (its key is missing): they cannot be used now. Tell the user if a task needs them.")
        }
        // commands for a VM or a cloud computer would run on the wrong machine (V12)
        if let computerKind, computerKind != "local" {
            return TurnSecrets(prompt: "The user gave you secrets in the SwarmeBot vault, but they are not available while you work on a computer: they only exist on the engine's host.")
        }
        let safe = canMount ? grants.filter { $0.mode == "safe" && vault.value($0.name) != nil } : []
        let env = grants.filter { $0.mode == "env" && vault.value($0.name) != nil }
        let unusable = grants.filter { $0.mode == "safe" && !canMount }
        var turn = TurnSecrets()
        if !safe.isEmpty {
            let grant = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            let stale = Date().addingTimeInterval(-86_400)
            secretsGrants = secretsGrants.filter { $0.value.created > stale }
            secretsGrants[grant] = SecretsGrant(botId: botId, threadId: threadId, names: Set(safe.map(\.name)), cwd: cwd, created: Date())
            turn.server = MCPServer(command: HelperCommand.executable, args: ["mcp-secrets"], env: [
                "OMB_HARNESS_URL": .string(harnessURL), "OMB_COMMS_TOKEN": .string(commsToken),
                "OMB_SECRETS_GRANT": .string(grant), "OMB_SECRETS_NAMES": .string(safe.map(\.name).joined(separator: ",")),
            ])
        }
        turn.environment = vault.environment(for: env.map(\.name))
        turn.prompt = secretsPrompt(safe: safe.map(\.name), env: env.map(\.name), unusable: unusable.map(\.name), note: note)
        return turn
    }

    func secretsPrompt(safe: [String], env: [String], unusable: [String], note: String) -> String {
        guard !(safe.isEmpty && env.isEmpty && unusable.isEmpty) else { return "" }
        let tool = "mcp__\(VaultTool.serverName)__\(VaultTool.toolName)"
        func line(_ name: String) -> String {
            let secret = vault.secret(name) ?? JSONObject()
            var parts = ["- \(name)"]
            let vars = vault.variableNames(name)
            parts.append("(variables: \(vars.map { "$\($0)" }.joined(separator: ", "))\(secret["preset"]?.string == "github" ? "; git is already authenticated for https://github.com" : ""))")
            if let description = secret["description"]?.string, !description.isEmpty { parts.append("— \(description)") }
            if let hint = secret["hint"]?.string, !hint.isEmpty { parts.append("How to use it: \(hint)") }
            return parts.joined(separator: " ")
        }
        var text = ["SECRETS. The user stored secrets for you in the SwarmeBot vault. You never see their values and must never try to: do not print, echo or log them, do not write them to files, URLs or your messages."]
        if !safe.isEmpty {
            text.append("Use these only through the \(VaultTool.toolName) tool (\(tool)): pass the command and the secret names; the engine runs it with `sh -c` in this chat's folder, the variables set, and returns the output with the values masked. Your own shell does NOT have them. Commands are not interactive (stdin is closed) and must not leave processes running in the background.")
            text += safe.map(line)
        }
        if !env.isEmpty {
            text.append("These are already set in your shell's environment for this turn; reference them as variables, never expand them in output:")
            text += env.map(line)
        }
        if !unusable.isEmpty {
            text.append("These were given to you but cannot be used with this engine (no \(VaultTool.toolName) tool): \(unusable.joined(separator: ", ")).")
        }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { text.append("The user's instructions about secrets: \(note)") }
        return text.joined(separator: "\n")
    }

    /// A settled turn's helper has nothing left to run; what it still runs stops.
    func revokeSecretsGrants(threadId: String) {
        guard secretsGrants.values.contains(where: { $0.threadId == threadId }) else { return }
        for (grant, entry) in secretsGrants where entry.threadId == threadId {
            secretsRuns[grant]?.forEach { $0.killTree() }
            secretsRuns[grant] = nil
        }
        secretsGrants = secretsGrants.filter { $0.value.threadId != threadId }
    }

    /// `POST /api/internal/secrets/run` `{command, secrets, timeout_sec}`.
    /// The caller already passed the boot-token check.
    func secretsInternalRoute(_ request: HTTPRequest, body: JSONObject) async -> HTTPResponse {
        guard request.method == "POST", request.path == "/api/internal/secrets/run" else { return .error(404, "not found") }
        let token = request.header(SecretsGrant.header) ?? ""
        guard let grant = secretsGrants[token] else { return .error(403, "this turn has no secrets") }
        let command = body["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else { return .error(400, "command required") }
        let names = body["secrets"]?.array?.compactMap(\.string) ?? []
        if let refused = names.first(where: { !grant.names.contains($0) }) {
            return .error(403, "the secret \(refused) was not given to this bot")
        }
        vault.reload()
        if vault.locked { return .error(409, "the vault is locked: its key is missing on this engine") }
        let timeout = min(max(body["timeout_sec"]?.double ?? 600, 1), Double(VaultTool.maxSeconds))
        var env = Self.commandEnvironment(environment)
        for (key, value) in vault.environment(for: names) { env[key] = value }
        let result = await VaultRunner.run(command: command, environment: env, cwd: grant.cwd, timeout: timeout) { [weak self] process in
            self?.secretsRuns[token, default: []].append(process)
        }
        secretsRuns[token]?.removeAll { $0.hasExited }
        guard let result else { return .error(500, "could not start /bin/sh") }
        return .json(200, [
            "exitCode": result.code.map { .number(Double($0)) } ?? .null,
            "stdout": .string(vault.mask(result.stdout)), "stderr": .string(vault.mask(result.stderr)),
            "timedOut": .bool(result.timedOut), "truncated": .bool(result.truncated),
        ])
    }

    /// The engine's environment without anything that looks like a credential:
    /// a command gets the secrets it asked for and nothing else of ours.
    static func commandEnvironment(_ source: [String: String]) -> [String: String] {
        var env = source.filter { key, _ in
            !Redact.isSecretName(key) && !key.hasPrefix("OMB_") && !key.hasPrefix("OGB_") && !key.hasPrefix("SWARMEBOT_")
        }
        WorkspaceCredentials.strip(&env)
        // the system folders always: `sh -c` without them has no basename, no env
        var path = EnvPath.augmented(source).split(separator: ":").map(String.init)
        for dir in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !path.contains(dir) { path.append(dir) }
        env["PATH"] = path.joined(separator: ":")
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }
}

/// One `sh -c` run: bounded output, whole-tree kill on timeout.
enum VaultRunner {
    struct Result {
        var code: Int32?
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var truncated: Bool
    }

    static let keep = 30_000

    @MainActor
    static func run(command: String, environment: [String: String], cwd: String?, timeout: TimeInterval,
                    started: (CLIProcess) -> Void) async -> Result? {
        let folder = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory()
        guard let process = try? CLIProcess(cli: "/bin/sh", args: ["-c", command], cwd: folder, environment: environment) else { return nil }
        started(process)
        return await withCheckedContinuation { continuation in
            var stdout = "", stderr = ""
            var truncated = false, timedOut = false, finished = false
            // keep the tail: the end of a long build log is what explains it
            func trim(_ text: inout String) {
                guard text.count > keep * 2 else { return }
                text = String(text.suffix(keep))
                truncated = true
            }
            process.onLine = { stdout += $0 + "\n"; trim(&stdout) }
            process.onStderr = { stderr += $0; trim(&stderr) }
            process.onClose = { code in
                guard !finished else { return }
                finished = true
                if stdout.count > keep { stdout = String(stdout.suffix(keep)); truncated = true }
                if stderr.count > keep { stderr = String(stderr.suffix(keep)); truncated = true }
                continuation.resume(returning: Result(code: code, stdout: stdout, stderr: stderr, timedOut: timedOut, truncated: truncated))
            }
            process.closeStdin()
            process.start()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !finished else { return }
                timedOut = true
                process.killTree()
                // something that ignores SIGTERM, or a child still holding the pipes:
                // answer with what came so far rather than hang the tool call
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !finished else { return }
                finished = true
                continuation.resume(returning: Result(code: nil, stdout: String(stdout.suffix(keep)), stderr: String(stderr.suffix(keep)),
                                                      timedOut: true, truncated: truncated))
            }
        }
    }
}
