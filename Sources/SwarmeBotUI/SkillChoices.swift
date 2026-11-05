import CompanionCore
import Foundation

/// One visible assignment, backed by the real skill ids sent to the engine.
struct SkillChoice: Identifiable {
    let id: String
    let title: String
    let description: String
    let skills: [Skill]
    let isGroup: Bool

    private var ids: Set<String> { Set(skills.map(\.id)) }
    var hasScripts: Bool { skills.contains { $0.hasScripts } }

    func assignedCount(in assigned: [BotSkill]) -> Int {
        Set(assigned.map(\.id)).intersection(ids).count
    }

    func defaultOnCount(in assigned: [BotSkill]) -> Int {
        Set(assigned.filter(\.defaultOn).map(\.id)).intersection(ids).count
    }

    func assigning(_ enabled: Bool, in assigned: [BotSkill]) -> [BotSkill] {
        // Explicit off entries override automatic assignments from a GitHub source.
        if !enabled && !isGroup { return assigned.filter { !ids.contains($0.id) } }
        var result = assigned.map { ids.contains($0.id) ? BotSkill(id: $0.id, defaultOn: enabled) : $0 }
        let present = Set(result.map(\.id))
        result += skills.filter { !present.contains($0.id) }.map { BotSkill(id: $0.id, defaultOn: enabled) }
        return result
    }

    func settingDefault(_ on: Bool, in assigned: [BotSkill]) -> [BotSkill] {
        assigned.map { ids.contains($0.id) ? BotSkill(id: $0.id, defaultOn: on) : $0 }
    }

    static func list(_ skills: [Skill], groups: [PluginSkillGroup]) -> [SkillChoice] {
        var grouped: [String: SkillChoice] = [:]
        var groupIDs = Set<String>()
        for group in groups where groupIDs.insert(group.id).inserted {
            let requested = Set(group.skillIDs)
            let members = skills.filter { requested.contains($0.id) && grouped[$0.id] == nil }
            guard !members.isEmpty else { continue }
            let choice = SkillChoice(id: "group:\(group.id)", title: group.title, description: group.description,
                                     skills: members, isGroup: true)
            for member in members { grouped[member.id] = choice }
        }
        var emitted = Set<String>()
        return skills.compactMap { skill in
            let choice = grouped[skill.id] ?? SkillChoice(id: "skill:\(skill.id)", title: skill.name,
                description: skill.description, skills: [skill], isGroup: false)
            return emitted.insert(choice.id).inserted ? choice : nil
        }
    }
}
