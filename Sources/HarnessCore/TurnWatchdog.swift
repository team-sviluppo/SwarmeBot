// Two observers of a running turn — `server/turn-watchdog.ts` and
// `server/repeat-detector.ts`.
//
// The watchdog stops a turn whose thread has emitted NOTHING for `stallMs`:
// activity-based, so an hour-long turn that keeps streaming is never touched,
// and a turn parked on a human approval is exempt — waiting on a person is
// not a stall. Without it a wedged CLI leaves its bot busy forever.
//
// The repeat detector only observes: the same tool call with the same
// arguments, over and over in one turn, gets a chip at 5, 10 and 20. The
// human has Stop; cutting the call off would need the harness to own it.
import Foundation

@MainActor
public final class TurnWatchdog {
    public struct Watched {
        public var threadId: String
        public var botId: String
        public var lastEventAt: Date
        public var waitingOnHuman = false
    }

    private var turns: [String: Watched] = [:]
    private let stallSeconds: TimeInterval
    private let checkSeconds: TimeInterval
    private let onStall: (Watched) -> Void
    private var sweeper: Task<Void, Never>?

    public init(stallSeconds: TimeInterval, checkSeconds: TimeInterval = 60, onStall: @escaping (Watched) -> Void) {
        self.stallSeconds = stallSeconds
        self.checkSeconds = checkSeconds
        self.onStall = onStall
    }

    public func start() {
        guard sweeper == nil else { return }
        let interval = checkSeconds
        sweeper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                self?.sweep()
            }
        }
    }

    public func watch(_ threadId: String, botId: String) {
        turns[threadId] = Watched(threadId: threadId, botId: botId, lastEventAt: Date())
    }

    public func touch(_ threadId: String) { turns[threadId]?.lastEventAt = Date() }

    public func setWaitingOnHuman(_ threadId: String, _ waiting: Bool) {
        guard turns[threadId] != nil else { return }
        turns[threadId]?.waitingOnHuman = waiting
        turns[threadId]?.lastEventAt = Date()
    }

    public func settle(_ threadId: String) { turns[threadId] = nil }

    public func watching(_ threadId: String) -> Bool { turns[threadId] != nil }

    func sweep(now: Date = Date()) {
        for turn in Array(turns.values) where !turn.waitingOnHuman && now.timeIntervalSince(turn.lastEventAt) >= stallSeconds {
            turns[turn.threadId] = nil
            onStall(turn)
        }
    }
}

public struct RepeatDetector {
    private var counts: [String: (order: [String], counts: [String: Int])] = [:]
    let thresholds: [Int]
    let maxKeysPerThread: Int

    public init(thresholds: [Int] = [5, 10, 20], maxKeysPerThread: Int = 256) {
        self.thresholds = thresholds.sorted()
        self.maxKeysPerThread = maxKeysPerThread
    }

    /// Tool plus whitespace-normalized arguments; a bare name is not a call
    /// worth counting ("Bash" five times may be five different commands).
    public static func callKey(_ tool: String, _ args: String?) -> String? {
        let normalized = (args ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty, normalized != tool else { return nil }
        return "\(tool):\(normalized)"
    }

    /// Count one call; the threshold it landed on, if any. A bounded,
    /// recency-ordered set: the least recently seen signature falls out.
    public mutating func record(_ threadId: String, _ key: String) -> Int? {
        var entry = counts[threadId] ?? ([], [:])
        let previous = entry.counts[key]
        if previous != nil {
            entry.order.removeAll { $0 == key }
        } else if entry.counts.count >= maxKeysPerThread, let oldest = entry.order.first {
            entry.order.removeFirst()
            entry.counts[oldest] = nil
        }
        let count = (previous ?? 0) + 1
        entry.counts[key] = count
        entry.order.append(key)
        counts[threadId] = entry
        return thresholds.contains(count) ? count : nil
    }

    public mutating func settle(_ threadId: String) { counts[threadId] = nil }
}
