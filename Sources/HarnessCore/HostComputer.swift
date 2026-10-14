// This Mac as a computer — `server/local-computer.ts` and the standalone
// half of `electron/cua.mjs`.
//
// Nothing here starts at launch. The app passes `OMB_LOCAL_COMPUTER=1` only
// after the person turns the switch on, and even then the driver process
// exists only for a turn whose bot chose this Mac. The default is off:
// Cua captured the desktop and made the UI stutter when it ran all the time.
import Foundation

enum HostComputer {
    static let installed = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"

    struct Connection {
        var command: String
        var args: [String]
        var env: [String: String]
    }

    /// The MCP command a turn may mount. Nil when this Mac has no driver.
    /// Reading the descriptor does not start anything.
    static func connection(environment: [String: String] = ProcessInfo.processInfo.environment) -> Connection? {
        let home = NSHomeDirectory()
        var files: [String] = []
        if let userData = environment["OMB_USER_DATA"], !userData.isEmpty {
            files.append((userData as NSString).appendingPathComponent("cua-connection.json"))
        }
        for directory in ["SwarmeBot", "swarmebot", "OpenMausBot", "openmausbot", "OpenGrokBot", "opengrokbot"] {
            files.append("\(home)/Library/Application Support/\(directory)/cua-connection.json")
        }
        for path in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSON.parse(data).object,
                  object["mode"]?.string != "unavailable",
                  let command = object["mcpCommand"]?.string, !command.isEmpty else { continue }
            let args = object["mcpArgs"]?.array?.compactMap(\.string) ?? ["mcp"]
            var env: [String: String] = [:]
            if let raw = object["mcpEnv"]?.object {
                for (key, value) in raw { if let text = value.string { env[key] = text } }
            }
            env["CUA_DRIVER_RS_TELEMETRY_ENABLED"] = env["CUA_DRIVER_RS_TELEMETRY_ENABLED"] ?? "0"
            return Connection(command: command, args: args, env: env)
        }
        let binary = environment["CUA_DRIVER_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? installed
        guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }
        return Connection(command: binary, args: ["mcp"], env: ["CUA_DRIVER_RS_TELEMETRY_ENABLED": "0"])
    }
}
