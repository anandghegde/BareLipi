import Foundation

// MARK: - Image islands

/// A length from an `<img>` tag's `width` / `height` (attribute or style):
/// CSS pixels (drawn as points) or a percentage of the text column.
public enum ImageLength: Sendable, Hashable {
    case pixels(Double)
    case percent(Double)

    /// `300`, `300px`, `50%`; nil for anything else (`auto`, `10em`).
    public init?(_ value: String) {
        var t = value.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("%") {
            guard let v = Double(t.dropLast()), v > 0 else { return nil }
            self = .percent(v)
            return
        }
        if t.hasSuffix("px") { t.removeLast(2) }
        guard let v = Double(t.trimmingCharacters(in: .whitespaces)), v > 0 else { return nil }
        self = .pixels(v)
    }
}

/// The image a block stands for (P0-07): a paragraph that is exactly one
/// `![alt](src "title")` or one `<img …>` tag, or an HTML block that is one
/// `<img …>` tag. The layout draws it as an island; while the caret is in
/// the image (`isFolded` false) its source is shown above the picture.
public struct DisplayImage: Sendable, Hashable {
    /// The image's `src` / destination as written (entities decoded).
    public var source: String
    public var alt: String
    public var title: String
    /// `style="zoom:N%"` in percent.
    public var zoom: Int?
    public var width: ImageLength?
    public var height: ImageLength?
    /// The source is hidden and the block shows only the picture.
    public var isFolded: Bool

    public init(source: String, alt: String = "", title: String = "", zoom: Int? = nil, width: ImageLength? = nil,
                height: ImageLength? = nil, isFolded: Bool = true) {
        self.source = source
        self.alt = alt
        self.title = title
        self.zoom = zoom
        self.width = width
        self.height = height
        self.isFolded = isFolded
    }

    /// The image of one `<img …>` tag (`text` may carry surrounding
    /// whitespace); nil when `text` is anything else or has no `src`.
    public init?(htmlTag text: String, isFolded: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tag = HTMLImageTag.parse(trimmed), let src = tag.value("src") else { return nil }
        let style = HTMLImageTag.declarations(tag.value("style") ?? "")
        func length(_ name: String) -> ImageLength? {
            tag.value(name).flatMap(ImageLength.init) ?? style.first { $0.property == name }.flatMap { ImageLength($0.value) }
        }
        self.init(source: HTMLImageTag.unescape(src), alt: HTMLImageTag.unescape(tag.value("alt") ?? ""),
                  title: HTMLImageTag.unescape(tag.value("title") ?? ""), zoom: tag.zoom,
                  width: length("width"), height: length("height"), isFolded: isFolded)
    }

    /// What stands in for the picture when there is none: the alt text,
    /// else the file name.
    public var label: String {
        if !alt.isEmpty { return alt }
        let name = source.split(separator: "/").last.map(String.init) ?? source
        return name.removingPercentEncoding ?? name
    }

    /// True for `http:` and `https:` images, which the editor never fetches.
    public var isRemote: Bool {
        let s = source.lowercased()
        return s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("//")
    }
}

// MARK: - Resolving

/// Where an image `src` points on disk (shared by the editor and export).
public enum ImageSource {
    /// The local file an image `src` names, or nil for remote and data URLs
    /// (and for relative paths when there is no document folder).
    public static func localFile(_ src: String, relativeTo directory: URL?) -> URL? {
        if src.isEmpty || src.hasPrefix("#") || src.hasPrefix("//") { return nil }
        if let colon = src.firstIndex(of: ":"), src[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }),
           src.distance(from: src.startIndex, to: colon) > 1 {
            // A scheme: only file URLs are local.
            guard src.lowercased().hasPrefix("file:"), let url = URL(string: src), url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
        var path = src
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<cut]) }
        path = path.removingPercentEncoding ?? path
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        if path.hasPrefix("~/") { return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL }
        guard let directory else { return nil }
        return URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
    }

    /// The folder a `typora-root-url` value names: absolute, `~/…`, or
    /// relative to the document's folder.
    public static func rootDirectory(_ value: String, documentDirectory: URL) -> URL {
        let expanded = (value as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: true)
            : documentDirectory.appendingPathComponent(expanded, isDirectory: true)
    }

    /// The file an image `src` names in a document whose folder is
    /// `documentDirectory`: a root-relative `/…` path resolves under `root`
    /// (`typora-root-url`) unless it names an existing absolute file.
    public static func resolve(_ src: String, documentDirectory: URL?, root: URL?,
                               fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        guard let file = localFile(src, relativeTo: documentDirectory) else { return nil }
        if let root, src.hasPrefix("/"), !src.hasPrefix("//"), !fileExists(file),
           let rooted = localFile(String(src.dropFirst()), relativeTo: root), fileExists(rooted) {
            return rooted
        }
        return file
    }
}

// MARK: - <img> tags

/// The attributes of one `<img …>` tag, keeping each one's source text so a
/// rewrite changes only the attributes it touches.
public struct HTMLImageTag: Equatable, Sendable {
    public struct Attribute: Equatable, Sendable {
        /// Whitespace before the attribute.
        public var lead: String
        /// Lowercased name.
        public var name: String
        /// Raw (entity-encoded) value; nil for a bare attribute.
        public var value: String?
        /// The attribute's source text after `lead`.
        public var text: String
    }

    /// `<img` as written (any case).
    public var open: String
    public var attributes: [Attribute]
    /// `>`, `/>` or ` />`: the rest of the tag.
    public var close: String

    /// Parses `s`, which must be exactly one `<img …>` open tag.
    public static func parse(_ s: String) -> HTMLImageTag? {
        let b = Array(s.utf8)
        guard let end = tagEnd(b, from: 0), end == b.count else { return nil }
        guard b.count >= 5, String(decoding: b[0..<4], as: UTF8.self).lowercased() == "<img" else { return nil }
        var i = 4
        guard isSpace(b[i]) || b[i] == 0x2F || b[i] == 0x3E else { return nil }
        var attributes: [Attribute] = []
        while true {
            let start = i
            while i < b.count, isSpace(b[i]) { i += 1 }
            guard i < b.count else { return nil }
            if b[i] == 0x3E || (b[i] == 0x2F && i + 1 < b.count && b[i + 1] == 0x3E) {
                guard (b[i] == 0x3E ? i + 1 : i + 2) == b.count else { return nil }
                return HTMLImageTag(open: String(decoding: b[0..<4], as: UTF8.self), attributes: attributes,
                                    close: String(decoding: b[start...], as: UTF8.self))
            }
            guard i > start else { return nil }
            let lead = String(decoding: b[start..<i], as: UTF8.self)
            let nameStart = i
            while i < b.count, isNameByte(b[i]) { i += 1 }
            guard i > nameStart else { return nil }
            let name = String(decoding: b[nameStart..<i], as: UTF8.self).lowercased()
            var j = i
            while j < b.count, isSpace(b[j]) { j += 1 }
            var value: String?
            if j < b.count, b[j] == 0x3D {
                j += 1
                while j < b.count, isSpace(b[j]) { j += 1 }
                guard j < b.count else { return nil }
                if b[j] == 0x22 || b[j] == 0x27 {
                    let q = b[j]
                    guard let close = b[(j + 1)...].firstIndex(of: q) else { return nil }
                    value = String(decoding: b[(j + 1)..<close], as: UTF8.self)
                    j = close + 1
                } else {
                    let vs = j
                    while j < b.count, !isSpace(b[j]), ![0x22, 0x27, 0x3D, 0x3C, 0x3E, 0x60].contains(b[j]) { j += 1 }
                    guard j > vs else { return nil }
                    value = String(decoding: b[vs..<j], as: UTF8.self)
                }
                i = j
            }
            attributes.append(Attribute(lead: lead, name: name, value: value,
                                        text: String(decoding: b[nameStart..<i], as: UTF8.self)))
        }
    }

    /// The end (exclusive) of the tag starting at `from` (`<`), skipping `>`
    /// inside quoted values; nil when unterminated.
    public static func tagEnd(_ b: [UInt8], from: Int) -> Int? {
        var i = from
        var quote: UInt8? = nil
        while i < b.count {
            let c = b[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == 0x22 || c == 0x27 {
                quote = c
            } else if c == 0x3E {
                return i + 1
            }
            i += 1
        }
        return nil
    }

    static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }
    static func isNameByte(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x3A
            || c == 0x2E || c == 0x2D
    }

    public var text: String { open + attributes.map { $0.lead + $0.text }.joined() + close }

    public func value(_ name: String) -> String? { attributes.first { $0.name == name }?.value }

    public mutating func set(_ name: String, _ value: String) {
        let text = name + "=\"" + value + "\""
        if let i = attributes.firstIndex(where: { $0.name == name }) {
            attributes[i].value = value
            attributes[i].text = text
        } else {
            attributes.append(Attribute(lead: " ", name: name, value: value, text: text))
        }
    }

    public mutating func remove(_ name: String) { attributes.removeAll { $0.name == name } }

    /// The `zoom` of the style attribute, in percent.
    public var zoom: Int? {
        guard let style = value("style") else { return nil }
        return HTMLImageTag.declarations(style).first { $0.property == "zoom" }.flatMap { HTMLImageTag.percent($0.value) }
    }

    /// Sets (or with nil removes) the style's `zoom`, keeping its other
    /// declarations; an emptied style attribute is dropped.
    public mutating func setZoom(_ zoom: Int?) {
        let style = value("style") ?? ""
        var decls = HTMLImageTag.declarations(style).filter { $0.property != "zoom" }.map(\.raw)
        if let zoom { decls.append("zoom:\(zoom)%") }
        if decls.isEmpty { remove("style") } else { set("style", decls.joined(separator: "; ") + ";") }
    }

    public static func declarations(_ style: String) -> [(property: String, value: String, raw: String)] {
        style.split(separator: ";").compactMap { part in
            let raw = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            let pieces = raw.split(separator: ":", maxSplits: 1)
            let property = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespaces) : ""
            return (property, value, raw)
        }
    }

    /// `50%` → 50, `0.5` → 50.
    public static func percent(_ v: String) -> Int? {
        let t = v.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%") { return Double(t.dropLast()).map { Int($0.rounded()) } }
        return Double(t).map { Int(($0 * 100).rounded()) }
    }

    /// The few entities attribute values use.
    public static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}
