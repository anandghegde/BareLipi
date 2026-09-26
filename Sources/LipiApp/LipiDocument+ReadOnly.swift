import AppKit
import LipiCore
import LipiEditor

// MARK: - Read-only and locked documents

extension LipiDocument {
    /// True when the file is locked in the Finder (`uchg`) or not writable.
    nonisolated static func isLocked(_ url: URL) -> Bool {
        // A fresh URL: resource values are cached per URL object.
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.isUserImmutableKey, .isWritableKey]) else { return false }
        return values.isUserImmutable == true || values.isWritable == false
    }

    /// Makes the editor match `isReadOnly` and shows the bars that explain
    /// why: the encoding bar (Convert to UTF-8) and the locked bar
    /// (Unlock, Duplicate).
    func updateReadOnlyState() {
        guard let windowController else { return }
        windowController.editor.isEditable = !isReadOnly
        let content = windowController.content
        if originalBytes != nil { showEncodingBar() } else { content.hide(.encoding) }
        if isFileLocked { showLockedBar() } else { content.hide(.locked) }
    }

    func showLockedBar() {
        windowController?.content.show(NoticeBar(kind: .locked, message: "This file is locked. Unlock it to edit, or edit a duplicate.", actions: [
            NoticeBar.Action("Unlock") { [weak self] in self?.unlockFile() },
            NoticeBar.Action("Duplicate") { [weak self] in self?.duplicate(nil) },
        ]))
    }

    /// An edit the editor refused: beep, and make sure the bar saying why
    /// is on screen.
    func editRefused() {
        NSSound.beep()
        if isFileLocked, windowController?.content.bar(.locked) == nil { showLockedBar() }
        if originalBytes != nil, windowController?.content.bar(.encoding) == nil { showEncodingBar() }
    }

    /// Clears the file's `uchg` flag and gives the owner write permission,
    /// as the Finder's Locked checkbox and NSDocument's Unlock do.
    public func unlockFile() {
        guard let url = fileURL else { return }
        let fm = FileManager.default
        do {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            if attributes[.immutable] as? Bool == true { try fm.setAttributes([.immutable: false], ofItemAtPath: url.path) }
            if let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value, mode & 0o200 == 0 {
                try fm.setAttributes([.posixPermissions: NSNumber(value: mode | 0o200)], ofItemAtPath: url.path)
            }
        } catch {
            windowController?.content.show(NoticeBar(kind: .fileError, message: "Could not unlock: \(error.localizedDescription)", actions: []))
            return
        }
        isFileLocked = LipiDocument.isLocked(url)
        updateReadOnlyState()
    }

    /// Test and restoration hook: marks the document locked (as a read of a
    /// locked file does) without touching the file.
    func setFileLocked(_ locked: Bool) {
        isFileLocked = locked
        updateReadOnlyState()
    }
}

// MARK: - Images (P0-07)

extension LipiDocument: EditorImageHandler {
    /// The document's front matter block (delimiters included), or "".
    var frontMatterText: String {
        guard let controller = windowController?.controller, let first = controller.blockIndex.entries.first,
              first.block.kind.isFrontMatter else { return "" }
        return controller.string(in: 0..<first.block.range.upperBound)
    }

    public func importImages(_ images: [ImagePayload]) -> [String] {
        do {
            return try assets.store(images)
        } catch {
            windowController?.content.show(NoticeBar(kind: .fileError, message: "Could not store the image: \(error.localizedDescription)", actions: []))
            return []
        }
    }

    public func linkPath(forExistingImage url: URL) -> String {
        AssetPolicy.linkPath(for: url, documentURL: fileURL, text: frontMatterText)
    }

    /// First save of an untitled document: moves its images beside the new
    /// file and rewrites their links, as one undo step that does not mark
    /// the document edited.
    func adoptUnsavedAssets(savingTo url: URL) {
        guard let controller = windowController?.controller else { return }
        let edits = assets.adoptUnsavedAssets(documentURL: url, text: controller.string)
        guard !edits.isEmpty else { return }
        let selection = controller.selection
        isLoading = true
        controller.perform(EditPlan(edits: edits, anchor: selection.anchor, head: selection.head))
        isLoading = false
    }
}
