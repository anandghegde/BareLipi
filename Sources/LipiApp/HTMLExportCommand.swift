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

    @objc public func exportHTML(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = exportTitle + ".html"
        if let directory = fileURL?.deletingLastPathComponent() { panel.directoryURL = directory }
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { await self.exportAndReport(to: url) }
        }
        if let window = windowController?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func exportAndReport(to url: URL) async {
        do {
            try await exportHTML(to: url)
        } catch {
            presentError(error)
        }
    }

    /// Renders the current text and writes it to `url`; the render and the
    /// write run on a background task.
    public func exportHTML(to url: URL) async throws {
        let snapshot = exportSnapshot()
        try await Task.detached(priority: .userInitiated) {
            let data = HTMLExporter(theme: snapshot.theme).data(markdown: snapshot.markdown, title: snapshot.title)
            _ = try AtomicWriter().write(data, to: url)
        }.value
    }
}
