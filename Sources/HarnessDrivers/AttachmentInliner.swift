// Attachments for engines with no filesystem (the OpenAI-compatible Local
// Endpoint). The composer sends `<attached-image path="…"/>` and
// `<attached-file path="…"/>` tags, which an agent CLI opens by itself; an
// HTTP model would only see a path it cannot reach. So for the latest user
// message the tags become content: images as `image_url` data URLs (sent
// whatever the model, an endpoint that cannot see them says so), text files
// inline, PDFs as their extracted text. Older messages keep a short label,
// so a long chat does not resend every file on every turn.
import Foundation
import HarnessCore
import PDFKit
import UniformTypeIdentifiers

enum AttachmentInliner {
    /// Plain text, code, CSV, JSON…: bytes read from disk.
    static let textLimit = 200_000
    /// PDFs: the file itself, then the text extracted from it.
    static let pdfFileLimit = 100 * 1024 * 1024
    static let pdfTextLimit = 2_000_000
    static let imageLimit = 20 * 1024 * 1024

    private static let tag = try! NSRegularExpression(pattern: #"<attached-(image|file) path="([^"]*)"\s*/>"#)

    struct Attachment {
        enum Kind { case image, file }
        var kind: Kind
        var path: String
        var range: Range<String.Index>
    }

    static func attachments(in text: String) -> [Attachment] {
        tag.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text),
                  let kindRange = Range(match.range(at: 1), in: text),
                  let pathRange = Range(match.range(at: 2), in: text) else { return nil }
            return Attachment(kind: text[kindRange] == "image" ? .image : .file, path: unescape(String(text[pathRange])), range: range)
        }
    }

    /// The latest user message: a plain string when nothing is attached,
    /// otherwise OpenAI content parts.
    static func content(_ text: String) -> JSON {
        let found = attachments(in: text)
        guard !found.isEmpty else { return .string(text) }
        var parts: [JSON] = []
        var images: [JSON] = []
        var body = ""
        var cursor = text.startIndex
        for attachment in found {
            body += text[cursor..<attachment.range.lowerBound]
            cursor = attachment.range.upperBound
            let name = (attachment.path as NSString).lastPathComponent
            switch attachment.kind {
            case .image:
                if let url = imageDataURL(attachment.path) {
                    images.append(["type": "image_url", "image_url": ["url": .string(url)]])
                    body += "[immagine allegata: \(name)]"
                } else {
                    body += "[immagine allegata non leggibile: \(name)]"
                }
            case .file:
                body += fileBlock(attachment.path)
            }
        }
        body += text[cursor...]
        parts.append(["type": "text", "text": .string(body)])
        return .array(parts + images)
    }

    /// History: tags become a label, the content was sent on its own turn.
    static func label(_ text: String) -> String {
        var out = ""
        var cursor = text.startIndex
        for attachment in attachments(in: text) {
            out += text[cursor..<attachment.range.lowerBound]
            cursor = attachment.range.upperBound
            let name = (attachment.path as NSString).lastPathComponent
            out += attachment.kind == .image ? "[immagine allegata: \(name)]" : "[file allegato: \(name)]"
        }
        return out + text[cursor...]
    }

    /// Whether this file can travel as text (or PDF text) to a remote model.
    static func isInlinable(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let type = UTType(filenameExtension: url.pathExtension) else { return looksLikeText(url) }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .sourceCode)
            || type.conforms(to: .json) || type.conforms(to: .xml) || type.conforms(to: .commaSeparatedText) { return true }
        if type.conforms(to: .image) || type.conforms(to: .audiovisualContent) || type.conforms(to: .archive)
            || type.conforms(to: .executable) { return false }
        return looksLikeText(url)
    }

    // MARK: Pieces

    private static func imageDataURL(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= imageLimit else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func fileBlock(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return "[file allegato non trovato: \(name)]"
        }
        if isDirectory.boolValue { return "[cartella allegata: \(name) — questo modello non può aprire cartelle]" }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0

        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            guard size <= pdfFileLimit else { return "[PDF allegato troppo grande: \(name), oltre \(pdfFileLimit / 1024 / 1024) MB]" }
            guard let text = PDFDocument(url: url)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return "[PDF allegato senza testo estraibile (forse scansionato): \(name)]"
            }
            return block(name, text, limit: pdfTextLimit)
        }
        guard isInlinable(path), let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return "[file allegato in un formato che questo modello non può leggere: \(name)]"
        }
        return block(name, String(decoding: data.prefix(textLimit), as: UTF8.self), limit: textLimit, truncated: data.count > textLimit)
    }

    private static func block(_ name: String, _ text: String, limit: Int, truncated: Bool = false) -> String {
        let cut = truncated || text.count > limit
        let body = text.count > limit ? String(text.prefix(limit)) : text
        return "<attached-file name=\"\(name)\"\(cut ? " truncated=\"true\"" : "")>\n\(body)\n</attached-file>"
    }

    /// No NUL in the first 8 KB, and it decodes as UTF-8.
    private static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        return !head.contains(0) && String(data: head, encoding: .utf8) != nil
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#9;", with: "\t")
            .replacingOccurrences(of: "&#13;", with: "\r")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
