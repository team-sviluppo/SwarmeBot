// A PDF attached to a message, as its text: extracted here with PDFKit, so
// every bot can read it — a phone bot, an OpenAI-compatible endpoint that
// takes no files, a remote bot on a Linux engine (which cannot extract PDFs).
// It travels in the prompt in the engine's own `<attached-file>` block.
import Foundation
import PDFKit

struct AttachedDocument: Codable, Hashable, Sendable {
    /// Characters kept from one PDF, as the engine keeps from a text file.
    static let limit = 200_000

    var name: String
    var text: String
    var truncated = false

    /// The block the model reads; the apps show it as the file's name.
    var promptBlock: String {
        let escaped = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        return "<attached-file name=\"\(escaped)\"\(truncated ? " truncated=\"true\"" : "")>\n\(text)\n</attached-file>"
    }

    /// A PDF the file importer handed over (outside the app's sandbox).
    static func pdf(at url: URL) throws -> AttachedDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url) else {
            throw DocumentError(message: tr("Il PDF non si apre."))
        }
        let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw DocumentError(message: tr("Il PDF non contiene testo da leggere (forse è una scansione)."))
        }
        return AttachedDocument(name: url.lastPathComponent, text: String(text.prefix(limit)), truncated: text.count > limit)
    }

    /// The blocks in a stored prompt, shown as a file's name.
    static func displayed(_ text: String) -> String {
        text.replacingOccurrences(of: #"<attached-file name="([^"]*)"[^>]*>[\s\S]*?</attached-file>\n*"#,
                                  with: "📄 $1\n", options: .regularExpression)
    }
}

struct DocumentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
