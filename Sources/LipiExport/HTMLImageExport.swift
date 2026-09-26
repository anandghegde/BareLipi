import Foundation

/// How HTML export treats the document's local images (§6.14): links
/// rebased so they still resolve from where the page is written, files
/// copied into a folder beside the page, or the bytes embedded as `data:`
/// URIs. Remote (`http`, `https`) and `data:` images are left alone.
public struct ImageExport: Sendable, Hashable {
    public enum Mode: String, Sendable, Hashable, CaseIterable {
        /// Keep links, rewritten relative to the page's folder.
        case reference
        /// Copy into `<page name>_files/` beside the page.
        case copy
        /// Embed as `data:` URIs (one self-contained file).
        case embed

        public var title: String {
            switch self {
            case .reference: return "Link to originals"
            case .copy: return "Copy into a folder"
            case .embed: return "Embed in the page"
            }
        }
    }

    public var mode: Mode
    /// Folder relative image paths resolve against (the document's folder);
    /// nil for an unsaved document, whose relative images are left as they are.
    public var documentDirectory: URL?
    /// The page being written.
    public var outputURL: URL

    public init(mode: Mode, documentDirectory: URL?, outputURL: URL) {
        self.mode = mode
        self.documentDirectory = documentDirectory
        self.outputURL = outputURL
    }

    /// The folder `copy` writes into.
    public var assetsFolder: URL {
        outputURL.deletingLastPathComponent()
            .appendingPathComponent(outputURL.deletingPathExtension().lastPathComponent + "_files", isDirectory: true)
    }
}

/// What export produced besides the page: files to copy and images it
/// could not find (listed after export rather than failing it, §6.14).
public struct HTMLExportResult: Sendable {
    public var html: String
    public var copies: [(source: URL, destination: URL)]
    public var missingImages: [String]
}

extension HTMLExporter {
    /// Rewrites the `src` of each `<img>` in `html` per `options`.
    static func rewriteImages(in html: String, options: ImageExport,
                              fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                              readData: (URL) -> Data? = { try? Data(contentsOf: $0) }) -> HTMLExportResult {
        var out = ""
        out.reserveCapacity(html.utf8.count)
        var copies: [(source: URL, destination: URL)] = []
        var missing: [String] = []
        var usedNames: [String: URL] = [:]
        var rest = html[...]
        let marker = "<img src=\""
        while let start = rest.range(of: marker) {
            out += rest[..<start.upperBound]
            let afterSrc = rest[start.upperBound...]
            guard let quote = afterSrc.firstIndex(of: "\"") else {
                out += afterSrc
                return HTMLExportResult(html: out, copies: copies, missingImages: missing)
            }
            let escapedSrc = String(afterSrc[..<quote])
            rest = afterSrc[quote...]
            let src = HTMLEscaping.unescape(escapedSrc)
            guard let file = localFile(src, relativeTo: options.documentDirectory) else {
                out += escapedSrc
                continue
            }
            guard fileExists(file) else {
                missing.append(src)
                out += escapedSrc
                continue
            }
            let newSrc: String
            switch options.mode {
            case .reference:
                newSrc = relativePath(from: options.outputURL.deletingLastPathComponent(), to: file)
            case .copy:
                let name = uniqueName(for: file, used: &usedNames)
                if !copies.contains(where: { $0.source == file }) {
                    copies.append((file, options.assetsFolder.appendingPathComponent(name)))
                }
                newSrc = encodePath(options.assetsFolder.lastPathComponent) + "/" + encodePath(name)
            case .embed:
                guard let data = readData(file) else {
                    missing.append(src)
                    out += escapedSrc
                    continue
                }
                newSrc = "data:\(mimeType(of: file));base64,\(data.base64EncodedString())"
            }
            out += HTMLEscaping.escape(newSrc)
        }
        out += rest
        return HTMLExportResult(html: out, copies: copies, missingImages: missing)
    }

    /// The local file an image `src` names, or nil for remote and data URLs
    /// (and for relative paths when there is no document folder).
    static func localFile(_ src: String, relativeTo directory: URL?) -> URL? {
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

    /// `file` relative to `directory`, percent-encoded for a URL.
    static func relativePath(from directory: URL, to file: URL) -> String {
        // Symlinks resolved on both sides (/var and /private/var are one folder).
        let base = resolved(directory).pathComponents
        let target = resolved(file).pathComponents
        var common = 0
        while common < base.count, common < target.count - 1, base[common] == target[common] { common += 1 }
        let ups = Array(repeating: "..", count: base.count - common)
        return (ups + target[common...].map(encodePath)).joined(separator: "/")
    }

    static func encodePath(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    /// A file name inside the assets folder, suffixed when two different
    /// files share a name.
    static func uniqueName(for file: URL, used: inout [String: URL]) -> String {
        let name = file.lastPathComponent
        let stem = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var candidate = name
        var n = 2
        while let owner = used[candidate], owner != file {
            candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            n += 1
        }
        used[candidate] = file
        return candidate
    }

    static func mimeType(of file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "heic": return "image/heic"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "ico": return "image/x-icon"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }
}

extension HTMLExporter {
    /// `url` with symlinks resolved in its longest existing prefix (the
    /// page's folder may not exist yet).
    static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath()
        for component in rest { result.appendPathComponent(component) }
        return result
    }
}
