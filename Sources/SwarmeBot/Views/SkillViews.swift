// Skills on a bot and in a chat (docs/plans/2026-10-21-skill.md): the bot's
// card picks which ones it may use and which start on; the chip under the
// composer switches them for the chat that is open, and `/name` in a
// message calls one whatever its switch.
import CompanionCore
import SwarmeKit
import SwiftUI

/// Dettagli › Skill.
struct BotSkillsCard: View {
    let bot: Bot
    @Environment(AppModel.self) private var model

    private var assigned: [BotSkill] { bot.skills ?? [] }

    var body: some View {
        SettingsCard(tr("Skill")) {
            if model.skills.isEmpty {
                SettingRow(icon: "wand.and.stars", tint: Theme.accentText, title: tr("Nessuna skill"),
                           subtitle: tr("Aggiungile in Impostazioni › Skill, poi scegli qui quali usa questo bot.")) {
                    SettingsLink { Text(tr("Apri")) }
                }
            } else {
                ForEach(Array(model.skills.enumerated()), id: \.element.id) { index, skill in
                    if index > 0 { CardDivider(leading: 48) }
                    row(skill)
                }
            }
        }
    }

    private func row(_ skill: Skill) -> some View {
        let entry = assigned.first { $0.id == skill.id }
        return SettingRow(icon: skill.hasScripts ? "terminal" : "wand.and.stars", tint: Theme.accentText,
                          title: skill.name, subtitle: skill.description) {
            HStack(spacing: 10) {
                if let entry {
                    Toggle(tr("Accesa nelle nuove chat"), isOn: Binding(get: { entry.defaultOn }, set: { on in
                        save(assigned.map { $0.id == skill.id ? BotSkill(id: $0.id, defaultOn: on) : $0 })
                    }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .help(tr("Se spenta, il bot non la vede finché non la accendi nella chat o la richiami con /%@.", skill.id))
                }
                Toggle("", isOn: Binding(get: { entry != nil }, set: { use in
                    save(use ? assigned + [BotSkill(id: skill.id, defaultOn: true)] : assigned.filter { $0.id != skill.id })
                }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.accent)
            }
        }
    }

    private func save(_ list: [BotSkill]) {
        Task { await model.setSkills(bot, list) }
    }
}

/// Under the composer, next to the connectors: the open chat's skills.
struct SkillsChip: View {
    let bot: Bot
    @Environment(AppModel.self) private var model
    @State private var open = false

    private var skills: [Skill] { model.assignedSkills(bot) }
    private var active: [Skill] { skills.filter { model.skillIsOn(bot, $0.id) } }
    private var hasOverrides: Bool { !(bot.tasks?.first { $0.threadId == bot.threadId }?.skills ?? [:]).isEmpty }

    var body: some View {
        if !skills.isEmpty {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 12))
                    Text(verbatim: "\(active.count)/\(skills.count)")
                        .font(.system(size: Theme.uiSize, weight: .medium)).monospacedDigit()
                }
                .fixedSize()
                .padding(.vertical, 1)
                .foregroundStyle(active.isEmpty ? Theme.tertiary : Theme.secondary)
            }
            .buttonStyle(ChipButtonStyle(filled: true, size: Theme.uiSize))
            .help(tr("Skill in questa chat"))
            .popover(isPresented: $open, arrowEdge: .top) { popover }
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Skill in questa chat")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            ForEach(skills) { skill in
                HStack(spacing: 8) {
                    Image(systemName: skill.hasScripts ? "terminal" : "wand.and.stars")
                        .font(.system(size: 12)).foregroundStyle(Theme.tertiary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "/\(skill.id)").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(skill.description).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(2)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: Binding(
                        get: { model.skillIsOn(bot, skill.id) },
                        set: { on in Task { await model.setSkill(bot, skill.id, on: on) } }
                    ))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
            HStack {
                Spacer()
                if hasOverrides {
                    Button(tr("Ripristina predefinite")) { Task { await model.resetSkills(bot) } }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            Text(tr("Le accese il bot le usa quando servono. Scrivi /nome per usarne una di sicuro, anche se spenta."))
                .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340)
    }
}
