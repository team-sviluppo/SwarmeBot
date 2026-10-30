// `swarme-harness vault …` — the vault of a remote engine, written over ssh
// by the Mac that administers it (docs/plans/2026-10-25-vault.md V7). The
// engine re-reads the files at its next turn: no restart.
//
//   vault list                  → the vault as GET /api/vault shows it (no value)
//   vault set <NAME>            stdin: one JSON line {preset, description, hint, value}
//                               (creates the secret, or updates the fields given)
//   vault unset <NAME>
//   vault grant <botId>         stdin: one JSON line {secrets: [{name, mode}], note}
//
// Data always comes on stdin, never argv: a value must not show in a process listing.
import Foundation
import HarnessCore

func runVaultCommand(_ args: [String], paths: DataPaths, environment: [String: String]) -> Never {
    paths.ensure()
    let vault = Vault(paths: paths, key: Vault.key(from: environment))
    func input() -> JSONObject {
        let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        guard let object = (try? JSON.parse(text))?.object else { fail("stdin must be one JSON object") }
        return object
    }
    do {
        switch (args.first, args.count) {
        case ("list", 1):
            print(vault.wire().serialized())
        case ("set", 2):
            let body = input()
            if vault.secret(args[1]) == nil {
                var create = body
                create["name"] = .string(args[1])
                try vault.create(create)
            } else {
                try vault.update(args[1], body)
            }
            print(JSON.object(["ok": true]).serialized())
        case ("unset", 2):
            try vault.remove(args[1])
            print(JSON.object(["ok": true]).serialized())
        case ("grant", 2):
            let known = FileIO.readJSON(paths.bots)?.array?.contains { $0["id"]?.string == args[1] } ?? false
            guard known else { fail("no such bot") }
            print(JSON.object(["grants": try vault.setGrants(botId: args[1], input())]).serialized())
        default:
            fail("vault list | set <NAME> | unset <NAME> | grant <botId> (data as JSON on stdin)")
        }
    } catch {
        fail(error.localizedDescription)
    }
    exit(0)
}
