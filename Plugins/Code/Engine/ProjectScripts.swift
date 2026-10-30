import Foundation
import HarnessCore

/// Explicit user commands from the project's configuration. Processes live on the engine, including remotely.
@MainActor
final class ProjectScripts {
    final class Run {
        let id = UUID().uuidString.lowercased()
        let name: String
        let command: String
        let folder: String
        var output = ""
        var truncated = false
        var running = true
        var stopped = false
        var code: Int32?
        var process: CLIProcess?
        init(name: String, command: String, folder: String) { self.name = name; self.command = command; self.folder = folder }
        var wire: JSON {
            ["id": .string(id), "name": .string(name), "command": .string(command), "folder": .string(folder),
             "output": .string(output), "truncated": .bool(truncated), "running": .bool(running), "stopped": .bool(stopped),
             "exitCode": code.map { .number(Double($0)) } ?? .null]
        }
        func append(_ text: String) {
            output += text
            if output.utf8.count > 200_000 { output = String(output.suffix(100_000)); truncated = true }
        }
    }

    private var runs: [String: Run] = [:]

    func configuration(harness: Harness, thread: String) throws -> (folder: String, scripts: [JSON]) {
        guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: thread)?.first else { throw HTTPError(404, "no such thread") }
        let owner = harness.store.groupByThread(thread) ?? harness.store.botByThread(thread)
        guard let projectId = owner?["plugins"]?["code"]?["projectId"]?.string,
              let project = ProjectStore(harness: harness).project(projectId),
              let repo = project["repos"]?.array?.first(where: { $0["path"]?.string.map(ThreadGit.canonical) == ThreadGit.canonical(folder) }) else {
            return (folder, [])
        }
        return (folder, repo["scripts"]?.array ?? [])
    }

    func status(harness: Harness, thread: String) throws -> JSON {
        let config = try configuration(harness: harness, thread: thread)
        return ["scripts": .array(config.scripts), "run": runs[thread]?.wire ?? .null]
    }

    func start(harness: Harness, thread: String, index: Int) throws -> JSON {
        let config = try configuration(harness: harness, thread: thread)
        guard config.scripts.indices.contains(index), let command = config.scripts[index]["command"]?.string else { throw HTTPError(400, "no such project script") }
        guard runs[thread]?.running != true else { throw HTTPError(409, "a project script is already running in this chat") }
        // Completed output is a bounded, transient convenience, never unbounded engine history.
        if runs.count >= 50, let old = runs.first(where: { !$0.value.running })?.key { runs[old] = nil }
        guard runs.count < 50 || runs[thread] != nil else { throw HTTPError(409, "too many project scripts are running") }
        let run = Run(name: config.scripts[index]["name"]?.string ?? "", command: command, folder: config.folder)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = EnvPath.augmented()
        let process = try CLIProcess(cli: "/bin/sh", args: ["-lc", command], cwd: config.folder, environment: environment)
        run.process = process
        process.onLine = { [weak run] in run?.append($0 + "\n") }
        process.onStderr = { [weak run] in run?.append($0) }
        process.onClose = { [weak run] code in run?.running = false; run?.code = code; run?.process = nil }
        runs[thread] = run
        process.closeStdin()
        process.start()
        return run.wire
    }

    func stop(thread: String) -> JSON {
        guard let run = runs[thread] else { return .null }
        if run.running { run.stopped = true; run.process?.killTree() }
        return run.wire
    }

    func stopAll() { for thread in runs.keys { _ = stop(thread: thread) } }
}
