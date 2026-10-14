// Risk R1 from the plan: does a SwiftUI transcript hold up on a long thread?
//
// `SWARMEBOT_BENCH=2000` starts the app without a harness on a synthetic
// thread of that many messages and measures, on the real window:
//
// - first layout: install → the transcript laid out and drawn;
// - jump to top / back to bottom: what scrolling 2,000 rows costs;
// - live append: 50 settled replies, 120 ms apart;
// - streaming: 300 deltas at 60 Hz into the live bubble;
// - resident memory at the end.
//
// "Hitch" is the longest gap between ticks of a 120 Hz main-thread timer
// during a phase — the stall a person would see as a dropped frame run.
// Results go to `SWARMEBOT_BENCH_OUT` (JSON) and stdout, then the app quits.
import AppKit
import SwarmeKit

@MainActor
final class BenchRunner {
    private let model: AppModel
    private let count: Int
    private var results: [String: Any] = [:]
    private var ticks: [CFTimeInterval] = []
    private var timer: Timer?

    init(model: AppModel, count: Int) {
        self.model = model
        self.count = count
    }

    func run() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2)) // let the window settle
            results["messages"] = count

            let installStart = CACurrentMediaTime()
            model.installBenchmark(messages: count)
            await settle()
            results["firstLayoutMs"] = ms(CACurrentMediaTime() - installStart)

            results["jumpToTop"] = await phase(seconds: 2) { self.model.focusMessageId = "m0" }
            results["jumpToBottom"] = await phase(seconds: 2) { self.model.focusMessageId = "m\(self.count - 1)" }

            results["append50"] = await phase(seconds: 0) {
                for index in 0..<50 {
                    self.model.appendBenchmarkMessage(index)
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            results["stream300"] = await phase(seconds: 0) {
                for index in 0..<300 {
                    self.model.streamBenchmarkDelta(index % 40 == 0 ? "\n\n" : "parola ")
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
            results["residentMB"] = Self.residentMB()

            let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            if let data {
                print(String(decoding: data, as: UTF8.self))
                if let out = ProcessInfo.processInfo.environment["SWARMEBOT_BENCH_OUT"] {
                    try? data.write(to: URL(fileURLWithPath: out))
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// Lay out and draw every window now, then let the run loop drain.
    private func settle() async {
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        try? await Task.sleep(for: .milliseconds(50))
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func phase(seconds: Double, _ body: @escaping () async -> Void) async -> [String: Double] {
        ticks = []
        let start = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ticks.append(CACurrentMediaTime()) }
        }
        RunLoop.main.add(timer!, forMode: .common)
        await body()
        await settle()
        if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
        timer?.invalidate()
        let gaps = zip(ticks.dropFirst(), ticks).map { $0 - $1 }
        let sorted = gaps.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return [
            "totalMs": ms(CACurrentMediaTime() - start),
            "maxHitchMs": ms(sorted.last ?? 0),
            "p95GapMs": ms(p95),
            "gapsOver50ms": Double(gaps.filter { $0 > 0.05 }.count),
        ]
    }

    private func ms(_ seconds: CFTimeInterval) -> Double { (seconds * 10_000).rounded() / 10 }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return (Double(info.resident_size) / 1_048_576 * 10).rounded() / 10
    }
}
