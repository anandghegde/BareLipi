import AppKit
import LipiCore
import LipiExport
import LipiLayout
import UniformTypeIdentifiers

/// File > Export > HTML… (P0-14, Phase 1): a standalone page in the
/// window's theme (or a light / dark pair), written off the main thread
/// through `AtomicWriter`.
extension LipiDocument {
    /// The export's title: the document name without its extension.
    var exportTitle: String {
        if let fileURL { return fileURL.deletingPathExtension().lastPathComponent }
        return displayName ?? "Untitled"
    }

    /// The text, theme and opt-in syntaxes to export, captured on the main
    /// thread.
    func exportSnapshot() -> (markdown: String, theme: Theme, syntax: ParserOptions.Extensions, title: String) {
        let markdown: String
        let syntax: ParserOptions.Extensions
        if let controller = windowController?.controller {
            markdown = controller.rope.string
            syntax = controller.parserOptions.extensions.intersection(HTMLExporter.optionalSyntax)
        } else {
            markdown = String(decoding: currentBytes(), as: UTF8.self)
            syntax = Self.optionalSyntaxSetting
        }
        return (markdown, windowController?.controller.theme ?? .taalegari, syntax, exportTitle)
    }

    /// View › Markdown Extensions, for a document without a window.
    static var optionalSyntaxSetting: ParserOptions.Extensions {
        var out: ParserOptions.Extensions = []
        if OptionalSyntax.subscript.isEnabled() { out.insert(.subscript) }
        if OptionalSyntax.superscript.isEnabled() { out.insert(.superscript) }
        if OptionalSyntax.highlight.isEnabled() { out.insert(.highlight) }
        return out
    }

    /// The image treatment last chosen in the export panel.
    static var imageExportMode: ImageExport.Mode {
        get { AppSettings().exportImages }
        set { AppSettings().exportImages = newValue }
    }

    /// The theme mode last chosen in the export panel.
    static var themeExportMode: ExportThemeMode {
        get { AppSettings().exportTheme }
        set { AppSettings().exportTheme = newValue }
    }

    /// A save panel accessory's pop-up of `titles` (title, raw value).
    static func accessoryPopup(_ titles: [(String, String)], selected: Int, label: String) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (title, value) in titles {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        popup.selectItem(at: selected)
        popup.setAccessibilityLabel(label)
        return popup
    }

    /// The panel's accessory: how to treat local images, and the theme.
    static func exportAccessory() -> (view: NSView, images: NSPopUpButton, theme: NSPopUpButton) {
        let images = accessoryPopup(ImageExport.Mode.allCases.map { ($0.title, $0.rawValue) },
                                    selected: ImageExport.Mode.allCases.firstIndex(of: imageExportMode) ?? 0, label: "Images")
        let theme = accessoryPopup(ExportThemeMode.allCases.map { ($0.title, $0.rawValue) },
                                   selected: ExportThemeMode.allCases.firstIndex(of: themeExportMode) ?? 0, label: "Theme")
        let stack = NSStackView(views: [NSTextField(labelWithString: "Images:"), images,
                                        NSTextField(labelWithString: "Theme:"), theme])
        stack.orientation = .horizontal
        stack.setCustomSpacing(16, after: images)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        return (stack, images, theme)
    }

    @objc public func exportHTML(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = exportTitle + ".html"
        if let directory = fileURL?.deletingLastPathComponent() { panel.directoryURL = directory }
        let accessory = Self.exportAccessory()
        panel.accessoryView = accessory.view
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let mode = (accessory.images.selectedItem?.representedObject as? String).flatMap(ImageExport.Mode.init(rawValue:)) ?? .reference
            let theme = (accessory.theme.selectedItem?.representedObject as? String).flatMap(ExportThemeMode.init(rawValue:)) ?? .window
            Self.imageExportMode = mode
            Self.themeExportMode = theme
            Task { await self.exportAndReport(to: url, images: mode, theme: theme) }
        }
        if let window = windowController?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func exportAndReport(to url: URL, images: ImageExport.Mode, theme: ExportThemeMode) async {
        do {
            let missing = try await exportHTML(to: url, images: images, theme: theme)
            guard !missing.isEmpty else { return }
            // Missing images are reported, not fatal (§6.14).
            let alert = NSAlert()
            alert.messageText = missing.count == 1 ? "1 image was not found" : "\(missing.count) images were not found"
            alert.informativeText = "The page links to them as written:\n" + missing.prefix(12).joined(separator: "\n")
                + (missing.count > 12 ? "\n…" : "")
            if let window = windowController?.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
        } catch {
            presentError(error)
        }
    }

    /// Renders the current text and writes it to `url`, copying images
    /// beside it when `images` is `.copy`; the render and the writes run on
    /// a background task. Returns the image sources that were not found.
    @discardableResult
    public func exportHTML(to url: URL, images: ImageExport.Mode = .reference,
                           theme: ExportThemeMode = .window) async throws -> [String] {
        let snapshot = exportSnapshot()
        let options = ImageExport(mode: images, documentDirectory: fileURL?.deletingLastPathComponent(), outputURL: url)
        return try await Task.detached(priority: .userInitiated) {
            let exporter = HTMLExporter(theme: snapshot.theme, themeMode: theme, syntax: snapshot.syntax)
            let result = exporter.export(markdown: snapshot.markdown, title: snapshot.title, images: options)
            if !result.copies.isEmpty {
                let files = FileManager.default
                try files.createDirectory(at: options.assetsFolder, withIntermediateDirectories: true)
                for copy in result.copies {
                    if files.fileExists(atPath: copy.destination.path) { try files.removeItem(at: copy.destination) }
                    try files.copyItem(at: copy.source, to: copy.destination)
                }
            }
            _ = try AtomicWriter().write(Data(result.html.utf8), to: url)
            return result.missingImages
        }.value
    }
}
