import AppKit

/// keymap.json on disk (Appendix A.3: `~/Library/Application Support/
/// BareLipi/keymap.json`): loaded when the registry is first used, watched
/// from shortly after launch, reloaded and re-applied when it changes, and
/// written by Settings → Keys.
///
/// Launch cost: `load()` is one `stat` when the file is absent (the
/// default) and a read plus `JSONSerialization` of a few hundred bytes when
/// present; the watcher is set up a second after launch, off the launch
/// path.
@MainActor
public final class KeymapStore {
    public static let shared = KeymapStore(url: KeymapStore.defaultURL)

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BareLipi", isDirectory: true).appendingPathComponent("keymap.json")
    }

    public let url: URL
    /// The bytes last loaded or saved, to ignore our own writes and
    /// no-op change events.
    private var lastData: Data?
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var activation: NSObjectProtocol?
    private var watchScheduled = false
    /// Problems already shown, so a reload with the same problems is quiet.
    private var reported: [String] = []

    /// The registry the watcher reloads into (nil: the app's).
    public weak var target: CommandRegistry?

    public init(url: URL) { self.url = url }

    /// Reads and parses the file; a missing file is the default keymap.
    public func load() -> (Keymap, [KeymapIssue]) {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            lastData = Data()
            return (Keymap(), [])
        }
        lastData = data
        return Keymap.parse(data)
    }

    /// Writes `keymap` (atomically) and applies it to `registry`.
    public func save(_ keymap: Keymap, to registry: CommandRegistry = .shared) throws {
        let data = keymap.encoded()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        lastData = data
        registry.apply(keymap)
        rearmFileSource()
    }

    /// Reloads when the bytes differ from the last load; true if applied.
    @discardableResult
    public func reloadIfChanged(into registry: CommandRegistry = .shared) -> Bool {
        let data = FileManager.default.contents(atPath: url.path) ?? Data()
        guard data != lastData else { return false }
        lastData = data
        let (keymap, issues) = data.isEmpty ? (Keymap(), []) : Keymap.parse(data)
        registry.apply(keymap, issues: issues)
        rearmFileSource()
        reportProblems(of: registry)
        return true
    }

    // MARK: Watching

    /// Starts watching a second after launch (and reports any problems in
    /// the file loaded at launch then).
    public func startWatchingSoon() {
        guard !watchScheduled else { return }
        watchScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.startWatching()
                self.reportProblems(of: .shared)
            }
        }
    }

    /// Watches the folder (atomic replaces, creation, deletion) and the
    /// file (in-place writes), and re-checks on app activation.
    public func startWatching() {
        guard directorySource == nil else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directorySource = source(for: dir.path, mask: [.write, .rename, .delete])
        rearmFileSource()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFromWatcher() }
        }
    }

    public func stopWatching() {
        directorySource?.cancel(); directorySource = nil
        fileSource?.cancel(); fileSource = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
    }

    private func rearmFileSource() {
        guard directorySource != nil else { return }
        fileSource?.cancel()
        fileSource = source(for: url.path, mask: [.write, .extend, .delete, .rename])
    }

    private func source(for path: String, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleReload() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// Editors write in bursts (temp file, rename, attributes): wait for quiet.
    private func scheduleReload() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reloadFromWatcher() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func reloadFromWatcher() { reloadIfChanged(into: target ?? .shared) }

    // MARK: Reporting

    /// Every problem as a line: file issues, then conflicts.
    public static func problemLines(of registry: CommandRegistry) -> [String] {
        var lines = registry.issues.map(\.description)
        for conflict in registry.conflicts {
            let titles = conflict.ids.map { id in registry[id].map { "\($0.title(appName: "BareLipi")) (\(id))" } ?? id }
            lines.append("\(conflict.chord.glyphs) is bound to \(titles.joined(separator: " and ")).")
        }
        return lines
    }

    /// Logs problems and shows them once in an alert (not during tests or
    /// before the app is running).
    func reportProblems(of registry: CommandRegistry) {
        let lines = Self.problemLines(of: registry)
        for line in lines { commandLog.error("keymap: \(line, privacy: .public)") }
        guard !lines.isEmpty, lines != reported, NSApp?.isRunning == true else {
            if lines.isEmpty { reported = [] }
            return
        }
        reported = lines
        let alert = NSAlert()
        alert.messageText = "Problems in keymap.json"
        alert.informativeText = lines.prefix(8).joined(separator: "\n") + (lines.count > 8 ? "\n…and \(lines.count - 8) more." : "")
            + "\n\nSettings → Keys shows every binding."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Settings")
        if alert.runModal() == .alertSecondButtonReturn {
            SettingsWindowController.shared.select("Keys")
            SettingsWindowController.shared.showWindow(nil)
        }
    }
}
