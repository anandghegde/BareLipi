import AppKit
import LipiCore
import UniformTypeIdentifiers

/// One image arriving by paste or drop (P0-07).
public struct ImagePayload: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// An image file (Finder copy, drag from Finder or another app).
        case file(URL)
        /// Image bytes from the pasteboard (a screenshot, a browser's Copy Image).
        case data(Data, type: String)
    }

    public var source: Source

    public init(_ source: Source) { self.source = source }
}

/// Stores images for the editor and names the paths its links use (§6.7).
@MainActor
public protocol EditorImageHandler: AnyObject {
    /// Copies the images to the document's asset folder and returns, in
    /// order, the link destinations for them (empty to refuse).
    func importImages(_ images: [ImagePayload]) -> [String]
    /// The link destination for an existing file picked in the Image open
    /// panel (not copied): relative to the document when it has a folder.
    func linkPath(forExistingImage url: URL) -> String
}

extension EditorView {
    /// Pasteboard types the view accepts as a drop.
    static let imageDragTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier)]

    /// Image data types read from a pasteboard, most preferred first.
    static let imageDataTypes: [UTType] = [.png, .tiff, .heic, .jpeg, .gif, .webP]

    /// The images on `pasteboard`: image files first; else raw image data,
    /// but only when the writer offers it ahead of text (so rich text that
    /// carries a picture still pastes as text) and no non-image file is on
    /// the board (Finder puts a file's icon there as TIFF).
    public static func images(on pasteboard: NSPasteboard) -> [ImagePayload] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            let images = urls.filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .image)
            }
            return images.count == urls.count ? images.map { ImagePayload(.file($0)) } : []
        }
        guard let item = pasteboard.pasteboardItems?.first else { return [] }
        for raw in item.types {
            if raw == .string || raw == .rtf || raw == .html || raw.rawValue == UTType.utf8PlainText.identifier { return [] }
            guard let type = UTType(raw.rawValue), let wanted = imageDataTypes.first(where: { type.conforms(to: $0) }),
                  let data = item.data(forType: raw) else { continue }
            return [ImagePayload(.data(data, type: wanted.identifier))]
        }
        return []
    }

    /// The Markdown inserted for image links: one `![](path)` per line.
    public static func imageMarkdown(_ paths: [String]) -> String {
        paths.map { "![](" + linkDestination($0) + ")" }.joined(separator: "\n")
    }

    /// A link destination as CommonMark needs it: in angle brackets when it
    /// has spaces or parentheses.
    public static func linkDestination(_ d: String) -> String {
        if d.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" }) {
            return "<" + d.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E") + ">"
        }
        return d
    }

    /// Imports the images on `pasteboard` and inserts their links over the
    /// selection as one undo step. False when there are no images.
    @discardableResult
    public func pasteImages(from pasteboard: NSPasteboard) -> Bool {
        guard let handler = imageHandler else { return false }
        let images = EditorView.images(on: pasteboard)
        guard !images.isEmpty else { return false }
        guard isEditable else { controller.insert(""); return true }  // reports the refusal
        let paths = handler.importImages(images)
        guard !paths.isEmpty else { NSSound.beep(); return true }
        controller.replace(controller.selection.range, with: EditorView.imageMarkdown(paths))
        return true
    }

    func imageDragOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard imageHandler != nil, isEditable, !EditorView.images(on: info.draggingPasteboard).isEmpty else { return [] }
        return .copy
    }

    func performImageDrop(_ info: NSDraggingInfo) -> Bool {
        guard imageDragOperation(info) == .copy else { return false }
        let point = convert(info.draggingLocation, from: nil)
        if let offset = controller.sourceOffset(at: point) { controller.moveCaret(to: offset) }
        window?.makeFirstResponder(self)
        return pasteImages(from: info.draggingPasteboard)
    }

    /// Whether edits are accepted (false for a locked or non-UTF-8 document).
    public var isEditable: Bool {
        get { controller.isEditable }
        set { controller.isEditable = newValue }
    }
}
