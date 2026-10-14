import AppKit
import CompanionCore
import SwarmeKit
import SwiftUI

/// Provider logo from Lobe Icons (`@lobehub/icons-static-svg`), bundled so the
/// picker does not wait on the network. Engines with no vendor (Box, a local
/// endpoint) get a system symbol; anything else falls back to initials.
struct ProviderMark: View {
    var driverKind: String?
    let name: String
    var size: CGFloat = 14

    var body: some View {
        if let logo = ProviderLogo.image(for: driverKind) {
            Image(nsImage: logo.image)
                .resizable()
                .renderingMode(logo.template ? .template : .original)
                .foregroundStyle(Theme.ink)
                .scaledToFit()
                .frame(width: size, height: size)
        } else if let symbol = ProviderLogo.symbol(for: driverKind) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.82, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.85))
                .frame(width: size, height: size)
        } else {
            Text(initials)
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: size + 4, height: size)
        }
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

enum ProviderLogo {
    struct Mark {
        var image: NSImage
        /// Mono marks use `currentColor`; tint them with the interface color.
        var template: Bool
    }

    private static let color = Set(["claude", "kimi", "gemini", "qwen", "deepseek", "antigravity"])
    private static let slug: [String: String] = [
        "claudeAgent": "claude", "claude": "claude",
        "codex": "codex",
        "grok": "grok", "grokAgent": "grok",
        "kimiAgent": "kimi",
        "cursorAgent": "cursor",
        "geminiAgent": "gemini",
        "qwenAgent": "qwen",
        "deepseekHarness": "deepseek",
        "opencodeGo": "opencode",
        "hermesAgent": "hermes",
        "antigravityAgent": "antigravity",
        "piAgent": "pi",
        "droidAgent": "droid",
    ]
    /// Generic on purpose: these run whatever the user points them at.
    private static let symbols: [String: String] = [
        "boxAgent": "shippingbox",
        "localEndpoint": "server.rack",
    ]

    static func symbol(for driverKind: String?) -> String? { driverKind.flatMap { symbols[$0] } }
    private static var cache: [String: Mark] = [:]

    static func image(for driverKind: String?) -> Mark? {
        guard let driverKind, let slug = slug[driverKind] else { return nil }
        if let cached = cache[slug] { return cached }
        guard let url = Bundle.resources.url(forResource: slug, withExtension: "svg", subdirectory: "ProviderIcons")
                ?? Bundle.resources.url(forResource: slug, withExtension: "svg"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let image = SVGMark.render(text, side: 64) else { return nil }
        let mark = Mark(image: image, template: !color.contains(slug))
        cache[slug] = mark
        return mark
    }
}

/// The model pill of the chat header: capsule, `hairline/40` border on
/// `raised/60`, provider mark 14, label (≤160) 13 ink, chevron that turns
/// when open. Opens the picker popover.
struct ModelPickerButton: View {
    let bot: Bot
    @Environment(AppModel.self) private var model
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let instance = model.instance(bot.modelSelection.instanceId)
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                ProviderMark(driverKind: instance?.driverKind, name: instance?.displayName ?? instance?.driverKind ?? "?")
                Text(chipText(model.modelLabel(for: bot), 28))
                    .font(.system(size: Theme.uiSize, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if let effort = bot.modelSelection.effort {
                    Text(EffortLevel.label(effort))
                        .font(.system(size: Theme.captionSize))
                        .foregroundStyle(Theme.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .animation(Theme.quick, value: open)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(hovering || open ? Theme.raised : Theme.raised.opacity(0.6)))
            .overlay(Capsule().stroke(Theme.hairline.opacity(0.4)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Modello e motore")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ModelPickerPopover(bot: bot) { open = false }
                .environment(model)
        }
    }
}

/// 380 × ≤480: provider rail (56) on the left, that engine's models on the
/// right, effort at the bottom when the engine offers it.
struct ModelPickerPopover: View {
    let bot: Bot
    let done: () -> Void
    @Environment(AppModel.self) private var model
    @State private var engine: String?
    @State private var filter = ""

    var body: some View {
        let instances = model.instances.filter { $0.pickerVisible != false && $0.snapshot.isAvailable }
        let current = engine ?? (instances.contains { $0.instanceId == bot.modelSelection.instanceId }
            ? bot.modelSelection.instanceId : instances.first?.instanceId ?? bot.modelSelection.instanceId)
        let selected = instances.first { $0.instanceId == current }
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(instances) { instance in
                        Button {
                            engine = instance.instanceId
                        } label: {
                            ProviderMark(driverKind: instance.driverKind, name: instance.displayName ?? instance.driverKind, size: 18)
                                .frame(width: 36, height: 36)
                                .background(RoundedRectangle(cornerRadius: 8).fill(instance.instanceId == current ? Theme.raised : .clear))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(instance.instanceId == current ? Theme.hairline.opacity(0.5) : .clear))
                                .overlay(alignment: .topTrailing) {
                                    if !instance.snapshot.isAvailable {
                                        Circle().fill(Theme.warning).frame(width: 6, height: 6)
                                            .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                                            .offset(x: -3, y: 3)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(instance.displayName ?? instance.driverKind)
                    }
                }
                .padding(8)
            }
            .frame(width: 56)
            .background(Theme.panel)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline.opacity(0.4)).frame(width: 1) }

            VStack(alignment: .leading, spacing: 0) {
                if let selected {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(selected.displayName ?? selected.driverKind)
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                            Text(selected.snapshot.isAvailable ? "Connesso" : "Non disponibile")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(selected.snapshot.isAvailable ? Theme.success : Theme.warning)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill((selected.snapshot.isAvailable ? Theme.success : Theme.warning).opacity(0.1)))
                        }
                        Text(selected.snapshot.isAvailable ? selected.driverKind : (selected.snapshot.reason ?? "Motore non disponibile"))
                            .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        TextField("", text: $filter, prompt: Text("Cerca modelli").foregroundStyle(Theme.secondary))
                            .textFieldStyle(.plain).font(.system(size: 12.5))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.inset))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline.opacity(0.4)))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(selected.models.options.filter { filter.isEmpty || $0.label.localizedCaseInsensitiveContains(filter) }) { option in
                                let isCurrent = bot.modelSelection.instanceId == selected.instanceId
                                    && bot.modelSelection.model == option.id
                                Button {
                                    let levels = selected.effortLevels(for: option.id)
                                    let effort = bot.modelSelection.effort.flatMap { levels.contains($0) ? $0 : nil }
                                    Task { await model.setModel(bot, instanceId: selected.instanceId, model: option.id, effort: effort) }
                                    done()
                                } label: {
                                    HStack {
                                        Text(option.label).font(.system(size: 13)).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if isCurrent { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent) }
                                    }
                                    .foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                    .hoverHighlight(selected: isCurrent, radius: 8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    let levels = selected.effortLevels(for: bot.modelSelection.model)
                    if bot.modelSelection.instanceId == selected.instanceId, !levels.isEmpty {
                        EffortPicker(levels: levels, current: bot.modelSelection.effort) { level in
                            Task {
                                await model.setModel(bot, instanceId: selected.instanceId, model: bot.modelSelection.model, effort: level)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline.opacity(0.4)).frame(height: 1) }
                    }
                } else {
                    Text("Nessun motore configurato")
                        .foregroundStyle(Theme.secondary)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 380, height: 440)
        .background(Theme.card)
        .task { await model.refreshInstances() }
    }
}

/// Display names for the effort levels the engines report.
enum EffortLevel {
    static func label(_ level: String) -> String {
        switch level.lowercased() {
        case "xhigh": return "XHigh"
        case "max": return "Max"
        default: return level.prefix(1).uppercased() + level.dropFirst()
        }
    }
}

/// Segmented control: every level on one line, the current one raised.
struct EffortPicker: View {
    let levels: [String]
    let current: String?
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent").font(.system(size: 12))
                Text("Effort").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.secondary)
            HStack(spacing: 2) {
                ForEach(levels, id: \.self) { level in
                    let on = current == level
                    Button { pick(level) } label: {
                        Text(EffortLevel.label(level))
                            .font(.system(size: 12, weight: on ? .semibold : .regular))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(on ? Theme.ink : Theme.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.raisedHover : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.inset))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.hairline.opacity(0.5)))
            .animation(Theme.quick, value: current)
        }
    }
}

/// Single-line chip text: long names end in an ellipsis at a fixed length,
/// so the chip keeps its own size and its neighbours stay next to it.
func chipText(_ text: String, _ limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
}
