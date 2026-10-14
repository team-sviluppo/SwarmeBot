// A turn's computer and the Computer panel's routes — the computer half of
// `startTurn` and the `/api/bots/:id/computer*` routes of `server/index.ts`.
//
// Ported: the cloud Box backend (find, provision on first explicit use, wake,
// preview capture, the box-native boxAgent engine), who-is-driving control.
// Not yet: the computer MCP server the local CLIs mount (computer-proxy), the
// Local VM container and the self-hosted VPS backend — a turn that needs one
// fails with a sentence that says so, never by silently running without it.
import Foundation

extension Harness {
    static let computerNotPorted = "non ancora disponibile nel motore Swift — passa al motore Node in Impostazioni › Motore"

    public struct TurnComputer {
        /// box · vps · vm, nil when the turn has none
        var kind: String?
        var boxId: String?
        var capture: (() async throws -> (png: String, format: String))?
        /// The system-prompt sentences for this kind of computer.
        var prompt = ""
        var server: MCPServer?
        /// Set for a computer whose tools must pass the approval broker.
        var scope: String?
    }

    /// `runOn: "cloud"` is how a cloud routine asks for the bot's box; an
    /// ordinary turn only gets the Local VM when the bot chose it.
    func prepareComputer(bot: JSONObject, instance: ProviderInstance, threadId: String, runOn: String?) async throws -> TurnComputer {
        let botId = bot["id"]?.string ?? ""
        let chosen = bot["computer"]?.string
        let wants = runOn == "cloud" ? "cloud" : chosen == "vm" ? "vm" : chosen == "local" ? "local" : "off"
        let backend = runOn == "cloud" || bot["cloudBackend"]?.string != "vps" ? "box" : "vps"
        let mountsComputerMcp = instance.adapter.capabilities.computerMcp
        let boxAgent = instance.driverKind == "boxAgent"
        let mountsCloud = mountsComputerMcp || boxAgent
        var turn = TurnComputer()

        if wants == "local" {
            // Off unless the app was started with the switch on. No daemon,
            // no screen capture, no process, until a turn actually asks.
            guard ProcessInfo.processInfo.environment["OMB_LOCAL_COMPUTER"] == "1" else {
                throw TurnError(status: 409, message: "the Mac computer is off — turn it on in Settings › Motore. It stays off so it does not slow this Mac")
            }
            if !instance.adapter.capabilities.localComputerMcp {
                throw TurnError(status: 409, message: "local computer control requires the interactive approval broker")
            }
            guard let connection = HostComputer.connection() else {
                throw TurnError(status: 409, message: "Cua Driver is not available on this Mac")
            }
            var env = JSONObject()
            for (key, value) in connection.env { env[key] = .string(value) }
            turn.server = MCPServer(command: connection.command, args: connection.args, env: env)
            turn.scope = "local-computer"
            turn.kind = "local"
            turn.prompt += " You are driving this Mac's own desktop, not a sandbox. Inspect before you act, prefer accessibility targets over raw coordinates, and stop at any password, MFA or CAPTCHA so the person can do it. Every action waits for their approval."
        }
        if wants == "vm" {
            if !mountsComputerMcp || boxAgent {
                throw TurnError(status: 409, message: "this model engine cannot use the Local VM — choose Claude or an ACP engine, or select another computer destination")
            }
            if localVM.lifecycleBusy {
                throw TurnError(status: 409, message: "the Local VM is being started, stopped, or replaced — wait for setup to finish")
            }
            let busy = { (botId: String) in Store.isBusy(self.store.bot(botId)) }
            if !localVM.lease.claim(threadId: threadId, botId: botId, busy: busy) {
                throw TurnError(status: 409, message: "the shared Local VM is already being used by another bot — wait for that turn to finish")
            }
            localVM.activeThread = threadId
            localVM.touchIdle()
            let vm = await localVM.status()
            if vm["ready"]?.bool != true || vm["runtime"] == nil || vm["runtime"]?.isNull == true {
                throw TurnError(status: 409, message: "\(vm["problem"]?.string ?? "the Local VM is not ready") (App Settings → Local VM)")
            }
            let control = controlIntegration(botId)
            turn.server = localVM.mcp(runtime: vm["runtime"]?.string ?? "docker", controlURL: control.url, token: control.token)
            turn.kind = "vm"
            turn.prompt += " You have a shared, isolated Cua sandbox: a Linux desktop in a container on this machine. Only /home/cua/workspace is durable; save downloads, repositories, working files, and browser profiles there because everything else inside the VM is disposable. No other host folder is mounted. Use the computer tools for desktop, accessibility, window, and shell work. Inspect the desktop state before acting, prefer accessibility targets over raw coordinates, and work carefully."
        }
        if wants == "cloud", backend == "vps" {
            throw TurnError(status: 409, message: "Il computer VPS è \(Self.computerNotPorted)")
        }
        if wants == "cloud", backend == "box", box.configured {
            if !mountsCloud {
                throw TurnError(status: 409, message: "this model engine cannot use computer tools — choose Claude, an ACP engine, or the Computer engine")
            }
            var found = await box.find(botId)
            // explicit Cloud and the box-native engine provision on first use
            if found == nil {
                broadcast(["kind": "computer", "botId": .string(botId), "state": "provisioning"])
                _ = try await box.provision(botId, botName: bot["name"]?.string ?? "")
                found = await box.find(botId)
            }
            if let current = found, !BoxComputer.ready.contains(current["state"]?.string ?? "") {
                broadcast(["kind": "computer", "botId": .string(botId), "state": "waking"])
                found = await box.readyBox(botId) ?? current
            }
            if let boxId = found?["id"]?.string {
                let box = self.box
                turn.capture = { try await box.screenshot(botId, knownBoxId: boxId) }
                turn.boxId = boxId
                turn.kind = "box"
            }
        }
        if wants == "cloud", backend == "box", !box.configured {
            throw TurnError(status: 409, message: "Cloud box is not configured — add a Box API key or choose Local VM")
        }
        if wants == "cloud", backend == "box", turn.boxId == nil {
            throw TurnError(status: 409, message: "the cloud computer could not be created or reached")
        }
        if turn.kind == "box", !boxAgent {
            turn.prompt += " You have your own cloud computer. In Chrome, prefer browser_snapshot with browser_click/browser_fill for semantic, trusted actions; use screenshot/click/type_text for visual or non-browser UI, open_url for navigation, and computer_exec for Linux tasks. Every action already returns the resulting screen, so don't follow it with screenshot; batch predictable pixel actions with computer_batch."
        }
        if turn.kind != nil {
            turn.prompt += " At a sign-in, password, MFA, CAPTCHA, or other protected-input step, stop and ask the user to complete it on the visible computer. Never type their password or ask them to paste a password or one-time code into chat."
        }
        return turn
    }

    /// The loopback endpoint a computer proxy polls before it acts.
    func controlIntegration(_ botId: String) -> (url: String, token: String) {
        let escaped = botId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? botId
        return ("\(harnessURL)/api/internal/computer-control?botId=\(escaped)", commsToken)
    }

    func localComputerRoute(_ r: HTTPRequest, path: String) async -> HTTPResponse? {
        if r.method == "POST", path == "/api/local-computer/interrupt" {
            let type = r.header("content-type") ?? ""
            if !type.lowercased().hasPrefix("application/json") { return .error(415, "content-type must be application/json") }
            for bot in store.bots where bot["computer"]?.string == "local" {
                let selection = ModelSelection(json: bot["modelSelection"])
                await fleet.get(selection.instanceId)?.adapter.interruptTurn(threadId: bot["threadId"]?.string ?? "")
            }
            return .json(200, ["ok": true])
        }
        if r.method == "GET", path == "/api/local-computer" { return .json(200, .object(await localVM.payload())) }
        guard path.hasPrefix("/api/local-computer/") else { return nil }
        if r.method == "POST", path == "/api/local-computer/screenshot" {
            localVM.touchIdle()
            do {
                let status = await localVM.status()
                guard status["ready"]?.bool == true, let runtime = status["runtime"]?.string else {
                    return .error(409, status["problem"]?.string ?? "The Local VM is not ready")
                }
                let shot = "/tmp/swarmebot-preview.png"
                _ = try await LocalVM.run(runtime, LocalVM.cuaExecArgs(["call", "get_desktop_state", "{}", "--socket", LocalVM.socket, "--screenshot-out-file", shot]), timeout: 20)
                let captured = try await LocalVM.run(runtime, ["exec", LocalVM.container, "base64", "-w0", shot], timeout: 20)
                return .json(200, ["image": .string(captured.trimmingCharacters(in: .whitespacesAndNewlines))])
            } catch {
                return .error(409, error.localizedDescription)
            }
        }
        guard let action = path.dropFirst("/api/local-computer/".count).split(separator: "/").first.map(String.init),
              ["pull", "run", "start", "stop", "remove"].contains(action), r.method == "POST" else { return nil }
        let type = r.header("content-type") ?? ""
        if !type.lowercased().hasPrefix("application/json") { return .error(415, "content-type must be application/json") }
        if localVM.lifecycleBusy { return .error(409, "another Local VM setup action is still running") }
        let busy = { (botId: String) in Store.isBusy(self.store.bot(botId)) }
        if let owner = localVM.lease.current(busy: busy), ["stop", "remove", "run"].contains(action) {
            return .error(409, "the Local VM is being used by a bot — stop that turn first")
        }
        localVM.lifecycleBusy = true
        defer { localVM.lifecycleBusy = false }
        do {
            if action == "run" || action == "start" { localVM.touchIdle() }
            if action == "stop" || action == "remove" { localVM.cancelIdle() }
            return .json(200, .object(try await localVM.action(action)))
        } catch {
            return .error(409, error.localizedDescription)
        }
    }

    /// The Computer panel: status, who drives, and the Box actions. Nil = not ours.
    func computerRoute(_ r: HTTPRequest, path: String) async throws -> HTTPResponse? {
        guard let range = path.range(of: #"^/api/bots/([\w-]+)/computer(/[\w-]+)?$"#, options: .regularExpression) else { return nil }
        let rest = String(path[range].dropFirst("/api/bots/".count))
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let botId = parts[0]
        let action = parts.count > 2 ? parts[2] : nil
        guard let bot = store.bot(botId) else { return .error(404, "no such bot") }
        let vps = bot["cloudBackend"]?.string == "vps"

        switch (r.method, action) {
        case ("GET", nil):
            if vps { return .error(501, "Il computer VPS è \(Self.computerNotPorted)") }
            return .json(200, .object(JSONObject([("backend", "box")]).merging(await box.status(botId))))
        case (_, "control"?):
            if r.method == "GET" { return .json(200, .object(computerControl.snapshot(botId))) }
            guard r.method == "POST" else { return .error(405, "method not allowed") }
            switch (try r.json())["action"].flatMap(Harness.text) ?? "" {
            case "take": return .json(200, .object(computerControl.take(botId)))
            case "release": return .json(200, .object(computerControl.release(botId)))
            case "dismiss-help": return .json(200, .object(computerControl.dismissHelp(botId)))
            default: return .error(400, "action must be take, release, or dismiss-help")
            }
        case ("POST", let verb?) where ["provision", "join", "sleep", "exec", "screenshot", "remove"].contains(verb):
            if vps { return .error(501, "Il computer VPS è \(Self.computerNotPorted)") }
            switch verb {
            case "remove":
                // boxes sleep and wake; only a VPS has a container to remove
                return .error(409, "the cloud Box backend has no container to remove — use sleep instead")
            case "provision": return .json(200, try await box.provision(botId, botName: bot["name"]?.string ?? ""))
            case "join": return .json(200, try await box.join(botId))
            case "sleep": return .json(200, try await box.sleep(botId))
            case "exec": return .json(200, try await box.exec(botId, (try r.json())["command"].flatMap(Harness.text) ?? ""))
            default:
                let shot = try await box.screenshot(botId)
                return .json(200, ["png": .string(shot.png), "format": .string(shot.format)])
            }
        default:
            return nil
        }
    }
}
