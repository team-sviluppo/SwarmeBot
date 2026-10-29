// Files a message refers to: the chips above the field, the search that adds them (⌘P),
// and the way a file dragged in from Finder becomes one. A reference is a path, not an upload:
// the agent reads the file itself, so it works with an engine on a server too.
import AppKit
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

/// One chip per file, in the row of the attachments.
struct FileReferenceChip: View {
    let file: FileReference
    let state: CodeState
    let threadId: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").foregroundStyle(Theme.accentText)
            Text(verbatim: file.name).font(.system(size: 11.5)).foregroundStyle(Theme.ink).lineLimit(1)
            Button { state.removeReference(file.path, threadId: threadId) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.inset))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.35), lineWidth: 1))
        .help(file.path)
    }
}

/// "File" under the composer, and ⌘P: a search over the repository's files.
struct CodeFilePicker: View {
    let chat: CodeChat
    let state: CodeState
    @Environment(AppModel.self) private var model
    @State private var open = false
    @State private var query = ""
    @State private var results: [CodeFile] = []
    @State private var highlighted = 0
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        Button { query = ""; open = true } label: {
            Label(tr("File"), systemImage: "paperclip").fixedSize()
        }
        .buttonStyle(ChipButtonStyle(filled: true, size: Theme.uiSize))
        .keyboardShortcut("p", modifiers: .command)
        .help(tr("Cita un file del progetto nel messaggio (⌘P)"))
        .popover(isPresented: $open) { picker }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(tr("Cerca un file"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { pick(highlighted) }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(results.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, file in
                            Button { pick(index) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text").foregroundStyle(Theme.secondary)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(verbatim: file.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                        Text(verbatim: (file.relative as NSString).deletingLastPathComponent)
                                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.head)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(index == highlighted ? Theme.raised : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(file.id)
                        }
                    }
                }
                .frame(height: 260)
                .onChange(of: highlighted) { _, index in
                    if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                }
            }
            if results.isEmpty && !searching { Text(tr("Nessun file trovato")).font(.system(size: 12)).foregroundStyle(Theme.tertiary) }
        }
        .padding(12)
        .frame(width: 380)
        .onAppear { focused = true }
        // a key a time is a request a time: wait for a pause
        .task(id: query) {
            searching = true
            defer { searching = false }
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 120_000_000) }
            guard !Task.isCancelled else { return }
            results = await state.searchFiles(model: model, threadId: chat.threadId, query: query)
            highlighted = 0
        }
    }

    private func pick(_ index: Int) {
        guard results.indices.contains(index) else { return }
        state.addReference(FileReference(path: results[index].path), threadId: chat.threadId)
        open = false
    }
}

/// Files dropped on the composer that lie inside the chat's folder, on this Mac: those are
/// references (the agent reads them where they are). Images stay attachments, as ever.
enum DroppedFiles {
    static func claimable(_ urls: [URL], folders: [String]) -> [URL] {
        let roots = folders.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        return urls.filter { url in
            guard !isImage(url) else { return false }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
            let path = url.resolvingSymlinksInPath().path
            return roots.contains { path.hasPrefix($0 + "/") }
        }
    }

    private static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(url.pathExtension.lowercased())
    }
}
