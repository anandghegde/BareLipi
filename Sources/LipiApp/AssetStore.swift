import AppKit
import CryptoKit
import ImageIO
import LipiCore
import LipiEditor
import UniformTypeIdentifiers

/// The §6.7 image storage policy (P0-07): where pasted and dropped images
/// go, what they are called, what format they are written in, and the
/// relative path the inserted `![](…)` uses.
///
/// Target folder, first match wins: front matter `assets:`, then the
/// Typora-compatible `typora-copy-images-to:`, then `./assets/` beside the
/// document (workspace settings arrive with the workspace, Phase 2). An
/// untitled document stores images under
/// `~/Library/Application Support/BareLipi/Unsaved/<uuid>/` and links them
/// by absolute path; the first save moves them beside the document and
/// rewrites the links (`adoptUnsavedAssets`).
public enum AssetPolicy {
    /// How new image files are named.
    public enum Naming: String, Sendable {
        /// `YYYY-MM-DD-HHmmss-<6-char hash>.<ext>` (default).
        case timestamp
        /// The dropped file's own name, with `-1`, `-2`… on collision.
        case original
    }

    /// The front matter value of `key` (YAML `key: value` at the top
    /// level of a leading `---` block), unquoted; nil when absent or empty.
    public static func frontMatterValue(_ key: String, in text: String) -> String? {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }).makeIterator()
        guard let first = lines.next(), first.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
        while let raw = lines.next() {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if line == "---" || line == "..." { return nil }
            guard line.hasPrefix(key), let colon = line.firstIndex(of: ":"),
                  line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces) == key else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The folder images for a document at `documentURL` go to.
    public static func targetFolder(documentURL: URL, text: String) -> URL {
        let dir = documentURL.deletingLastPathComponent()
        let name = documentURL.deletingPathExtension().lastPathComponent
        let configured = frontMatterValue("assets", in: text) ?? frontMatterValue("typora-copy-images-to", in: text)
        guard var path = configured else { return dir.appendingPathComponent("assets", isDirectory: true) }
        path = path.replacingOccurrences(of: "${filename}", with: name)
        path = (path as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : dir.appendingPathComponent(path, isDirectory: true)
        return url.standardizedFileURL
    }

    /// The standardized path components of `url`, with the `/private`
    /// firmlink prefix of `/var`, `/tmp` and `/etc` dropped (standardizing
    /// drops it only for paths that exist).
    static func components(_ url: URL) -> [String] {
        var c = url.standardizedFileURL.pathComponents
        if c.count > 2, c[0] == "/", c[1] == "private", ["var", "tmp", "etc"].contains(c[2]) { c.remove(at: 1) }
        return c
    }

    /// `file` relative to `directory`, with `..` segments as needed.
    public static func relativePath(of file: URL, from directory: URL) -> String {
        let a = components(directory)
        let b = components(file)
        var common = 0
        while common < a.count, common < b.count, a[common] == b[common] { common += 1 }
        let up = Array(repeating: "..", count: a.count - common)
        return (up + b[common...]).joined(separator: "/")
    }

    /// The link destination for `file` in a document at `documentURL`:
    /// relative to the document's folder, or root-relative (`/…`) under a
    /// `typora-root-url`; the absolute path for an untitled document.
    public static func linkPath(for file: URL, documentURL: URL?, text: String) -> String {
        guard let documentURL else { return file.standardizedFileURL.path }
        let dir = documentURL.deletingLastPathComponent()
        if let rootValue = frontMatterValue("typora-root-url", in: text) {
            let expanded = (rootValue as NSString).expandingTildeInPath
            let root = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: true) : dir.appendingPathComponent(expanded, isDirectory: true)
            let rel = relativePath(of: file, from: root)
            if !rel.hasPrefix("..") { return "/" + rel }
        }
        return relativePath(of: file, from: dir)
    }

    /// A timestamped name: `2026-09-26-142501-a1b2c3.png`.
    public static func timestampName(date: Date, data: Data, ext: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let hash = SHA256.hash(data: data).prefix(3).map { String(format: "%02x", $0) }.joined()
        return "\(f.string(from: date))-\(hash).\(ext)"
    }

    /// `name` in `folder`, or `name-1`, `name-2`… when taken by different bytes.
    /// A file with identical bytes is reused.
    public static func unusedURL(for name: String, in folder: URL, data: Data, fileManager: FileManager = .default) -> (url: URL, exists: Bool) {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 0
        while true {
            let candidate = n == 0 ? name : "\(base)-\(n)" + (ext.isEmpty ? "" : ".\(ext)")
            let url = folder.appendingPathComponent(candidate)
            guard fileManager.fileExists(atPath: url.path) else { return (url, false) }
            if let existing = try? Data(contentsOf: url), existing == data { return (url, true) }
            n += 1
        }
    }

    /// Bytes and extension to store: TIFF becomes PNG, HEIC becomes JPEG at
    /// quality 0.9 (when `convertHEIC`), everything else is kept as is.
    public static func encode(_ data: Data, type: UTType, convertHEIC: Bool = true) -> (data: Data, ext: String)? {
        if type.conforms(to: .png) { return (data, "png") }
        if type.conforms(to: .tiff) {
            guard let png = transcode(data, to: .png, quality: nil) else { return nil }
            return (png, "png")
        }
        if type.conforms(to: .heic) || type.conforms(to: .heif) {
            guard convertHEIC else { return (data, type.preferredFilenameExtension ?? "heic") }
            guard let jpeg = transcode(data, to: .jpeg, quality: 0.9) else { return nil }
            return (jpeg, "jpg")
        }
        if type.conforms(to: .jpeg) { return (data, "jpg") }
        return (data, type.preferredFilenameExtension ?? "img")
    }

    static func transcode(_ data: Data, to type: UTType, quality: Double?) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        if let meta = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let orientation = meta[kCGImagePropertyOrientation] { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// Stores images for one document (see `AssetPolicy`).
@MainActor
public final class AssetStore {
    /// Defaults keys (Settings → Images).
    public static let namingKey = "ImageNaming"
    public static let convertHEICKey = "ConvertHEICToJPEG"

    /// Where untitled documents keep images.
    public let unsavedFolder: URL
    public var documentURL: () -> URL?
    public var text: () -> String
    public var naming: AssetPolicy.Naming
    public var convertHEIC: Bool
    public var now: () -> Date = Date.init
    let fileManager = FileManager.default

    public init(unsavedRoot: URL? = nil, documentURL: @escaping () -> URL?, text: @escaping () -> String) {
        let root = unsavedRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BareLipi/Unsaved", isDirectory: true)
        unsavedFolder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.documentURL = documentURL
        self.text = text
        let defaults = UserDefaults.standard
        naming = AssetPolicy.Naming(rawValue: defaults.string(forKey: AssetStore.namingKey) ?? "") ?? .timestamp
        convertHEIC = defaults.object(forKey: AssetStore.convertHEICKey) as? Bool ?? true
    }

    /// The folder new images go to now.
    public var targetFolder: URL {
        guard let doc = documentURL() else { return unsavedFolder }
        return AssetPolicy.targetFolder(documentURL: doc, text: text())
    }

    /// Writes `images` to the target folder; returns the link paths.
    public func store(_ images: [ImagePayload]) throws -> [String] {
        let folder = targetFolder
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var paths: [String] = []
        for image in images {
            let raw: Data, type: UTType, originalName: String?
            switch image.source {
            case .file(let url):
                raw = try Data(contentsOf: url)
                type = UTType(filenameExtension: url.pathExtension) ?? .data
                originalName = url.deletingPathExtension().lastPathComponent
            case .data(let data, let id):
                raw = data
                type = UTType(id) ?? .png
                originalName = nil
            }
            guard let (data, ext) = AssetPolicy.encode(raw, type: type, convertHEIC: convertHEIC) else { continue }
            let name: String
            if naming == .original, let originalName {
                name = originalName + "." + ext
            } else {
                name = AssetPolicy.timestampName(date: now(), data: data, ext: ext)
            }
            let (url, exists) = AssetPolicy.unusedURL(for: name, in: folder, data: data, fileManager: fileManager)
            if !exists { try data.write(to: url, options: .atomic) }
            paths.append(AssetPolicy.linkPath(for: url, documentURL: documentURL(), text: text()))
        }
        return paths
    }

    /// After the first save of an untitled document to `documentURL`: moves
    /// every image under `unsavedFolder` that `text` links to into the
    /// document's target folder. Returns the link edits to make (absolute
    /// unsaved paths → relative), in document order; empty when none.
    public func adoptUnsavedAssets(documentURL: URL, text: String) -> [Edit] {
        let files = (try? fileManager.contentsOfDirectory(at: unsavedFolder, includingPropertiesForKeys: nil)) ?? []
        guard !files.isEmpty else { return [] }
        let folder = AssetPolicy.targetFolder(documentURL: documentURL, text: text)
        let search = SearchText(text)
        var edits: [Edit] = []
        for file in files {
            let old = AssetPolicy.linkPath(for: file, documentURL: nil, text: text)
            let oldDestination = EditorView.linkDestination(old)
            let hits = (try? DocumentSearch.matches(of: FindQuery(oldDestination, caseSensitive: true), in: search)) ?? []
            guard !hits.isEmpty else { continue }
            guard (try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { continue }
            let data = (try? Data(contentsOf: file)) ?? Data()
            let (target, exists) = AssetPolicy.unusedURL(for: file.lastPathComponent, in: folder, data: data, fileManager: fileManager)
            do {
                if exists { try fileManager.removeItem(at: file) } else { try fileManager.moveItem(at: file, to: target) }
            } catch { continue }
            let new = EditorView.linkDestination(AssetPolicy.linkPath(for: target, documentURL: documentURL, text: text))
            edits += hits.map { Edit(replacing: $0, with: new) }
        }
        try? fileManager.removeItem(at: unsavedFolder)
        return edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Removes the unsaved folder (an untitled document closed unsaved).
    public func discardUnsaved() {
        try? fileManager.removeItem(at: unsavedFolder)
    }
}
