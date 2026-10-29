import Foundation
import HarnessCore

enum CodexQuota {
    /// The primary Codex bucket is the current subscription session. Sparse
    /// updates for another bucket must not replace it with an unrelated quota.
    static func session(_ payload: JSON) -> (window: String, utilization: Double, resetsAt: Double?)? {
        let limits = payload["rateLimitsByLimitId"]?["codex"] ?? payload["rateLimits"] ?? payload
        guard limits["limitId"]?.string.map({ $0 == "codex" }) ?? true,
              let primary = limits["primary"], let used = primary["usedPercent"]?.double,
              used.isFinite, used >= 0 else { return nil }
        let minutes = primary["windowDurationMins"]?.int
        let window = minutes == 300 ? "five_hour" : minutes.map { "minutes_\($0)" } ?? "session"
        return (window, used / 100, primary["resetsAt"]?.double)
    }
}

/// USD-equivalent estimate at public Standard API prices, verified 2026-10-29:
/// https://developers.openai.com/api/docs/pricing
/// Model pages document cache writes and the >272K API context premium.
/// This is not the bill for a ChatGPT subscription. Unknown/custom models
/// deliberately have no estimate instead of borrowing another model's price.
struct CodexCostEstimate {
    private struct Rate {
        var input: Double
        var cached: Double
        var output: Double
        var longContextPremium = true
    }

    private static let rates: [String: Rate] = [
        "gpt-6-astra": .init(input: 10, cached: 1, output: 50),
        "gpt-6.1-sol": .init(input: 2, cached: 0.1, output: 10),
        "gpt-6.1-terra": .init(input: 1, cached: 0.05, output: 5),
        "gpt-6-sol": .init(input: 2, cached: 0.2, output: 10),
        "gpt-6-luna": .init(input: 0.1, cached: 0.01, output: 0.5),
        "gpt-5.6-sol": .init(input: 4, cached: 0.4, output: 20),
        "gpt-5.6-terra": .init(input: 2, cached: 0.2, output: 12),
        "gpt-5.6-luna": .init(input: 0.2, cached: 0.02, output: 1.2),
        "gpt-5.5": .init(input: 5, cached: 0.5, output: 30),
        "gpt-5.4": .init(input: 2.5, cached: 0.25, output: 15),
        "gpt-5.4-mini": .init(input: 0.75, cached: 0.075, output: 4.5, longContextPremium: false),
        "gpt-5.3-codex": .init(input: 1.75, cached: 0.175, output: 14, longContextPremium: false),
    ]

    private(set) var cost: Double?
    private var previousTotal: JSON?

    mutating func record(_ tokenUsage: JSON, model: String?, provider: String?) {
        guard provider == "openai", let model else { return }
        let selection = CodexCatalog.decode(model)
        guard selection.provider == nil || selection.provider == "openai", let slug = selection.model else { return }
        let base = slug.replacingOccurrences(of: #"-\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression)
        guard let rate = Self.rates[base == "gpt-5.6" ? "gpt-5.6-sol" : base] else { return }
        let total = tokenUsage["total"]
        if let total, total == previousTotal { return }
        guard let last = tokenUsage["last"],
              last["inputTokens"]?.double != nil, last["outputTokens"]?.double != nil else { return }
        let keys = ["inputTokens", "cachedInputTokens", "cacheWriteInputTokens", "outputTokens"]
        var counts: [String: Double] = [:]
        for key in keys {
            let count: Double
            if let previousTotal, let current = total?[key]?.double, let previous = previousTotal[key]?.double, current >= previous {
                count = current - previous
            } else { count = last[key]?.double ?? 0 }
            guard count.isFinite, count >= 0 else { return }
            counts[key] = count
        }
        // Input contains its cached subset; reasoning tokens are already in output.
        let input = counts["inputTokens"] ?? 0
        let cached = min(input, counts["cachedInputTokens"] ?? 0)
        let writes = min(input - cached, counts["cacheWriteInputTokens"] ?? 0)
        let longContext = rate.longContextPremium && (last["inputTokens"]?.double ?? input) > 272_000
        let inputFactor = longContext ? 2.0 : 1.0
        let outputFactor = longContext ? 1.5 : 1.0
        let added = ((input - cached - writes) * rate.input + cached * rate.cached + writes * rate.input * 1.25) * inputFactor
            + (counts["outputTokens"] ?? 0) * rate.output * outputFactor
        cost = (cost ?? 0) + added / 1_000_000
        previousTotal = total
    }
}
