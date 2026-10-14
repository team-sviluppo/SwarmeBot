// A bot's library: documents the user loads on the bot, used as knowledge
// in its chats. It replaces the MEMORY.md the bot was meant to curate itself.
//
// Each document is converted once, on import, into Markdown (PDFKit text,
// Vision OCR for pages with none) and cut into passages with an embedding.
// A turn then carries the documents its chat has switched on:
//
// - engines with a filesystem (Claude, Codex, ACP…) get the paths and read
//   the text themselves when the question needs it;
// - engines without one (Local Endpoint, Grok, Box agent) get the whole text
//   in the system prompt, before the history, so a server's prompt cache
//   reuses it from the second turn on. Past `inlineBudget` tokens only the
//   passages closest to the latest message go, ranked by keywords (BM25) and
//   meaning (NLContextualEmbedding).
//
// Files: `workspaces/<bot>/library/index.json`, and per document the
// original `<id>.<ext>`, its text `<id>.md`, its passages `<id>.passages.json`.
import CoreGraphics
import Foundation
import NaturalLanguage
import PDFKit
import Vision

public struct LibraryDoc: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// "pdf" or "text".
    public var kind: String
    public var bytes: Int
    public var pages: Int
    public var chars: Int
    public var tokens: Int
    /// Pages read with OCR: scanned, or text drawn as pictures.
    public var ocrPages: Int
    /// processing, ready, failed.
    public var status: String
    public var error: String?
    public var createdAt: Double

    var json: JSON {
        JSON.object(JSONObject([
            ("id", .string(id)), ("name", .string(name)), ("kind", .string(kind)), ("bytes", .number(Double(bytes))),
            ("pages", .number(Double(pages))), ("chars", .number(Double(chars))), ("tokens", .number(Double(tokens))),
            ("ocrPages", .number(Double(ocrPages))), ("status", .string(status)), ("error", JSON.from(error)),
            ("createdAt", .number(createdAt)),
        ]))
    }
}

public struct LibraryPassage: Codable, Equatable, Sendable {
    public var page: Int
    public var text: String
    /// Unit length; nil when no embedding model was available.
    public var vector: [Float]?
}

/// What a turn carries from the library.
public enum LibraryMode: Equatable, Sendable {
    /// The engine opens files itself.
    case paths
    /// The engine only sees text.
    case inline
}

@MainActor
public final class Library {
    public static let maxFileBytes = 200 * 1024 * 1024
    /// Past this, the documents switched on for a chat go as passages.
    public static let inlineBudget = 400_000
    /// The passages sent when the documents do not fit.
    public static let passageBudget = 120_000
    public static let extensions = ["pdf", "md", "markdown", "txt", "text", "csv"]

    let paths: DataPaths
    /// Called when a document is added, finished, or removed.
    public var onChange: ((String) -> Void)?

    public init(paths: DataPaths) { self.paths = paths }

    /// Engines that open files get paths; the rest get the text.
    public static func mode(_ driverKind: String) -> LibraryMode {
        ["localEndpoint", "grok", "boxAgent"].contains(driverKind) ? .inline : .paths
    }

    // MARK: Files

    func folder(_ botId: String) -> URL { paths.workspace(botId).appendingPathComponent("library", isDirectory: true) }
    private func indexFile(_ botId: String) -> URL { folder(botId).appendingPathComponent("index.json") }
    public func textFile(_ botId: String, _ doc: LibraryDoc) -> URL { folder(botId).appendingPathComponent("\(doc.id).md") }
    public func originalFile(_ botId: String, _ doc: LibraryDoc) -> URL {
        folder(botId).appendingPathComponent("\(doc.id).\(Self.ext(doc.name))")
    }
    private func passagesFile(_ botId: String, _ id: String) -> URL { folder(botId).appendingPathComponent("\(id).passages.json") }

    public func docs(_ botId: String) -> [LibraryDoc] {
        guard let data = try? Data(contentsOf: indexFile(botId)) else { return [] }
        return (try? JSONDecoder().decode([LibraryDoc].self, from: data)) ?? []
    }

    private func save(_ botId: String, _ docs: [LibraryDoc]) {
        try? FileManager.default.createDirectory(at: folder(botId), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(docs) { try? FileIO.writeAtomic(data, to: indexFile(botId)) }
    }

    private func update(_ botId: String, _ id: String, _ change: (inout LibraryDoc) -> Void) {
        var all = docs(botId)
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        save(botId, all)
    }

    nonisolated static func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }

    // MARK: Import

    public struct ImportError: Error { public var status: Int; public var message: String }

    /// Copies the file in and converts it in the background. The document
    /// shows as `processing` until its text is ready.
    @discardableResult
    public func add(_ botId: String, from source: URL) throws -> LibraryDoc {
        let name = source.lastPathComponent
        guard Self.extensions.contains(Self.ext(name)) else {
            throw ImportError(status: 400, message: "only PDF and text files (\(Self.extensions.joined(separator: ", "))) can go in the library")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular, let bytes = attributes?[.size] as? Int else {
            throw ImportError(status: 400, message: "no such file: \(source.path)")
        }
        guard bytes <= Self.maxFileBytes else { throw ImportError(status: 413, message: "file exceeds \(Self.maxFileBytes / 1024 / 1024) MB") }
        let doc = LibraryDoc(id: newId(), name: name, kind: Self.ext(name) == "pdf" ? "pdf" : "text", bytes: bytes, pages: 0,
                             chars: 0, tokens: 0, ocrPages: 0, status: "processing", error: nil, createdAt: nowMillis())
        try FileManager.default.createDirectory(at: folder(botId), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: source, to: originalFile(botId, doc))
        save(botId, docs(botId) + [doc])
        onChange?(botId)
        convert(botId, doc)
        return doc
    }

    private func convert(_ botId: String, _ doc: LibraryDoc) {
        let original = originalFile(botId, doc)
        let text = textFile(botId, doc)
        let passages = passagesFile(botId, doc.id)
        Task.detached(priority: .utility) {
            let result = Result { try LibraryConversion.convert(original, name: doc.name) }
            if case let .success(converted) = result {
                try? FileIO.writeAtomic(Data(converted.markdown.utf8), to: text)
                if let data = try? JSONEncoder().encode(converted.passages) { try? FileIO.writeAtomic(data, to: passages) }
            }
            await MainActor.run {
                self.update(botId, doc.id) { stored in
                    switch result {
                    case let .success(converted):
                        stored.pages = converted.pages
                        stored.chars = converted.body.count
                        stored.tokens = LibraryConversion.tokens(converted.body)
                        stored.ocrPages = converted.ocrPages
                        stored.status = converted.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "failed" : "ready"
                        stored.error = stored.status == "failed" ? "no text found, not even with OCR" : nil
                    case let .failure(error):
                        stored.status = "failed"
                        stored.error = (error as? ImportError)?.message ?? error.localizedDescription
                    }
                }
                self.onChange?(botId)
            }
        }
    }

    /// Documents that were converting when the harness stopped start over.
    public func resume(_ botIds: [String]) {
        for botId in botIds {
            for doc in docs(botId) where doc.status == "processing" { convert(botId, doc) }
        }
    }

    public func remove(_ botId: String, _ id: String) -> Bool {
        guard let doc = docs(botId).first(where: { $0.id == id }) else { return false }
        for file in [originalFile(botId, doc), textFile(botId, doc), passagesFile(botId, id)] {
            try? FileManager.default.removeItem(at: file)
        }
        save(botId, docs(botId).filter { $0.id != id })
        onChange?(botId)
        return true
    }

    public func text(_ botId: String, _ id: String) -> String? {
        guard let doc = docs(botId).first(where: { $0.id == id }) else { return nil }
        return try? String(contentsOf: textFile(botId, doc), encoding: .utf8)
    }

    // MARK: Turns

    /// Ready documents, minus the ones this chat switched off.
    public func active(_ botId: String, off: [String]) -> [LibraryDoc] {
        docs(botId).filter { $0.status == "ready" && !off.contains($0.id) }
    }

    /// The system prompt block for a turn; empty with nothing switched on.
    public func prompt(_ botId: String, off: [String], mode: LibraryMode, message: String) -> String {
        let docs = active(botId, off: off)
        guard !docs.isEmpty else { return "" }
        switch mode {
        case .paths:
            let list = docs.map { doc in
                "- \(doc.name)\(doc.kind == "pdf" ? " (\(doc.pages) pages)" : ""): text at \(JSON.string(textFile(botId, doc).path).serialized())," +
                    " original at \(JSON.string(originalFile(botId, doc).path).serialized())"
            }
            return "Reference documents the user loaded for this chat. When the question touches them, read the text file" +
                " (it holds every page, with `## Page N` headings) and say which document and page you used:\n" + list.joined(separator: "\n")
        case .inline:
            let total = docs.reduce(0) { $0 + $1.tokens }
            if total <= Self.inlineBudget {
                let blocks = docs.compactMap { doc -> String? in
                    guard let text = try? String(contentsOf: textFile(botId, doc), encoding: .utf8) else { return nil }
                    return "<document name=\(JSON.string(doc.name).serialized()) pages=\"\(doc.pages)\">\n\(text)\n</document>"
                }
                return "Reference documents the user loaded for this chat. Use them as knowledge when the question touches them," +
                    " and say which document and page you used.\n\n" + blocks.joined(separator: "\n\n")
            }
            let pool = docs.map { doc in (doc, passages(botId, doc.id)) }
            let picked = LibraryRetrieval.select(message, pool.map { ($0.0.name, $0.1) }, budget: Self.passageBudget)
            let blocks = picked.map { "<passage document=\(JSON.string($0.document).serialized()) page=\"\($0.passage.page)\">\n\($0.passage.text)\n</passage>" }
            return "Reference documents the user loaded for this chat: \(docs.map(\.name).joined(separator: ", "))." +
                " They are too long to include whole, so these are the passages closest to the latest message." +
                " Use them as knowledge when relevant, say which document and page you used, and say so when they do not cover the question.\n\n" +
                blocks.joined(separator: "\n\n")
        }
    }

    private func passages(_ botId: String, _ id: String) -> [LibraryPassage] {
        guard let data = try? Data(contentsOf: passagesFile(botId, id)) else { return [] }
        return (try? JSONDecoder().decode([LibraryPassage].self, from: data)) ?? []
    }
}

// MARK: - Conversion

enum LibraryConversion {
    struct Converted {
        var markdown: String
        /// The text alone, without the headings this file adds.
        var body: String
        var pages: Int
        var ocrPages: Int
        var passages: [LibraryPassage]
    }

    /// Below this many characters a PDF page is treated as a picture.
    static let pageTextMinimum = 30
    static let passageChars = 1000

    /// Italian and English run around 3.5 characters a token.
    static func tokens(_ text: String) -> Int { Int((Double(text.count) / 3.5).rounded(.up)) }

    static func convert(_ url: URL, name: String) throws -> Converted {
        let pages: [String]
        var ocrPages = 0
        if Library.ext(name) == "pdf" {
            guard let pdf = PDFDocument(url: url) else { throw Library.ImportError(status: 400, message: "this PDF cannot be opened (damaged or password protected)") }
            if pdf.isLocked { throw Library.ImportError(status: 400, message: "this PDF is password protected") }
            var read: [String] = []
            for index in 0..<pdf.pageCount {
                let text = pdf.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.count >= pageTextMinimum { read.append(text); continue }
                let recognized = ocr(url, page: index + 1) ?? ""
                if !recognized.isEmpty { ocrPages += 1 }
                read.append(recognized.count > text.count ? recognized : text)
            }
            pages = read
        } else {
            let data = try Data(contentsOf: url)
            pages = [String(decoding: data, as: UTF8.self)]
        }

        let isPDF = Library.ext(name) == "pdf"
        let markdown = isPDF
            ? "# \(name)\n\n" + pages.enumerated().map { "## Page \($0.offset + 1)\n\n\($0.element)" }.joined(separator: "\n\n") + "\n"
            : pages.joined()
        let body = pages.joined(separator: "\n\n")
        let pieces = pages.enumerated().flatMap { page in split(page.element).map { (page: isPDF ? page.offset + 1 : 0, text: $0) } }
        let embedder = Embedder(sample: body)
        let passages = pieces.map { LibraryPassage(page: $0.page, text: $0.text, vector: embedder?.vector($0.text)) }
        return Converted(markdown: markdown, body: body, pages: pages.count, ocrPages: ocrPages, passages: passages)
    }

    /// Paragraphs packed into passages of about `passageChars`, which is what
    /// the embedding model reads before it truncates (256 tokens).
    static func split(_ text: String) -> [String] {
        // a paragraph longer than a passage is cut at spaces first, so its
        // tail still packs with what follows instead of standing alone
        let pieces = text.components(separatedBy: "\n\n").flatMap { paragraph -> [Substring] in
            var rest = Substring(paragraph.trimmingCharacters(in: .whitespacesAndNewlines))
            var out: [Substring] = []
            while rest.count > passageChars {
                let window = rest.prefix(passageChars)
                let cut = window.lastIndex(where: { $0 == " " || $0 == "\n" }) ?? window.endIndex
                out.append(rest[..<cut])
                rest = rest[cut...].drop { $0 == " " || $0 == "\n" }
            }
            return rest.isEmpty ? out : out + [rest]
        }
        var out: [String] = []
        var current = ""
        for piece in pieces where !piece.isEmpty {
            if !current.isEmpty, current.count + piece.count + 2 > passageChars {
                out.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + piece
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// One page, rendered at 2× and read by Vision.
    static func ocr(_ url: URL, page number: Int) -> String? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: number) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["it-IT", "en-US"]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

// MARK: - Embeddings

/// Apple's contextual embedding (a BERT on the device), mean-pooled into one
/// unit vector per text. Nil when the model's assets are not on this Mac.
struct Embedder {
    let model: NLContextualEmbedding
    let language: NLLanguage

    init?(sample: String) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(5000)))
        let language = recognizer.dominantLanguage ?? .italian
        guard let model = NLContextualEmbedding(language: language) ?? NLContextualEmbedding(language: .italian),
              model.hasAvailableAssets, (try? model.load()) != nil else { return nil }
        self.model = model
        self.language = model.languages.contains(language) ? language : .italian
    }

    func vector(_ text: String) -> [Float]? {
        guard !text.isEmpty, let result = try? model.embeddingResult(for: text, language: language) else { return nil }
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0.0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { values, _ in
            for index in 0..<min(values.count, sum.count) { sum[index] += values[index] }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return sum.map { Float($0 / norm) }
    }
}

// MARK: - Retrieval

enum LibraryRetrieval {
    struct Pick { var document: String; var passage: LibraryPassage }

    /// The passages closest to `query`, up to `budget` tokens, back in
    /// document and page order. Keywords and meaning weigh the same; either
    /// alone is enough when the other has nothing to say.
    static func select(_ query: String, _ pool: [(document: String, passages: [LibraryPassage])], budget: Int) -> [Pick] {
        let all = pool.enumerated().flatMap { doc in
            doc.element.passages.enumerated().map { (doc: doc.offset, index: $0.offset, name: doc.element.document, passage: $0.element) }
        }
        guard !all.isEmpty else { return [] }
        let keyword = normalize(bm25(query, all.map(\.passage.text)))
        let embedder = Embedder(sample: query)
        let queryVector = embedder?.vector(query)
        let meaning = normalize(all.map { item in
            guard let queryVector, let vector = item.passage.vector, vector.count == queryVector.count else { return 0 }
            return Double(zip(queryVector, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 })
        })
        let ranked = all.indices.sorted { keyword[$0] + meaning[$0] > keyword[$1] + meaning[$1] }
        var spent = 0
        var chosen: [Int] = []
        for index in ranked {
            let cost = LibraryConversion.tokens(all[index].passage.text)
            if spent + cost > budget { continue }
            spent += cost
            chosen.append(index)
        }
        return chosen
            .sorted { (all[$0].doc, all[$0].index) < (all[$1].doc, all[$1].index) }
            .map { Pick(document: all[$0].name, passage: all[$0].passage) }
    }

    static func terms(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 || $0.allSatisfy(\.isNumber) }
    }

    /// Okapi BM25, k1 1.2, b 0.75.
    static func bm25(_ query: String, _ texts: [String]) -> [Double] {
        let docs = texts.map(terms)
        let queryTerms = Set(terms(query))
        guard !queryTerms.isEmpty else { return docs.map { _ in 0 } }
        let average = Double(docs.reduce(0) { $0 + $1.count }) / Double(max(docs.count, 1))
        var frequency: [String: Int] = [:]
        for doc in docs { for term in Set(doc) where queryTerms.contains(term) { frequency[term, default: 0] += 1 } }
        return docs.map { doc in
            var counts: [String: Int] = [:]
            for term in doc where queryTerms.contains(term) { counts[term, default: 0] += 1 }
            return counts.reduce(0.0) { score, entry in
                let n = Double(frequency[entry.key] ?? 0)
                let idf = log(1 + (Double(docs.count) - n + 0.5) / (n + 0.5))
                let tf = Double(entry.value)
                return score + idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * Double(doc.count) / max(average, 1)))
            }
        }
    }

    /// Min-max to 0…1; all zeros when every score is the same.
    static func normalize(_ scores: [Double]) -> [Double] {
        guard let low = scores.min(), let high = scores.max(), high > low else { return scores.map { _ in 0 } }
        return scores.map { ($0 - low) / (high - low) }
    }
}
