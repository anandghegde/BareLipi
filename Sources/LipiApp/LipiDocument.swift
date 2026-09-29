import AppKit
import LipiCore
import LipiEditor
import LipiLayout

/// A Markdown document (ADR-008). `NSDocument` provides autosave in place,
/// Versions, restorable state, the dirty indicator, Duplicate, Rename, Move
/// and the open and save panels; BareLipi supplies byte-exact reading and
/// writing (`TextCodec`), the §9.3 `AtomicWriter`, and external-change
/// handling (`ExternalChangeMonitor` fed by the vnode source, this
/// document's `NSFilePresenter` callbacks and app activation).
@objc(LipiDocument)
@MainActor
public final class LipiDocument: NSDocument {
    /// Text and format as read, until the window exists.
    private var pendingText = ""
    public private(set) var format = TextFormat()
    /// Bytes of a non-UTF-8 file, written back unchanged until converted.
    public private(set) var originalBytes: Data?
    /// The file's state at the last read or write.
    public private(set) var fingerprint: FileFingerprint?
    /// The text (without BOM) at the last read or write: the common ancestor
    /// for a three-way merge with an external change (P1-04). A snapshot of
    /// the persistent rope, so it shares storage with the editor's text
    /// until edits path-copy it. Nil for unconverted non-UTF-8 files.
    public internal(set) var mergeBase: LipiRope?
    /// The external change the conflict bar is about.
    private var pendingTheirs: (bytes: Data, fingerprint: FileFingerprint)?
    public private(set) var windowController: DocumentWindowController?
    private var monitor: ExternalChangeMonitor?
    private var activationObserver: NSObjectProtocol?
    /// Set while the text is replaced programmatically (open, reload), so
    /// the change does not mark the document edited.
    var isLoading = false
    private var deletedOnDisk = false
    private var pendingRestore: RestorableEditorState?
    /// Consumed by the next `showWindows()`: open in a separate window
    /// rather than joining the frontmost window's tabs (Cmd-N).
    static var nextOpensInSeparateWindow = false

    public override init() {
        super.init()
        hasUndoManager = false
        LaunchTracker.shared.didFinishLaunching()
        if let text = LaunchTracker.shared.consumeInitialText() { pendingText = text }
    }

    // MARK: NSDocument configuration

    public override class var autosavesInPlace: Bool { true }
    /// Untitled documents stay in memory and are offered for save on quit (ADR-008).
    public override class var autosavesDrafts: Bool { false }
    public override class var preservesVersions: Bool { true }
    public override class var usesUbiquitousStorage: Bool { false }

    /// The file is locked (`uchg`) or not writable; set at each read.
    public internal(set) var isFileLocked = false
    /// The document is read-only while its file is locked, and until a
    /// non-UTF-8 file is converted. The editor refuses edits up front.
    public var isReadOnly: Bool { originalBytes != nil || isFileLocked }
    /// Pasted and dropped images (§6.7).
    public internal(set) lazy var assets = AssetStore(documentURL: { [weak self] in self?.fileURL },
                                                     text: { [weak self] in self?.frontMatterText ?? "" })

    /// Save As, Move To and Rename set this; the editor resolves the
    /// document's relative image paths against it (P0-07).
    public override var fileURL: URL? {
        didSet {
            // Saves may set it off the main thread.
            if Thread.isMainThread {
                MainActor.assumeIsolated { syncDocumentURL() }
            } else {
                Task { @MainActor [weak self] in self?.syncDocumentURL() }
            }
        }
    }

    private func syncDocumentURL() {
        guard let controller = windowController?.editor.controller, controller.documentURL != fileURL else { return }
        controller.documentURL = fileURL
    }

    // MARK: Windows

    public override func makeWindowControllers() {
        // The window shown before the document controller started (launch).
        let replacesText = fileURL != nil || !pendingText.isEmpty
        if let early = EarlyWindow.adopt(replacesText: replacesText) {
            let windowController = early.windowController
            windowController.controller.documentURL = fileURL
            if replacesText {
                windowController.controller.load(pendingText)
                windowController.scroll(toY: 0)
            }
            pendingText = ""
            attach(windowController)
            if early.isEdited { updateChangeCount(.changeDone) }
            return
        }
        let tracker = LaunchTracker.shared
        var mark = CACurrentMediaTime()
        let controller = EditorController(text: pendingText, engine: tracker.options.engine, theme: tracker.options.theme,
                                          zoom: tracker.options.zoom, viewportWidth: 1100)
        controller.documentURL = fileURL
        tracker.phases.controller = CACurrentMediaTime() - mark
        mark = CACurrentMediaTime()
        pendingText = ""
        let windowController = DocumentWindowController(controller: controller, theme: tracker.options.theme)
        tracker.attach(windowController.editor)
        attach(windowController)
        tracker.phases.window = CACurrentMediaTime() - mark
    }

    /// Wires `windowController` (new, or the adopted early window) to this document.
    private func attach(_ windowController: DocumentWindowController) {
        let controller = windowController.controller
        let previous = controller.onChange
        controller.onChange = { [weak self] change in
            previous?(change)
            self?.editorDidChange(change)
        }
        windowController.onScroll = { [weak self] in self?.invalidateRestorableState() }
        controller.onRefusedEdit = { [weak self] in self?.editRefused() }
        windowController.editor.imageHandler = self
        addWindowController(windowController)
        self.windowController = windowController
        if fingerprint != nil, originalBytes == nil { mergeBase = controller.rope }
        updateReadOnlyState()
        if let state = pendingRestore {
            pendingRestore = nil
            windowController.apply(state)
        }
    }

    public override func showWindows() {
        let separate = LipiDocument.nextOpensInSeparateWindow
        LipiDocument.nextOpensInSeparateWindow = false
        let window = windowController?.window
        if separate { window?.tabbingMode = .disallowed }
        super.showWindows()
        window?.tabbingMode = .preferred
        LaunchTracker.shared.phases.shown = CACurrentMediaTime()
        if let editor = windowController?.editor { window?.makeFirstResponder(editor) }
        if fileURL != nil { EarlyWindow.noteRestorableWindow() }
        startMonitoring()
    }

    public override func close() {
        if fileURL == nil { assets.discardUnsaved() }
        monitor?.stop()
        monitor = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        super.close()
    }

    private func editorDidChange(_ change: EditorChange) {
        invalidateRestorableState()
        guard change.textChanged, !isLoading else { return }
        updateChangeCount(.changeDone)
    }

    // MARK: Reading

    public nonisolated override func read(from url: URL, ofType typeName: String) throws {
        var coordinationError: NSError?
        var result: Result<(Data, FileStat, Bool), Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result {
                let data = try Data(contentsOf: target)
                return (data, try FileStat.of(path: target.path), LipiDocument.isLocked(target))
            }
        }
        if let coordinationError { throw coordinationError }
        guard let (data, stat, locked) = try result?.get() else { throw CocoaError(.fileReadUnknown) }
        let decoded = TextCodec.decode(data)
        let fingerprint = FileFingerprint(stat: stat, bytes: data)
        // canConcurrentlyReadDocuments is false, so NSDocument reads on the main thread.
        MainActor.assumeIsolated { self.didRead(decoded, fingerprint: fingerprint, url: url, locked: locked) }
    }

    private func didRead(_ decoded: DecodedText, fingerprint: FileFingerprint, url: URL, locked: Bool = false) {
        format = decoded.format
        originalBytes = decoded.originalBytes
        isFileLocked = locked
        self.fingerprint = fingerprint
        deletedOnDisk = false
        if let windowController {
            // Revert: keep the caret on the same text.
            isLoading = true
            windowController.reload(text: decoded.text)
            isLoading = false
            mergeBase = originalBytes == nil ? windowController.controller.rope : nil
            pendingTheirs = nil
            updateReadOnlyState()
            windowController.content.hide(.externalChange)
            windowController.content.hide(.deleted)
        } else {
            pendingText = decoded.text
        }
        monitor?.acknowledge(fingerprint, url: AtomicWriter.resolve(url))
    }

    // MARK: Writing

    /// The bytes a save writes: the rope with its BOM, or the original bytes
    /// of an unconverted non-UTF-8 file. Never normalised.
    public func currentBytes() -> Data {
        if let originalBytes { return originalBytes }
        if let controller = windowController?.controller { return TextCodec.encode(controller.rope, format: format) }
        return TextCodec.encode(LipiRope(pendingText), format: format)
    }

    public override func data(ofType typeName: String) throws -> Data { currentBytes() }

    public nonisolated override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                                           originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        let data = onMain { self.currentBytes() }
        try data.write(to: url)
    }

    /// Saves through the §9.3 `AtomicWriter` instead of NSDocument's own
    /// safe-save (which would drop hard links and some metadata).
    public nonisolated override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        let (data, rope, refuse, isUTF8) = onMain { () -> (Data, LipiRope?, Bool, Bool) in
            // Do not resurrect a file deleted on disk behind the user's back
            // by autosaving; the bar offers Save As.
            let refuse = self.deletedOnDisk && saveOperation == .autosaveInPlaceOperation && url == self.fileURL
            if self.fileURL == nil, saveOperation == .saveOperation || saveOperation == .saveAsOperation {
                self.adoptUnsavedAssets(savingTo: url)
            }
            let rope = self.originalBytes == nil ? self.windowController?.controller.rope : nil
            return (self.currentBytes(), rope, refuse, self.format.isUTF8)
        }
        if refuse { throw CocoaError(.userCancelled) }
        var options = AtomicWriter.Options()
        options.coordinate = false  // NSDocument coordinates its saves.
        options.fullSync = saveOperation == .saveOperation || saveOperation == .saveAsOperation
        if !isUTF8 { options.textEncodingAttribute = nil }
        let outcome = try AtomicWriter(options: options).write(data, to: url)
        switch saveOperation {
        case .saveOperation, .saveAsOperation, .autosaveInPlaceOperation:
            onMain {
                self.fingerprint = outcome.fingerprint
                self.mergeBase = rope
                self.deletedOnDisk = false
                if let monitor = self.monitor {
                    monitor.acknowledge(outcome.fingerprint, url: outcome.resolvedURL)
                } else {
                    self.startMonitoring(at: outcome.resolvedURL)
                }
                self.windowController?.content.hide(.deleted)
            }
        default:
            break
        }
    }

    /// Runs `body` on the main actor. NSDocument writes on the main thread
    /// unless `canAsynchronouslyWrite` says otherwise (it does not here).
    private nonisolated func onMain<T: Sendable>(_ body: @MainActor @Sendable () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try MainActor.assumeIsolated(body) }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
    }


    // MARK: Encoding

    func showEncodingBar() {
        guard let content = windowController?.content else { return }
        let message = "This file is \(format.encodingName), not UTF-8. It is open read-only."
        content.show(NoticeBar(kind: .encoding, message: message, actions: [
            NoticeBar.Action("Convert to UTF-8") { [weak self] in self?.convertToUTF8() },
        ]))
    }

    /// Drops the original bytes: the next save writes the text as UTF-8.
    public func convertToUTF8() {
        guard originalBytes != nil else { return }
        originalBytes = nil
        format.encoding = .utf8
        format.hasBOM = false
        updateReadOnlyState()
        updateChangeCount(.changeDone)
    }

    // MARK: External changes (§6.16, §9.3)

    /// Starts watching the document's file (or `resolved`, the file just
    /// written by a first save, before `fileURL` is updated).
    private func startMonitoring(at resolved: URL? = nil) {
        guard let resolved = resolved ?? fileURL.map(AtomicWriter.resolve) else { return }
        if let monitor {
            monitor.follow(resolved)
            if let fingerprint { monitor.acknowledge(fingerprint) }
            return
        }
        let monitor = ExternalChangeMonitor(url: resolved, known: fingerprint)
        monitor.read = LipiDocument.readCoordinated
        monitor.onChange = { [weak self] change in self?.handle(change) }
        monitor.start()
        self.monitor = monitor
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor?.noteEvent() }
        }
    }

    /// Reads `url` under an `NSFileCoordinator`.
    nonisolated static func readCoordinated(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    /// Applies a resolved external change.
    func handle(_ change: ExternalChange) {
        guard let content = windowController?.content else { return }
        switch change {
        case .none, .metadataOnly:
            break
        case .modified(let bytes, let fingerprint):
            fileModificationDate = fingerprint.stat.modificationDate
            content.hide(.deleted)
            content.hide(.fileError)
            deletedOnDisk = false
            if isDocumentEdited {
                pendingTheirs = (bytes, fingerprint)
                content.show(NoticeBar(kind: .externalChange, message: "Changed on disk by another application", actions: [
                    NoticeBar.Action("Keep Mine") { [weak self] in self?.keepMine() },
                    NoticeBar.Action("Take Theirs") { [weak self] in self?.takeTheirs() },
                    NoticeBar.Action("Merge", isEnabled: canMerge(bytes)) { [weak self] in self?.merge() },
                ]))
            } else {
                apply(bytes: bytes, fingerprint: fingerprint)
            }
        case .deleted:
            deletedOnDisk = true
            content.hide(.externalChange)
            content.show(NoticeBar(kind: .deleted, message: "Deleted on disk", actions: [
                NoticeBar.Action("Save As…") { [weak self] in self?.saveAs(nil) },
                NoticeBar.Action("Close") { [weak self] in self?.close() },
            ]))
        case .moved(let url):
            fileURL = url
            windowController?.synchronizeWindowTitleWithDocumentName()
        case .unreadable(let message):
            content.show(NoticeBar(kind: .fileError, message: message, actions: [
                NoticeBar.Action("Retry") { [weak self] in
                    self?.windowController?.content.hide(.fileError)
                    self?.monitor?.checkNow()
                },
            ]))
        }
    }

    /// Silent reload of bytes from disk: caret remapped, scroll kept.
    private func apply(bytes: Data, fingerprint: FileFingerprint) {
        let decoded = TextCodec.decode(bytes)
        format = decoded.format
        originalBytes = decoded.originalBytes
        self.fingerprint = fingerprint
        isLoading = true
        windowController?.reload(text: decoded.text)
        isLoading = false
        mergeBase = originalBytes == nil ? windowController?.controller.rope : nil
        pendingTheirs = nil
        updateChangeCount(.changeCleared)
        updateReadOnlyState()
        windowController?.content.hide(.externalChange)
    }

    private func keepMine() {
        windowController?.content.hide(.externalChange)
        // The document stays edited; the next save overwrites the disk
        // without NSDocument's "changed by another application" alert.
        if let fingerprint = monitor?.known { fileModificationDate = fingerprint.stat.modificationDate }
        // Mine was chosen over what is on disk now, so that is the base a
        // later external change is merged against.
        if let theirs = pendingTheirs {
            let decoded = TextCodec.decode(theirs.bytes)
            mergeBase = decoded.originalBytes == nil ? LipiRope(decoded.text) : nil
            fingerprint = theirs.fingerprint
        }
        pendingTheirs = nil
    }

    private func takeTheirs() {
        guard let (bytes, fingerprint) = readTheirs() else { return }
        apply(bytes: bytes, fingerprint: fingerprint)
    }

    /// The file's current bytes, acknowledged as the known state.
    private func readTheirs() -> (Data, FileFingerprint)? {
        guard let url = monitor?.url ?? fileURL.map(AtomicWriter.resolve) else { return nil }
        do {
            let bytes = try LipiDocument.readCoordinated(url)
            let stat = try FileStat.of(path: url.path)
            let fingerprint = FileFingerprint(stat: stat, bytes: bytes)
            monitor?.acknowledge(fingerprint)
            fileModificationDate = stat.modificationDate
            return (bytes, fingerprint)
        } catch {
            handle(.unreadable(message: error.localizedDescription))
            return nil
        }
    }

    // MARK: Three-way merge (P1-04)

    /// Merge needs a base and UTF-8 on both sides.
    private func canMerge(_ theirs: Data) -> Bool {
        mergeBase != nil && !isReadOnly && TextCodec.decode(theirs).originalBytes == nil
    }

    /// The line ending conflict markers use: the document's, LF when mixed.
    var markerNewline: [UInt8] {
        switch format.lineEnding {
        case .crlf: [0x0D, 0x0A]
        case .cr: [0x0D]
        case .lf, .none, .mixed: [0x0A]
        }
    }

    /// Merges the file's current text into the editor's against the base
    /// (the text last read or written). The result is one undo step whose
    /// edits touch only the regions that changed; conflicts are written with
    /// `<<<<<<< Mine` / `=======` / `>>>>>>> Theirs` markers and counted in
    /// the bar. The disk's text becomes the new base.
    func merge() {
        guard let windowController, let base = mergeBase, let (bytes, fingerprint) = readTheirs() else { return }
        let decoded = TextCodec.decode(bytes)
        guard decoded.originalBytes == nil else { return }
        let controller = windowController.controller
        let mine = Array(controller.rope.string.utf8)
        let result = ThreeWayMerge(base: Array(base.string.utf8), mine: mine, theirs: Array(decoded.text.utf8),
                                   newline: markerNewline)
        self.fingerprint = fingerprint
        mergeBase = LipiRope(decoded.text)
        pendingTheirs = nil
        let content = windowController.content
        content.hide(.externalChange)
        guard !result.replacements.isEmpty else { return }
        let edits = result.replacements.map {
            Edit(replacing: $0.range, with: String(decoding: $0.bytes, as: UTF8.self))
        }
        let selection = controller.selection
        let anchor = CaretRemap.map(selection.anchor, from: mine, to: result.merged)
        let head = CaretRemap.map(selection.head, from: mine, to: result.merged)
        let y = windowController.scrollY
        controller.perform(EditPlan(edits: edits, anchor: anchor, head: head))
        if result.isClean {
            windowController.scroll(toY: y)
            return
        }
        let count = result.conflictCount
        content.show(NoticeBar(kind: .externalChange,
                               message: "Merged with \(count) \(count == 1 ? "conflict" : "conflicts"), marked <<<<<<< Mine … >>>>>>> Theirs",
                               actions: [
                                   NoticeBar.Action("Next Conflict") { [weak self] in self?.revealNextConflict() },
                                   NoticeBar.Action("Done") { [weak self] in self?.windowController?.content.hide(.externalChange) },
                               ]))
        if let first = ThreeWayMerge.conflictStarts(in: result.merged).first { controller.moveCaret(to: first) }
    }

    /// Moves the caret to the next conflict marker after it, wrapping round.
    func revealNextConflict() {
        guard let controller = windowController?.controller else { return }
        let starts = ThreeWayMerge.conflictStarts(in: Array(controller.rope.string.utf8))
        guard let first = starts.first else {
            windowController?.content.hide(.externalChange)
            return
        }
        let caret = controller.selection.head
        controller.moveCaret(to: starts.first { $0 > caret } ?? first)
    }

    // MARK: NSFilePresenter

    public nonisolated override func presentedItemDidChange() {
        // Replaces NSDocument's own reload logic with the §6.16 behaviour.
        DispatchQueue.main.async { [weak self] in self?.monitor?.noteEvent() }
    }

    public nonisolated override func presentedItemDidMove(to newURL: URL) {
        super.presentedItemDidMove(to: newURL)
        DispatchQueue.main.async { [weak self] in
            self?.monitor?.follow(AtomicWriter.resolve(newURL))
            self?.windowController?.synchronizeWindowTitleWithDocumentName()
        }
    }

    public nonisolated override func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in self?.handle(.deleted) }
        completionHandler(nil)
    }

    // MARK: Restorable state (§6.19)

    public override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        windowController?.editorState().encode(to: coder)
    }

    public override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        guard let state = RestorableEditorState.decode(from: coder) else { return }
        if let windowController { windowController.apply(state) } else { pendingRestore = state }
    }
}

/// Document controller: Cmd-N opens a separate window (tabs are Cmd-T),
/// and Cmd-T with no window open still makes a document.
@MainActor
public final class LipiDocumentController: NSDocumentController {
    /// Defaults key: when true, Cmd-N joins the front window's tabs.
    public static let newDocumentInTabKey = "NewDocumentOpensInTab"

    public override func newDocument(_ sender: Any?) {
        LipiDocument.nextOpensInSeparateWindow = !UserDefaults.standard.bool(forKey: LipiDocumentController.newDocumentInTabKey)
        super.newDocument(sender)
    }

    @objc public func newWindowForTab(_ sender: Any?) {
        super.newDocument(sender)
    }
}
