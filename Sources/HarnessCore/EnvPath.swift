// The PATH a CLI engine is spawned with — `server/env-path.ts`, macOS only.
//
// A GUI app inherits launchd's PATH, which has neither Homebrew nor nvm nor
// ~/.local/bin in it, so "claude: command not found" is what every engine
// would say. The augmented PATH is: OMB_EXTRA_PATH, the process PATH, the
// usual installer directories, and the login shell's own PATH (probed once,
// in the background, exactly as the Node engine does). Risk R4 of the plan.
import Foundation

public enum EnvPath {
    nonisolated(unsafe) private static var cached: String?
    nonisolated(unsafe) private static var loginShellPath: String?
    nonisolated(unsafe) private static var probed = false
    private static let lock = NSLock()

    static func knownDirs(home: String = NSHomeDirectory()) -> [String] {
        var dirs = [
            "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.kimi-code/bin", "\(home)/.grok/bin",
            "\(home)/.opencode/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.volta/bin", "\(home)/.bun/bin", "\(home)/.asdf/shims", "\(home)/.deno/bin", "\(home)/bin",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [])
            .filter { $0.hasPrefix("v") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        dirs += versions.map { "\(nvm)/\($0)/bin" }
        return dirs
    }

    public static func reset() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    public static func augmented(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        var parts: [String] = []
        parts += (env["OMB_EXTRA_PATH"] ?? "").split(separator: ":").map(String.init)
        parts += (env["PATH"] ?? "").split(separator: ":").map(String.init)
        parts += knownDirs()
        parts += (loginShellPath ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let merged = parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        cached = merged
        if !probed {
            probed = true
            DispatchQueue.global(qos: .utility).async { probeLoginShell(env) }
        }
        return merged
    }

    private static func probeLoginShell(_ env: [String: String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: env["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l", "-i", "-c", #"printf "__OMB_PATH__%s" "$PATH""#]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let range = output.range(of: "__OMB_PATH__") else { return }
        let path = output[range.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
        guard !path.isEmpty else { return }
        lock.lock()
        loginShellPath = path
        cached = nil
        lock.unlock()
    }

    /// Every copy of `name` on the augmented PATH, in PATH order.
    public static func candidates(_ name: String) -> [String] {
        guard !name.isEmpty, !name.contains("\n") else { return [] }
        if name.contains("/") { return [name] }
        return augmented().split(separator: ":").compactMap { dir in
            let path = "\(dir)/\(name)"
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
    }

    public static func which(_ name: String) -> String? { candidates(name).first }

    /// `splitCliString`: a configured CLI may carry arguments and quotes.
    public static func split(_ cli: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        for character in cli.trimmingCharacters(in: .whitespaces) {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { out.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
