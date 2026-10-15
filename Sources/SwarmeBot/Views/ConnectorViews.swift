// Connectors on a bot and in a chat (docs/plans/2026-10-15-connettori-mcp.md §7):
// the bot's card picks which ones it may use and which start on; the chip
// under the composer switches them for the chat that is open.
import CompanionCore
import SwarmeKit
import SwiftUI

/// Dettagli › Connettori.
struct BotConnectorsCard: View {
    let bot: Bot
    @Environment(AppModel.self) private var model

    private var assigned: [BotConnector] { bot.connectors ?? [] }

    var body: some View {
        SettingsCard("Connettori") {
            if model.mcpConnectors.isEmpty {
                SettingRow(icon: "puzzlepiece.extension", tint: Theme.accentText, title: "Nessun connettore",
                           subtitle: "Aggiungili in Impostazioni › Connettori, poi scegli qui quali usa questo bot.") {
                    SettingsLink { Text("Apri") }
                }
            } else {
                if model.connectorMount(bot) == "none" {
                    Text("Il motore scelto per questo bot non usa i connettori: valgono con Claude, Codex e gli agenti ACP.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.top, 9)
                }
                ForEach(Array(model.mcpConnectors.enumerated()), id: \.element.id) { index, connector in
                    if index > 0 { CardDivider(leading: 48) }
                    row(connector)
                }
            }
        }
    }

    private func row(_ connector: MCPConnector) -> some View {
        let entry = assigned.first { $0.id == connector.id }
        return SettingRow(icon: "puzzlepiece.extension", tint: connector.isEnabled ? Theme.accentText : Theme.tertiary,
                          title: connector.name, subtitle: subtitle(connector)) {
            HStack(spacing: 10) {
                if let entry {
                    Toggle("Acceso nelle nuove chat", isOn: Binding(get: { entry.defaultOn }, set: { on in
                        save(assigned.map { $0.id == connector.id ? BotConnector(id: $0.id, defaultOn: on) : $0 })
                    }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .help("Se spento, il bot lo ha a disposizione ma va acceso chat per chat: risparmia contesto.")
                }
                Toggle("", isOn: Binding(get: { entry != nil }, set: { use in
                    save(use ? assigned + [BotConnector(id: connector.id, defaultOn: true)] : assigned.filter { $0.id != connector.id })
                }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.accent)
            }
        }
    }

    private func subtitle(_ connector: MCPConnector) -> String {
        if !connector.isEnabled { return "Disattivato nelle impostazioni" }
        var parts: [String] = [connector.transport == "http" ? "HTTP" : "stdio"]
        if let tokens = connector.estimatedTokens { parts.append("~\(tokens) token") }
        if connector.lastCheck?.ok == false { parts.append("ultima prova non riuscita") }
        return parts.joined(separator: " · ")
    }

    private func save(_ list: [BotConnector]) {
        Task { await model.setConnectors(bot, list) }
    }
}

/// Under the composer, next to the library: the open chat's connectors.
struct ConnectorsChip: View {
    let bot: Bot
    @Environment(AppModel.self) private var model
    @State private var open = false

    private var connectors: [MCPConnector] {
        let ids = (bot.connectors ?? []).map(\.id)
        return ids.compactMap { id in model.mcpConnectors.first { $0.id == id } }
    }

    private var supported: Bool { model.connectorMount(bot) != "none" }
    private var active: [MCPConnector] { connectors.filter { $0.isEnabled && model.connectorIsOn(bot, $0.id) } }
    private var hasOverrides: Bool { !(bot.tasks?.first { $0.threadId == bot.threadId }?.connectors ?? [:]).isEmpty }

    var body: some View {
        if !connectors.isEmpty {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 12))
                    Text("\(supported ? active.count : 0)/\(connectors.count)")
                        .font(.system(size: Theme.uiSize, weight: .medium)).monospacedDigit()
                }
                .fixedSize()
                .padding(.vertical, 1)
                .foregroundStyle(!supported || active.isEmpty ? Theme.tertiary : Theme.secondary)
            }
            .buttonStyle(ChipButtonStyle(filled: true, size: Theme.uiSize))
            .help(supported ? "Connettori in questa chat" : "Il motore di questo bot non usa i connettori")
            .popover(isPresented: $open, arrowEdge: .top) { popover }
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connettori in questa chat").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            if !supported {
                Text("Il motore scelto per questo bot non usa i connettori: valgono con Claude, Codex e gli agenti ACP.")
                    .font(.system(size: 11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(connectors) { connector in
                HStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 12)).foregroundStyle(Theme.tertiary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(connector.name).font(.system(size: 12.5)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(detail(connector)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: Binding(
                        get: { model.connectorIsOn(bot, connector.id) },
                        set: { on in Task { await model.setConnector(bot, connector.id, on: on) } }
                    ))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(!supported || !connector.isEnabled)
                }
            }
            HStack {
                let tokens = active.compactMap(\.estimatedTokens).reduce(0, +)
                if supported, tokens > 0 {
                    Text("~\(tokens) token di strumenti per turno").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                Spacer()
                if hasOverrides {
                    Button("Ripristina predefiniti") { Task { await model.resetConnectors(bot) } }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            Text("Valgono dal prossimo messaggio.").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func detail(_ connector: MCPConnector) -> String {
        if !connector.isEnabled { return "disattivato nelle impostazioni" }
        let fallback = bot.connectors?.first { $0.id == connector.id }?.defaultOn ?? false
        var parts = [fallback ? "acceso di default" : "spento di default"]
        if let tokens = connector.estimatedTokens { parts.append("~\(tokens) token") }
        return parts.joined(separator: " · ")
    }
}
