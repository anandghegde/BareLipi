import AppKit
import LipiCore
import LipiExport
import LipiLayout
import UniformTypeIdentifiers

/// File > Export > HTML… (P0-14, Phase 1): a standalone page in the
/// window's theme, written off the main thread through `AtomicWriter`.
extension LipiDocument {
    /// The export's title: the document name without its extension.
    var exportTitle: String {
        if let fileURL { return fileURL.deletingPathExtension().lastPathComponent }
        return displayName ?? "Untitled"
    }

    /// The text and theme to export, captured on the main thread.
    func exportSnapshot() -> (markdown: String, theme: Theme, title: String) {
        let markdown: String
        if let controller = windowController?.controller {
            markdown = controller.rope.string
        } else {
            markdown = String(decoding: currentBytes(), as: UTF8.self)
        }
        return (markdown, windowController?.controller.theme ?? .taalegari, exportTitle)
    }

    /// The image treatment last chosen in the export panel.
    static var imageExportMode: ImageExport.Mode {
        get { UserDefaults.standard.string(forKey: "export.html.images").flatMap(ImageExport.Mode.init(rawValue:)) ?? .reference }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "export.html.images") }
    }

    /// The panel's accessory: how to treat local images.
    static func imageModeAccessory() -> (view: NSView, popup: NSPopUpButton) {
        let label = NSTextField(labelWithString: "Images:")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for mode in ImageExport.Mode.allCases {
            popup.addItem(withTitle: mode.title)
            popup.lastItem?.representedObject = mode.rawValue
        }
        popup.selectItem(at: ImageExport.Mode.allCases.firstIndex(of: imageExportMode) ?? 0)
        popup.setAccessibilityLabel("Images")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        return (stack, popup)
    }

    @objc public func exportHTML(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = exportTitle + ".html"
        if let directory = fileURL?.deletingLastPathComponent() { panel.directoryURL = directory }
        let accessory = Self.imageModeAccessory()
        panel.accessoryView = accessory.view
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let mode = (accessory.popup.selectedItem?.representedObject as? String).flatMap(ImageExport.Mode.init(rawValue:)) ?? .reference
            Self.imageExportMode = mode
            Task { await self.exportAndReport(to: url, images: mode) }
        }
        if let window = windowController?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func exportAndReport(to url: URL, images: ImageExport.Mode) async {
        do {
            let missing = try await exportHTML(to: url, images: images)
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
    public func exportHTML(to url: URL, images: ImageExport.Mode = .reference) async throws -> [String] {
        let snapshot = exportSnapshot()
        let options = ImageExport(mode: images, documentDirectory: fileURL?.deletingLastPathComponent(), outputURL: url)
        return try await Task.detached(priority: .userInitiated) {
            let result = HTMLExporter(theme: snapshot.theme).export(markdown: snapshot.markdown, title: snapshot.title, images: options)
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
