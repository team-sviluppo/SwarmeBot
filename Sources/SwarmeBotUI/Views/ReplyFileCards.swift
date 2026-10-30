import AppKit
import CompanionCore
import SwarmeKit
import SwiftUI
import UniformTypeIdentifiers

/// The files a settled bot reply points at, one card each: click to open,
/// the arrow to save a copy. On a remote engine the file is fetched first.
struct ReplyFileCards: View {
    let message: Message
    let threadId: String
    @Environment(AppModel.self) private var model
    @State private var files: [ReplyFile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(files) { ReplyFileCard(file: $0, threadId: threadId) }
        }
        .task(id: message.id) {
            files = await model.replyFiles(threadId: threadId, messageId: message.id, text: message.text ?? "")
        }
    }
}

private struct ReplyFileCard: View {
    let file: ReplyFile
    let threadId: String
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var busy = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 12)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await saveCopy() } } label: {
                    Image(systemName: "arrow.down.circle").font(.system(size: 17))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.secondary)
                .help(tr("Salva una copia…"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusBubble, style: .continuous).fill(hovering ? Theme.raised : Theme.bubbleBot))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusBubble, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { Task { await open() } }
        .help(file.path)
        .contextMenu {
            Button(tr("Apri")) { Task { await open() } }
            if !model.isRemote {
                Button(tr("Mostra nel Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
            }
            Button(tr("Salva una copia…")) { Task { await saveCopy() } }
            Button(tr("Copia percorso")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
    }

    private var icon: NSImage {
        if !model.isRemote { return NSWorkspace.shared.icon(forFile: file.path) }
        let type = UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    private func open() async {
        busy = true
        defer { busy = false }
        if let url = await model.localURL(for: file, threadId: threadId) { NSWorkspace.shared.open(url) }
    }

    private func saveCopy() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true
        defer { busy = false }
        guard let source = await model.localURL(for: file, threadId: threadId) else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            model.lastError = error.localizedDescription
        }
    }
}

extension View {
    /// Links in a reply that are not web addresses name a file: resolved
    /// against the chat's folder by the engine and opened like a file card.
    func replyFileLinks(threadId: String, model: AppModel) -> some View {
        environment(\.openURL, OpenURLAction { url in
            guard url.isFileURL || url.scheme == nil else { return .systemAction }
            let reference = url.isFileURL ? url.path : (url.absoluteString.removingPercentEncoding ?? url.absoluteString)
            Task { @MainActor in
                guard let file = await model.replyFile(threadId: threadId, reference: reference) else {
                    model.lastError = tr("File non trovato: %@", reference)
                    return
                }
                if let local = await model.localURL(for: file, threadId: threadId) { NSWorkspace.shared.open(local) }
            }
            return .handled
        })
    }
}
