import CompanionCore
import Foundation
import Observation

public enum RemoteHarness: String, CaseIterable, Sendable {
    case codex, claude, omp

    public var name: String {
        switch self { case .codex: return "Codex"; case .claude: return "Claude Code"; case .omp: return "omp" }
    }

    func installed(in probe: RemoteProbe) -> String? {
        switch self { case .codex: return probe.codex; case .claude: return probe.claude; case .omp: return probe.omp }
    }
}

struct HarnessVersion: Comparable, Equatable, Sendable {
    let parts: [Int]

    init?(_ value: String) {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) }) else { return nil }
        let parts = pieces.compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.parts = parts
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }

    static func installed(_ line: String, kind: RemoteHarness) -> Self? {
        let value = kind == .omp ? line.replacingOccurrences(of: "omp/", with: "")
            : kind == .codex ? line.replacingOccurrences(of: "codex-cli ", with: "") : line
        return value.split(whereSeparator: { $0.isWhitespace }).first.flatMap { Self(String($0)) }
    }
}

struct HarnessRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable { var name: String; var digest: String? }
    var tag_name: String
    var prerelease: Bool
    var draft: Bool
    var assets: [Asset]

    func package(kind: RemoteHarness, probe: RemoteProbe) throws -> (version: String, asset: String, sha256: String) {
        let prefix = kind == .codex ? "rust-v" : "v"
        let version = tag_name.hasPrefix(prefix) ? String(tag_name.dropFirst(prefix.count)) : ""
        let asset = kind == .codex ? CodexConfig.release(for: probe).map { $0.asset + ".tar.gz" } : OmpConfig.asset(for: probe)
        guard !prerelease, !draft, HarnessVersion(version) != nil,
              let asset, let entry = assets.first(where: { $0.name == asset }),
              let digest = entry.digest, digest.hasPrefix("sha256:") else {
            throw ProcessRunner.Failure(message: tr("Release ufficiale di %@ non valida per questo server", kind.name))
        }
        let hash = String(digest.dropFirst(7))
        guard hash.count == 64, hash.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw ProcessRunner.Failure(message: tr("Release ufficiale di %@ non valida per questo server", kind.name))
        }
        return (version, kind == .codex ? String(asset.dropLast(7)) : asset, hash)
    }
}

/// One source per app-start sweep: servers share the same official release response.
@MainActor
final class HarnessReleaseSource {
    private var requests: [RemoteHarness: Task<HarnessRelease, Error>] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func reset() { requests.removeAll() }

    func latest(_ kind: RemoteHarness) async throws -> HarnessRelease {
        if let pending = requests[kind] { return try await pending.value }
        let repo = kind == .codex ? "openai/codex" : "can1357/oh-my-pi"
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SwarmeBot", forHTTPHeaderField: "User-Agent")
        let task = Task { [session] in
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ProcessRunner.Failure(message: tr("Controllo degli aggiornamenti di %@ non riuscito", kind.name))
            }
            return try JSONDecoder().decode(HarnessRelease.self, from: data)
        }
        requests[kind] = task
        do { return try await task.value }
        catch { requests[kind] = nil; throw error }
    }
}

public struct RemoteHarnessUpdateStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case checking, waiting, finished, failed }
    public var phase: Phase
    public var lines: [String]
    public var busyNames: [String] = []

    public var running: Bool { phase == .checking || phase == .waiting }
    public var text: String {
        switch phase {
        case .checking: return tr("Controllo e aggiornamento degli harness…")
        case .waiting: return tr("Aggiornamento rimandato: stanno lavorando %@", busyNames.joined(separator: ", "))
        case .finished: return lines.isEmpty ? tr("Nessun harness gestito installato") : lines.joined(separator: "\n")
        case .failed: return lines.joined(separator: "\n")
        }
    }
}

@MainActor
@Observable
public final class RemoteHarnessUpdateMonitor {
    public private(set) var statuses: [String: RemoteHarnessUpdateStatus] = [:]
    @ObservationIgnored private var checked: Set<String> = []
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var runs: [String: UUID] = [:]
    @ObservationIgnored var waitUntilRetry: () async throws -> Void = { try await Task.sleep(nanoseconds: 30_000_000_000) }

    func check(_ id: String, operations: RemoteHarnessUpdater.Operations, force: Bool = false) {
        guard tasks[id] == nil, force || !checked.contains(id) else { return }
        checked.insert(id)
        let run = UUID()
        runs[id] = run
        statuses[id] = .init(phase: .checking, lines: [])
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.runs[id] == run { self.tasks[id] = nil; self.runs[id] = nil }
            }
            do {
                while !Task.isCancelled {
                    let status = try await RemoteHarnessUpdater.run(operations)
                    try Task.checkCancellation()
                    guard self.runs[id] == run else { return }
                    self.statuses[id] = status
                    guard status.phase == .waiting else { return }
                    try await self.waitUntilRetry()
                }
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, self.runs[id] == run {
                    self.statuses[id] = .init(phase: .failed, lines: [error.localizedDescription])
                }
            }
        }
    }

    func retain(_ ids: Set<String>) {
        for id in Array(tasks.keys) where !ids.contains(id) {
            runs[id] = nil
            tasks.removeValue(forKey: id)?.cancel()
        }
        checked.formIntersection(ids)
        statuses = statuses.filter { ids.contains($0.key) }
    }

    func stop() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        runs.removeAll()
    }
}

/// Only updates installed coding harnesses. Never copies logins, restarts the
/// engine or assumes that an unreachable fleet is idle.
@MainActor
enum RemoteHarnessUpdater {
    struct Operations {
        var probe: () async throws -> RemoteProbe
        var busy: () async throws -> [String]
        var update: (RemoteHarness, RemoteProbe, () async throws -> Void) async throws -> String
    }

    static func run(_ operations: Operations) async throws -> RemoteHarnessUpdateStatus {
        func idle() async throws {
            try Task.checkCancellation()
            let names = try await operations.busy()
            if !names.isEmpty { throw EngineUpdateError.busy(names) }
        }
        var lines: [String] = []
        var failed = false
        do {
            try await idle()
            let probe = try await operations.probe()
            for kind in RemoteHarness.allCases where kind.installed(in: probe) != nil {
                do {
                    try await idle()
                    let after = try await operations.update(kind, probe, idle)
                    let before = kind.installed(in: probe) ?? ""
                    if HarnessVersion.installed(before, kind: kind) == HarnessVersion.installed(after, kind: kind) {
                        lines.append(tr("%@: controllo completato (%@)", kind.name, after))
                    } else {
                        lines.append(tr("%@: %@ → %@", kind.name, before, after))
                    }
                } catch let EngineUpdateError.busy(names) {
                    return .init(phase: .waiting, lines: lines, busyNames: names)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    failed = true
                    lines.append("\(kind.name): \(error.localizedDescription)")
                }
            }
            return .init(phase: failed ? .failed : .finished, lines: lines)
        } catch let EngineUpdateError.busy(names) {
            return .init(phase: .waiting, lines: lines, busyNames: names)
        }
    }
}

extension RemoteAdmin {
    func updateHarness(_ kind: RemoteHarness, probe: RemoteProbe, source: HarnessReleaseSource,
                       ensureIdle: () async throws -> Void) async throws -> String {
        if kind == .claude {
            try await ensureIdle()
            let result = try await ssh.run(RemoteScripts.command(RemoteScripts.updateClaude), timeout: 300)
            guard let version = RemoteScripts.values(result.text)["claude"], HarnessVersion.installed(version, kind: .claude) != nil else {
                throw ProcessRunner.Failure(message: tr("Versione installata di %@ non riconosciuta", kind.name))
            }
            return version
        }
        let release = try await source.latest(kind).package(kind: kind, probe: probe)
        guard let current = kind.installed(in: probe), let installed = HarnessVersion.installed(current, kind: kind),
              let latest = HarnessVersion(release.version) else {
            throw ProcessRunner.Failure(message: tr("Versione installata di %@ non riconosciuta", kind.name))
        }
        // Never downgrade: release publication and package managers may be ahead of /latest.
        if installed > latest || (kind == .omp && installed == latest) { return current }
        try await ensureIdle() // downloads of release metadata may have taken a while
        let script = kind == .codex ? RemoteScripts.installCodex : RemoteScripts.installOmp
        let arguments = [release.version, release.asset, release.sha256] + (kind == .codex ? ["update"] : [])
        let result = try await ssh.run(RemoteScripts.command(script, arguments), timeout: 600)
        guard let version = RemoteScripts.values(result.text)[kind.rawValue],
              HarnessVersion.installed(version, kind: kind) == latest else {
            throw ProcessRunner.Failure(message: tr("Versione installata di %@ non riconosciuta", kind.name))
        }
        return version
    }
}
