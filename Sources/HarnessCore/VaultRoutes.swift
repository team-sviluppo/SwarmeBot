// `/api/vault*` — the vault's settings API (docs/plans/2026-10-25-vault.md).
// No route ever returns a value. On a remote engine only the reading is
// served: the vault is written over ssh by the Mac that administers it
// (`swarme-harness vault …`, V7). Every change is broadcast as
// `{"kind": "vault"}`; the app reloads.
import Foundation

@MainActor
enum VaultRoutes {
    static let remoteRefusal = "the vault of a remote engine is changed from the Mac that administers it"

    static func respond(_ status: Int, _ value: JSON) -> RouteResult { .response(.json(status, value)) }
    static func fail(_ status: Int, _ message: String) -> RouteResult { .response(.error(status, message)) }

    static func handle(_ r: HTTPRequest, harness: Harness) throws -> RouteResult? {
        let path = r.path, method = r.method
        guard path == "/api/vault" || path.hasPrefix("/api/vault/") else { return nil }
        let vault = harness.vault
        if method == "GET", path == "/api/vault" {
            vault.reload()
            guard var out = vault.wire().object else { return fail(500, "vault unreadable") }
            out["support"] = support(harness)
            return respond(200, .object(out))
        }
        if r.deviceId != nil { return fail(403, remoteRefusal) }
        if method != "DELETE", !r.isJSON { return fail(415, "content-type must be application/json") }
        do {
            if path == "/api/vault/secrets", method == "POST" {
                let secret = try vault.create(try r.json())
                harness.broadcast(["kind": "vault"])
                return respond(201, ["secret": .object(secret)])
            }
            if path.hasPrefix("/api/vault/secrets/") {
                let name = String(path.dropFirst("/api/vault/secrets/".count))
                switch method {
                case "PATCH":
                    let secret = try vault.update(name, try r.json())
                    harness.broadcast(["kind": "vault"])
                    return respond(200, ["secret": .object(secret)])
                case "DELETE":
                    try vault.remove(name)
                    harness.broadcast(["kind": "vault"])
                    return respond(200, ["ok": true])
                default:
                    return nil
                }
            }
            if path.hasPrefix("/api/vault/grants/"), method == "PUT" {
                let botId = String(path.dropFirst("/api/vault/grants/".count))
                guard harness.store.bot(botId) != nil else { return fail(404, "no such bot") }
                let grants = try vault.setGrants(botId: botId, try r.json())
                harness.broadcast(["kind": "vault"])
                return respond(200, ["grants": grants])
            }
        } catch let error as VaultError {
            return fail(error.status, error.message)
        }
        return nil
    }

    /// Which engines can use a secret, and how: the app greys out the rest.
    static func support(_ harness: Harness) -> JSON {
        var safe: [String] = [], env: [String] = []
        for instance in harness.registry.instances() where !Harness.noShellDrivers.contains(instance.driverKind) {
            if instance.adapter.capabilities.agentsMcp, !safe.contains(instance.driverKind) { safe.append(instance.driverKind) }
            if !env.contains(instance.driverKind) { env.append(instance.driverKind) }
        }
        return ["safe": .strings(safe), "env": .strings(env)]
    }
}
