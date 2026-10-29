// Running git (and gh) for the Code plugin: one environment, one way to ask.
import Foundation
import HarnessCore

enum GitRun {
    /// `GIT_OPTIONAL_LOCKS=0` so that looking never takes the index lock from the agent that is
    /// committing; `LC_ALL=C` so that what git says can be read; no terminal to ask anything on.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = EnvPath.augmented()
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    @MainActor
    static func git(_ args: [String], in folder: String, timeout: TimeInterval = 15) async -> CLIProcess.Output? {
        await CLIProcess.run("git", ["-c", "core.quotePath=false", "-c", "color.ui=false"] + args, environment: environment, cwd: folder, timeout: timeout)
    }

    /// stdout of a git command that must succeed, trimmed; nil when it did not.
    @MainActor
    static func text(_ args: [String], in folder: String, timeout: TimeInterval = 15) async -> String? {
        guard let output = await git(args, in: folder, timeout: timeout), output.ok else { return nil }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a failed command said, for a message a person can read.
    static func said(_ output: CLIProcess.Output) -> String {
        let text = output.stderr.isEmpty ? output.stdout : output.stderr + (output.stdout.isEmpty ? "" : "\n" + output.stdout)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
