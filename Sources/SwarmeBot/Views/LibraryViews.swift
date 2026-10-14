// The bot's library: PDFs and text files it uses as knowledge.
//
// The Libreria tab loads and removes them; the composer chip switches them
// on and off for the chat that is open. Every document starts on.
import AppKit
import CompanionCore
import SwarmeKit
import SwiftUI
import UniformTypeIdentifiers

enum LibraryFormat {
    static let types: [UTType] = [.pdf, .plainText, .commaSeparatedText] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
    static let extensions = ["pdf", "md", "markdown", "txt", "text", "csv"]
    /// The harness's limit for text sent whole (`Library.inlineBudget`).
    static let inlineBudget = 400_000

    static func tokens(_ count: Int) -> String {
        count < 1000 ? "\(count) token" : String(format: "~%.1fk token", Double(count) / 1000).replacingOccurrences(of: ".", with: ",")
    }

    static func summary(_ doc: LibraryDoc) -> String {
        var parts: [String] = []
        if doc.kind == "pdf" { parts.append(doc.pages == 1 ? "1 pagina" : "\(doc.pages) pagine") }
        parts.append(tokens(doc.tokens))
        if doc.ocrPages > 0 { parts.append(doc.ocrPages == 1 ? "OCR su 1 pagina" : "OCR su \(doc.ocrPages) pagine") }
        return parts.joined(separator: " · ")
    }

    /// Engines that only see text get the documents whole (or passages);
    /// the others open the files themselves.
    static func readsText(_ driverKind: String?) -> Bool {
        ["localEndpoint", "grok", "boxAgent"].contains(driverKind ?? "")
    }
}

// MARK: - Libreria tab

struct LibraryTab: View {
    let bot: Bot
    @Environment(AppModel.self) private var model
    @State private var docs: [LibraryDoc] = []
    @State private var loaded = false
    @State private var targeted = false
    @State private var preview: Preview?

    struct Preview: Identifiable {
        let doc: LibraryDoc
        let text: String
        var id: String { doc.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard("Documenti", accessory: {
                Button(action: pick) { Label("Aggiungi…", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle())
            }) {
                if docs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.badge.plus").font(.system(size: 22)).foregroundStyle(Theme.tertiary)
                        Text(loaded ? "Trascina qui PDF o file di testo" : "Caricamento…")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondary)
                        Text("Diventano la conoscenza di \(bot.name): ogni chat li usa, e puoi spegnerli chat per chat dal composer.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .padding(.horizontal, 16)
                } else {
                    ForEach(Array(docs.enumerated()), id: \.element.id) { index, doc in
                        if index > 0 { CardDivider(leading: 48) }
                        LibraryRow(doc: doc, onPreview: { open(doc) }, onDelete: { remove(doc) })
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.accent, lineWidth: 2)
                    .padding(.top, 26)
                    .opacity(targeted ? 1 : 0)
            )

            if !docs.isEmpty { footer }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .onDrop(of: [.fileURL], isTargeted: $targeted, perform: drop)
        .task(id: "\(bot.id):\(model.state.libraryRevision[bot.id] ?? 0)") { await reload() }
        .sheet(item: $preview) { preview in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(preview.doc.name).font(.headline).lineLimit(1)
                    Spacer()
                    Text(LibraryFormat.summary(preview.doc)).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
                ScrollView {
                    Text(preview.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inset))
                HStack {
                    Text("Il testo che il bot riceve, estratto dal file.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    Button("Chiudi") { self.preview = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 620, height: 520)
        }
    }

    private var footer: some View {
        let total = docs.filter { $0.status == "ready" }.reduce(0) { $0 + $1.tokens }
        let reader = LibraryFormat.readsText(model.instance(bot.modelSelection.instanceId)?.driverKind)
        let how = reader
            ? (total > LibraryFormat.inlineBudget
                ? "Insieme superano \(LibraryFormat.tokens(LibraryFormat.inlineBudget)): a ogni messaggio il modello riceve i passaggi più pertinenti."
                : "Il modello riceve il testo intero all'inizio di ogni chat; il server lo tiene in cache dal secondo messaggio.")
            : "Il bot riceve i percorsi e apre i documenti quando la domanda li riguarda."
        return Text("Totale \(LibraryFormat.tokens(total)). \(how)")
            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private func reload() async {
        docs = await model.library(bot)
        loaded = true
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = LibraryFormat.types
        panel.allowsMultipleSelection = true
        panel.prompt = "Aggiungi"
        panel.message = "Documenti per \(bot.name)"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in add([url]) }
            }
        }
        return !providers.isEmpty
    }

    private func add(_ urls: [URL]) {
        let accepted = urls.filter { LibraryFormat.extensions.contains($0.pathExtension.lowercased()) }
        if accepted.count < urls.count {
            model.lastError = "La libreria accetta PDF e file di testo (.md, .txt, .csv)."
        }
        guard !accepted.isEmpty else { return }
        Task {
            await model.addToLibrary(bot, accepted)
            await reload()
        }
    }

    private func remove(_ doc: LibraryDoc) {
        Task {
            await model.removeFromLibrary(bot, doc)
            await reload()
        }
    }

    private func open(_ doc: LibraryDoc) {
        Task {
            if let text = try? await model.client?.libraryText(botId: bot.id, docId: doc.id) {
                preview = Preview(doc: doc, text: text)
            }
        }
    }
}

private struct LibraryRow: View {
    let doc: LibraryDoc
    let onPreview: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: doc.kind == "pdf" ? "doc.richtext" : "doc.plaintext")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.name).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                status
            }
            Spacer(minLength: 6)
            if hovering || confirming {
                if doc.status == "ready" {
                    Button(action: onPreview) { Image(systemName: "eye") }
                        .buttonStyle(IconButtonStyle(size: 24, iconSize: 12))
                        .help("Vedi il testo estratto")
                }
                if confirming {
                    Button("Elimina") { confirming = false; onDelete() }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .tint(Theme.danger)
                } else {
                    Button { confirming = true } label: { Image(systemName: "trash") }
                        .buttonStyle(IconButtonStyle(size: 24, iconSize: 12))
                        .help("Rimuovi dalla libreria")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if !inside { confirming = false }
        }
    }

    private var tint: Color {
        switch doc.status {
        case "failed": return Theme.danger
        case "processing": return Theme.secondary
        default: return Theme.accent
        }
    }

    @ViewBuilder private var status: some View {
        switch doc.status {
        case "processing":
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Conversione in corso…")
            }
            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
        case "failed":
            Text(doc.error ?? "Conversione non riuscita").font(.system(size: 11.5)).foregroundStyle(Theme.danger).lineLimit(2)
        default:
            Text(LibraryFormat.summary(doc)).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: - Composer chip

/// Which documents this chat uses. Hidden while the bot has none.
struct LibraryChip: View {
    let bot: Bot
    @Environment(AppModel.self) private var model
    @State private var docs: [LibraryDoc] = []
    @State private var open = false

    private var off: [String] { bot.tasks?.first { $0.threadId == bot.threadId }?.libraryOff ?? [] }
    private var ready: [LibraryDoc] { docs.filter { $0.status == "ready" } }
    private var active: [LibraryDoc] { ready.filter { !off.contains($0.id) } }

    var body: some View {
        Group {
            if !docs.isEmpty {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "books.vertical").font(.system(size: 12))
                        Text("\(active.count)/\(ready.count)").font(.system(size: Theme.uiSize, weight: .medium)).monospacedDigit()
                    }
                    .fixedSize()
                    .padding(.vertical, 1)
                    .foregroundStyle(active.isEmpty ? Theme.tertiary : Theme.secondary)
                }
                .buttonStyle(ChipButtonStyle(filled: true, size: Theme.uiSize))
                .help("Documenti usati in questa chat")
                .popover(isPresented: $open, arrowEdge: .top) { popover }
            }
        }
        .task(id: "\(bot.id):\(model.state.libraryRevision[bot.id] ?? 0)") { docs = await model.library(bot) }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Documenti in questa chat").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            ForEach(docs) { doc in
                HStack(spacing: 8) {
                    Image(systemName: doc.kind == "pdf" ? "doc.richtext" : "doc.plaintext")
                        .font(.system(size: 12)).foregroundStyle(Theme.tertiary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(doc.name).font(.system(size: 12.5)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        Text(doc.status == "ready" ? LibraryFormat.summary(doc) : doc.status == "processing" ? "Conversione in corso…" : (doc.error ?? "Non riuscito"))
                            .font(.system(size: 11)).foregroundStyle(doc.status == "failed" ? Theme.danger : Theme.tertiary)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: Binding(
                        get: { !off.contains(doc.id) },
                        set: { on in Task { await model.setLibraryDoc(bot, doc, on: on) } }
                    ))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(doc.status != "ready")
                }
            }
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var note: String? {
        guard LibraryFormat.readsText(model.instance(bot.modelSelection.instanceId)?.driverKind) else { return nil }
        let total = active.reduce(0) { $0 + $1.tokens }
        guard total > LibraryFormat.inlineBudget else { return nil }
        return "Insieme superano \(LibraryFormat.tokens(LibraryFormat.inlineBudget)): il modello riceverà solo i passaggi più pertinenti a ogni messaggio."
    }
}
