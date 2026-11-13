import AppKit
import ImageIO
import SwarmeKit
import SwiftUI
import UniformTypeIdentifiers

/// Images dropped or pasted on a chat, ready to go up as attachments.
///
/// Engines take PNG, JPEG, GIF and WebP. Any other image macOS can read
/// (TIFF from Preview or a browser, HEIC from Photos, BMP…) is converted:
/// to PNG, or to JPEG when the PNG would be over the size cap.
enum ComposerImage {
    static let maxBytes = 10_000_000

    /// The bytes to upload and their MIME type; nil when the data is not an
    /// image macOS can decode, or stays over `maxBytes` even as JPEG.
    /// The first frame only: an animated GIF over the cap arrives still.
    static func normalize(_ data: Data, type: UTType? = nil) -> (data: Data, mime: String)? {
        let type = type ?? sniff(data)
        // a supported image over the cap is re-encoded below like any other
        if let type, let mime = mime(type), data.count <= maxBytes { return (data, mime) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]), png.count <= maxBytes { return (png, "image/png") }
        if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]), jpeg.count <= maxBytes {
            return (jpeg, "image/jpeg")
        }
        return nil
    }

    static func mime(_ type: UTType) -> String? {
        if type.conforms(to: .png) { return "image/png" }
        if type.conforms(to: .jpeg) { return "image/jpeg" }
        if type.conforms(to: .gif) { return "image/gif" }
        if type.conforms(to: .webP) { return "image/webp" }
        return nil
    }

    /// The type ImageIO reads in the bytes themselves.
    private static func sniff(_ data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(identifier)
    }

    /// What a drag or a paste carries that the composer attaches: files
    /// (Finder), else an image without a file (a browser, Preview, a screenshot
    /// thumbnail). Nil when it carries neither, e.g. plain text.
    static func attachments(on board: NSPasteboard) -> (files: [URL], image: Data?)? {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return (urls, nil) }
        for type in [NSPasteboard.PasteboardType.png, .tiff] + imageTypes(on: board) {
            if let data = board.data(forType: type) { return ([], data) }
        }
        return nil
    }

    /// Other image types on the board (JPEG, HEIC, WebP…), in its own order.
    private static func imageTypes(on board: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        (board.types ?? []).filter { UTType($0.rawValue)?.conforms(to: .image) == true }
    }

    /// The type identifiers the chat accepts from SwiftUI drops.
    static let dropTypes: [UTType] = [.fileURL, .image]
}

/// What was dropped on the chat, handed to the composer, which owns the
/// attachments. Equal by id, so `onChange` fires once per drop.
struct ChatDrop: Equatable {
    let id = UUID()
    let providers: [NSItemProvider]

    static func == (lhs: ChatDrop, rhs: ChatDrop) -> Bool { lhs.id == rhs.id }
}

/// Over the whole chat while files or images are dragged on it.
struct ChatDropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.accent.opacity(0.06)))
            .overlay {
                Label(tr("Rilascia per allegare"), systemImage: "paperclip")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(Theme.raised))
            }
            .padding(12)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}
