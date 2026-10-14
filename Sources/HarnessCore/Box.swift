// The bot's cloud computer on box.ascii.dev — `server/box.ts`, ported.
//
// One persistent box per bot, found by a deterministic name; stop pauses
// billing while the disk survives; Join always mints a FRESH desktop URL
// (stream tokens rotate on every state change — never persist one). REST
// only: shell runs synchronously through POST /boxes/{id}/commands.
import CryptoKit
import Foundation

public struct BoxError: LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
}

@MainActor
public final class BoxComputer {
    static let ready: Set<String> = ["idle", "ready", "running"]
    let api: String
    let session: URLSession
    let token: () -> String?
    /// Resolving a box LISTs the whole account: once the id is known, go straight at it.
    private var idCache: [String: String] = [:]

    /// `OMB_BOX_API` points tests and parity at a stub instead of the provider.
    public init(environment: [String: String], session: URLSession = .shared, token: @escaping () -> String?) {
        api = environment["OMB_BOX_API"].flatMap { $0.isEmpty ? nil : $0 } ?? "https://ascii.dev/api/box/v1"
        self.session = session
        self.token = token
    }

    public var configured: Bool { !(token() ?? "").isEmpty }

    struct Reply {
        var ok: Bool
        var status: Int
        var body: JSON?
        var data: Data
    }

    private func call(_ path: String, method: String = "GET", body: JSON? = nil, headers: [String: String] = [:],
                      timeout: TimeInterval = 60) async throws -> Reply {
        guard let url = URL(string: api + path) else { throw BoxError(message: "invalid box URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token() ?? "")", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.httpBody = body.data }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSON.parse(data)
        return Reply(ok: (200...299).contains(status) && json?["ok"]?.bool != false, status: status, body: json, data: data)
    }

    /// `boxJson`, which never throws on a transport failure in its callers' eyes.
    private func json(_ path: String, method: String = "GET", body: JSON? = nil, headers: [String: String] = [:]) async -> Reply {
        (try? await call(path, method: method, body: body, headers: headers)) ?? Reply(ok: false, status: 0, body: nil, data: Data())
    }

    /// Deterministic per-bot name; the hash kills truncated-uuid collisions.
    nonisolated public static func name(for botId: String) -> String {
        let hash = SHA256.hash(data: Data(botId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(6)
        let head = String(botId.prefix(8)).lowercased().filter { ($0.isASCII && $0.isLetter) || $0.isNumber }
        return "ogb-\(head)-\(hash)"
    }

    public struct Command {
        public var ok: Bool
        public var exitCode: Int?
        public var stdout: String
        public var stderr: String
    }

    public func run(_ boxId: String, _ command: String, timeout: TimeInterval = 120) async throws -> Command {
        let reply = try await call("/boxes/\(boxId)/commands", method: "POST", body: ["command": .string(command)], timeout: timeout)
        let exit = reply.body?["exitCode"]?.int
        return Command(ok: (200...299).contains(reply.status) && exit == 0, exitCode: exit,
                       stdout: reply.body?["stdout"]?.string ?? "", stderr: reply.body?["stderr"]?.string ?? "")
    }

    /// VNC first (plain WebSocket, survives P2P-blocking networks; answers
    /// `provisioning` first, so poll), WebRTC as the fallback.
    func mintDesktopUrl(_ boxId: String, vncBudget: TimeInterval = 60) async -> String? {
        let start = Date()
        while Date().timeIntervalSince(start) < vncBudget {
            let body = await json("/boxes/\(boxId)/desktop?vnc=1", method: "POST").body
            if let url = body?["desktopUrl"]?.string ?? body?["url"]?.string { return url }
            if body?["provisioning"]?.truthy != true { break }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        let body = await json("/boxes/\(boxId)/desktop", method: "POST").body
        return body?["desktopUrl"]?.string ?? body?["url"]?.string
    }

    func waitReady(_ boxId: String, budget: TimeInterval = 90) async -> JSON? {
        let start = Date()
        while Date().timeIntervalSince(start) < budget {
            let box = await json("/boxes/\(boxId)").body?["box"]
            let state = box?["state"]?.string ?? ""
            if Self.ready.contains(state) { return box }
            if state == "error" { return nil }
            // an archiving box can't resume until the snapshot lands: nudge
            if state == "archived" { _ = await json("/boxes/\(boxId)/resume", method: "POST") }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
        return nil
    }

    public func find(_ botId: String) async -> JSON? {
        if let cached = idCache[botId] {
            let reply = await json("/boxes/\(cached)")
            if reply.ok, let box = reply.body?["box"], box["id"] != nil, box["state"]?.string != "error" { return box }
            idCache[botId] = nil // gone or broken: back to the listing
        }
        let name = Self.name(for: botId)
        let found = (await json("/boxes").body?["boxes"]?.array ?? []).first { $0["name"]?.string == name && $0["state"]?.string != "error" }
        if let id = found?["id"]?.string { idCache[botId] = id }
        return found
    }

    /// Ready-or-nil, without the LIST when the box is known.
    public func readyBox(_ botId: String, budget: TimeInterval = 60) async -> JSON? {
        guard let box = await find(botId) else { return nil }
        if Self.ready.contains(box["state"]?.string ?? "") { return box }
        return await waitReady(box["id"]?.string ?? "", budget: budget)
    }

    /// The provider's own words beat ours: it knows the plan, the limit, the link.
    nonisolated public static func errorMessage(_ status: Int, _ what: String, _ body: JSON?) -> String {
        let theirs = body?["message"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let link = body?["error"]?["details"]?["billingUrl"]?.string ?? ""
        switch status {
        case 402:
            return [theirs.isEmpty ? "ascii.dev needs a paid Box plan before it will create a computer." : theirs, link].filter { !$0.isEmpty }.joined(separator: " ")
        case 401, 403:
            return "your box token was rejected by ascii.dev — open App Settings and paste a current token (it starts with box_)"
        case 429:
            return theirs.isEmpty ? "ascii.dev is rate-limiting this account — wait a minute and try again" : theirs
        default:
            return theirs.isEmpty ? "\(what) failed (\(status))" : "\(what) failed: \(theirs)"
        }
    }

    /// Ask the provider whether a token is real before anyone saves it.
    public func verify(_ candidate: String) async -> String? {
        guard let url = URL(string: api + "/boxes") else { return "invalid box URL" }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(candidate)", forHTTPHeaderField: "authorization")
        guard let (_, response) = try? await session.data(for: request) else {
            return "Couldn't reach ascii.dev to check that token — check your connection and retry."
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200...299).contains(status) { return nil }
        if status == 401 || status == 403 {
            return candidate.hasPrefix("box_")
                ? "ascii.dev rejected that token — it may have been revoked or expired. Copy a fresh one from your ascii.dev account."
                : "That doesn't look like a box API key: they start with box_. Copy the API key from your ascii.dev account (an account or session token won't work here)."
        }
        return "ascii.dev returned \(status) for that token — try again in a moment."
    }

    /// Box state for the Computer panel.
    public func status(_ botId: String) async -> JSONObject {
        guard configured else { return ["configured": false, "box": .null] }
        guard let box = await find(botId) else { return ["configured": true, "box": .null] }
        return ["configured": true, "box": ["boxId": box["id"] ?? .null, "state": box["state"] ?? .null,
                                           "desktopAvailable": box["desktopAvailable"] ?? .null]]
    }

    /// Find-or-create, wait for ready, bootstrap, mint a desktop URL. A box
    /// this call created is deleted again if anything after it fails.
    public func provision(_ botId: String, botName: String) async throws -> JSON {
        guard configured else { throw BoxError(message: #"box provider not enabled — add {"box":{"token":"…"}} to ~/.swarmebot/config.json"#) }
        let vmName = Self.name(for: botId)
        var box = await find(botId)
        var created = false
        do {
            if box == nil {
                // provider-side env injection off: no host key may appear in the guest
                let reply = await json("/boxes", method: "POST", body: ["ttlSeconds": .number(8 * 60 * 60), "noEnv": true])
                guard reply.ok, let made = reply.body?["box"], made["id"]?.string != nil else {
                    throw BoxError(message: Self.errorMessage(reply.status, "box create", reply.body))
                }
                box = made
                created = true
                let rename = await json("/boxes/\(made["id"]!.string!)", method: "PATCH", body: ["name": .string(vmName)])
                if !rename.ok { throw BoxError(message: Self.errorMessage(rename.status, "box naming", rename.body)) }
            }
            let boxId = box?["id"]?.string ?? ""
            guard let ready = await waitReady(boxId) else { throw BoxError(message: "box did not become ready within 90s — retry in a minute") }
            let bootstrap = RemoteComputer.bootstrapCommand(botName: botName)
            var boot: Command?
            for _ in 0..<5 {
                boot = try? await run(boxId, bootstrap)
                if boot?.ok == true || boot?.exitCode != nil { break }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            guard boot?.ok == true else {
                let stderr = String(boot?.stderr.prefix(200) ?? "")
                let detail = !stderr.isEmpty ? stderr : boot?.exitCode.map { "exit \($0)" } ?? "no response"
                throw BoxError(message: "box setup failed: \(detail)")
            }
            guard let joinUrl = await mintDesktopUrl(boxId) else { throw BoxError(message: "box desktop link could not be created") }
            return ["boxId": .string(boxId), "machineName": .string(vmName), "reused": .bool(!created),
                    "state": ready["state"] ?? .null, "joinUrl": .string(joinUrl)]
        } catch {
            guard created, let boxId = box?["id"]?.string else { throw error }
            let cleanup = await json("/boxes/\(boxId)", method: "DELETE", headers: ["X-Ascii-Confirm-Delete": boxId])
            idCache[botId] = nil
            if cleanup.ok { throw error }
            throw BoxError(message: "\(error.localizedDescription). The new computer could not be removed automatically; delete box \(boxId) in ascii.dev.")
        }
    }

    /// Wake the box and hand back a FRESH desktop URL; resume loses processes,
    /// so the driver daemon is reattached first.
    public func join(_ botId: String) async throws -> JSON {
        guard let box = await find(botId), let boxId = box["id"]?.string else { throw BoxError(message: "no computer yet — provision it first") }
        guard let ready = await waitReady(boxId) else { throw BoxError(message: "the box did not wake in time — try again") }
        _ = try? await run(boxId, RemoteComputer.ensureCuaCommand(), timeout: 15)
        return ["joinUrl": JSON.from(await mintDesktopUrl(boxId)), "state": ready["state"] ?? .null]
    }

    /// Archive now: billing pauses, the disk survives. Chrome gets a chance to
    /// flush its profile before the snapshot.
    public func sleep(_ botId: String) async throws -> JSON {
        guard let box = await find(botId), let boxId = box["id"]?.string else { throw BoxError(message: "no computer for this bot") }
        let quiesce = [
            #"for name in chrome google-chrome chromium chromium-browser; do pid=$(pgrep -o -x "$name" 2>/dev/null || true); [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true; done"#,
            "for i in 1 2 3 4 5 6 7 8; do if ! pgrep -x chrome >/dev/null 2>&1 && ! pgrep -x google-chrome >/dev/null 2>&1 && ! pgrep -x chromium >/dev/null 2>&1 && ! pgrep -x chromium-browser >/dev/null 2>&1; then break; fi; sleep 0.25; done",
        ].joined(separator: "; ")
        _ = try? await run(boxId, quiesce, timeout: 5)
        _ = await json("/boxes/\(boxId)/stop", method: "POST")
        return ["ok": true]
    }

    /// The Computer panel's console.
    public func exec(_ botId: String, _ command: String) async throws -> JSON {
        guard let box = await find(botId), let boxId = box["id"]?.string else { throw BoxError(message: "no computer for this bot yet") }
        guard await waitReady(boxId, budget: 60) != nil else { throw BoxError(message: "box did not wake") }
        let out = try await run(boxId, String(command.prefix(4000)))
        return ["exitCode": out.exitCode.map { .number(Double($0)) } ?? .null,
                "stdout": .string(String(out.stdout.suffix(4000))), "stderr": .string(String(out.stderr.suffix(2000)))]
    }

    static let panelPath = "/tmp/ogb-panel.jpg"
    static let shotCommand = [
        "export DISPLAY=${DISPLAY:-:0}",
        "f=\(panelPath)",
        #"w=$(xdotool getdisplaygeometry 2>/dev/null | cut -d" " -f1)"#,
        #"case "$w" in ""|*[!0-9]*) w=0;; esac"#,
        #"scrot -o -q 70 "$f" 2>/dev/null || import -window root -quality 70 "$f" 2>/dev/null || ffmpeg -y -f x11grab -i "$DISPLAY" -frames:v 1 -q:v 7 "$f" >/dev/null 2>&1"#,
        #"if [ "$w" -gt 1024 ] 2>/dev/null && command -v convert >/dev/null 2>&1; then convert "$f" -thumbnail 1024x -quality 70 "$f" 2>/dev/null || true; fi"#,
        #"test -s "$f" && echo captured"#,
    ].joined(separator: "; ")

    /// Raw artifact bytes when the API has them, else the files API.
    func readBase64(_ boxId: String, _ path: String) async -> String? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? path
        if let reply = try? await call("/boxes/\(boxId)/artifacts?path=\(encoded)"), (200...299).contains(reply.status), !reply.data.isEmpty {
            return reply.data.base64EncodedString()
        }
        let reply = await json("/boxes/\(boxId)/files?path=\(encoded)&encoding=base64")
        guard reply.ok, let content = reply.body?["content"]?.string, !content.isEmpty else { return nil }
        return content
    }

    /// Two hops: capture to a file on the box, read the bytes back over HTTP
    /// (base64 over command stdout is not reliable at full size).
    public func screenshot(_ botId: String, knownBoxId: String? = nil) async throws -> (png: String, format: String) {
        var boxId = knownBoxId
        if boxId == nil {
            guard let box = await find(botId) else { throw BoxError(message: "no computer for this bot yet") }
            let state = box["state"]?.string ?? ""
            guard Self.ready.contains(state) else { throw BoxError(message: "box is \(state)") }
            boxId = box["id"]?.string
        }
        let out = try await run(boxId!, Self.shotCommand, timeout: 60)
        guard out.stdout.contains("captured") else {
            let stderr = String(out.stderr.prefix(200))
            throw BoxError(message: stderr.isEmpty ? "screen capture failed on the box" : stderr)
        }
        guard let data = await readBase64(boxId!, Self.panelPath) else { throw BoxError(message: "could not read the frame back from the box") }
        return (data, "jpeg")
    }
}
