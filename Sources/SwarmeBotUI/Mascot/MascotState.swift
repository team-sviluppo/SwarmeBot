// Which face a bot wears — the desktop's `stateForBot`, ported via the iOS
// companion. A pinned expression wins; then what the bot is doing right now;
// then a guess from its role. Same rules, same order, so a bot looks the
// same here as in the Electron app and on the phone.
import CompanionCore
import Foundation

extension SwarmeState {
    /// The desktop's legacy names, kept so an older bot record still resolves.
    private static let legacy: [String: SwarmeState] = [
        "deadpan": .idle, "friendly": .happy, "focused": .working, "thinking": .thinking,
        "excited": .excited, "sleepy": .drowsy, "surprised": .surprised, "skeptical": .suspicious,
        "worried": .scared, "mischievous": .playful,
    ]

    /// Resolves any stored value — current, legacy or junk — to a real state.
    static func normalize(_ value: String?) -> SwarmeState? {
        guard let value, !value.isEmpty else { return nil }
        return SwarmeState(rawValue: value) ?? legacy[value]
    }

    static func forBot(_ bot: Bot, last: Message?) -> SwarmeState {
        if let pinned = normalize(bot.mascotExpression) { return pinned }

        if last?.kind == .activity, last?.tool?.ok == false { return .alerting }
        if bot.activity == "waiting-on-you" { return .curious }
        if bot.busy == true || bot.activity == "working" { return .working }
        if bot.unread { return .notifying }
        if last?.kind == .options { return .curious }

        let profile = "\(bot.name) \(bot.title) \(bot.description)".lowercased()
        func matches(_ words: [String]) -> Bool {
            words.contains { word in
                profile.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
            }
        }
        if matches(["code", "coding", "developer", "development", "engineer", "engineering", "build", "debug", "program", "software"]) { return .working }
        if matches(["research", "researcher", "search", "investigate", "strategy", "strategist", "study", "learn", "knowledge"]) { return .searching }
        if matches(["marketing", "growth", "launch", "campaign", "social", "sales", "outreach", "brand"]) { return .excited }
        if matches(["overnight", "night", "background", "async", "queue", "batch", "long-running"]) { return .drowsy }
        if matches(["monitor", "monitoring", "incident", "alert", "watch", "status", "uptime"]) { return .radar }
        if matches(["review", "reviewer", "audit", "critic", "critique", "quality", "qa", "test", "legal"]) { return .suspicious }
        if matches(["security", "secure", "compliance", "risk", "privacy", "finance", "financial"]) { return .scared }
        if matches(["design", "designer", "creative", "brainstorm", "art", "illustration", "music", "story"]) { return .playful }
        if matches(["support", "help", "success", "onboarding", "coach", "teacher", "guide", "welcome"]) { return .happy }
        return restingFace(for: bot.id.isEmpty ? bot.name : bot.id)
    }

    /// `restingFaceFor`: FNV-1a (32-bit, over UTF-16 code units like JS
    /// `charCodeAt`) of the bot's identity, modulo RESTING_FACES — varied
    /// across a roster, fixed for each bot.
    static func restingFace(for identity: String) -> SwarmeState {
        var h: UInt32 = 0x811c9dc5
        for unit in identity.utf16 {
            h ^= UInt32(unit)
            h = h &* 0x01000193
        }
        let faces = SwarmeFaceData.restingFaces
        return faces[Int(h % UInt32(faces.count))]
    }
}
