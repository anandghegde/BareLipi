import Darwin
import Foundation

/// What happened to a document's file since its known state (§9.3).
public enum ExternalChange: Sendable, Equatable {
    /// Nothing that matters: same metadata, or an event this app caused.
    case none
    /// Metadata changed but the bytes hash the same (a `touch`, an xattr);
    /// the known state is updated and nothing is shown.
    case metadataOnly(FileFingerprint)
    /// The bytes changed (in place or by replacement of the inode).
    case modified(bytes: Data, fingerprint: FileFingerprint)
    /// Nothing is at the path any more (deleted or moved to the Trash).
    case deleted
    /// The file was renamed or moved outside the app; the document follows it.
    case moved(to: URL)
    /// The file could not be examined: permission or volume error, with the
    /// system's text.
    case unreadable(message: String)
}

/// Decides what a change event means by `stat`ing the path and, only when
/// size, inode or mtime differ, reading and hashing the bytes (§9.3).
public enum ExternalChangeResolver {
    public static func examine(_ url: URL, known: FileFingerprint?, read: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> ExternalChange {
        let current: FileStat
        do {
            current = try FileStat.of(path: url.path)
        } catch let error as POSIXError where error.code == .ENOENT || error.code == .ENOTDIR {
            return .deleted
        } catch {
            return .unreadable(message: error.localizedDescription)
        }
        if let known, known.metadataMatches(current) { return .none }
        let bytes: Data
        do {
            bytes = try read(url)
        } catch {
            if AtomicWriter.posixCode(error) == .ENOENT || (error as NSError).code == CocoaError.fileReadNoSuchFile.rawValue { return .deleted }
            return .unreadable(message: error.localizedDescription)
        }
        let fingerprint = FileFingerprint(stat: (try? FileStat.of(path: url.path)) ?? current, bytes: bytes)
        if let known, known.sha256 == fingerprint.sha256 { return .metadataOnly(fingerprint) }
        return .modified(bytes: bytes, fingerprint: fingerprint)
    }

    /// Whether a path is inside a Trash folder (a move there is a deletion).
    public static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }
}

/// Watches one open file (§9.3): a `DispatchSource` vnode source on an
/// `O_EVTONLY` descriptor, plus whatever else calls `noteEvent()` (the
/// document's `NSFilePresenter` callbacks and app activation). Events are
/// coalesced for 150 ms and then resolved against the known fingerprint, so
/// the same change arriving from three sources is handled once, and the
/// app's own writes (whose fingerprint is recorded) are ignored.
@MainActor
public final class ExternalChangeMonitor {
    /// The resolved path being watched.
    public private(set) var url: URL
    /// The file's state at the last read or write by this app.
    public var known: FileFingerprint?
    /// Receives each resolved change once.
    public var onChange: ((ExternalChange) -> Void)?
    /// Coalescing interval for bursts of events.
    public var coalesceInterval: TimeInterval = 0.15
    /// How bytes are read when metadata changed (the document coordinates).
    public var read: (URL) throws -> Data = { try Data(contentsOf: $0) }

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var watchedInode: UInt64?
    private var pending: DispatchWorkItem?
    private var lastDelivered: ExternalChange?
    public private(set) var isRunning = false

    public init(url: URL, known: FileFingerprint?) {
        self.url = url
        self.known = known
    }

    // Stopping is the owner's job (`stop()` in `close()`); a deinit cannot
    // touch main-actor state, and the event handler holds the monitor weakly.

    /// Starts the vnode watch. Safe to call again (re-opens on the current path).
    public func start() {
        isRunning = true
        openWatch()
    }

    public func stop() {
        isRunning = false
        pending?.cancel()
        pending = nil
        closeWatch()
    }

    /// Records the file's state after the app read or wrote it.
    public func acknowledge(_ fingerprint: FileFingerprint, url: URL? = nil) {
        known = fingerprint
        lastDelivered = nil
        if let url, url.path != self.url.path {
            self.url = url
            if isRunning { openWatch() }
        } else if isRunning, watchedInode != fingerprint.stat.inode {
            openWatch()
        }
    }

    /// The document now lives at `url` (moved by the app, a Save As, or a
    /// presenter callback).
    public func follow(_ url: URL) {
        guard url.path != self.url.path else { return }
        self.url = url
        if isRunning { openWatch() }
    }

    /// Something may have changed: resolve after the coalescing interval.
    public func noteEvent() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { _ = self?.checkNow() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceInterval, execute: item)
    }

    /// Resolves the file's state now and delivers a change if there is one.
    /// Returns what it found (tests call this directly).
    @discardableResult
    public func checkNow() -> ExternalChange {
        pending = nil
        if let moved = movedPath() {
            url = moved
            if isRunning { openWatch() }
            return deliver(.moved(to: moved))
        }
        let change = ExternalChangeResolver.examine(url, known: known, read: read)
        switch change {
        case .none:
            lastDelivered = nil
            return .none
        case .metadataOnly(let fingerprint):
            known = fingerprint
            lastDelivered = nil
            if isRunning, watchedInode != fingerprint.stat.inode { openWatch() }
            return change
        case .modified(_, let fingerprint):
            // Handled once: the known state becomes the disk's, whatever the
            // user chooses, so the same bytes do not prompt again.
            known = fingerprint
            if isRunning, watchedInode != fingerprint.stat.inode { openWatch() }
            return deliver(change)
        case .deleted, .unreadable, .moved:
            return deliver(change)
        }
    }

    /// Delivers `change` unless it is the same as the last one delivered
    /// (a deletion or an error is presented once per event, not per poll).
    private func deliver(_ change: ExternalChange) -> ExternalChange {
        if case .modified = change {} else if change == lastDelivered { return .none }
        lastDelivered = change
        onChange?(change)
        return change
    }

    /// When the watched inode is still linked but under another name (a
    /// rename or move outside the app), its new path; `fcntl(F_GETPATH)`
    /// follows the file id.
    private func movedPath() -> URL? {
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_nlink > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard path != url.path, !ExternalChangeResolver.isInTrash(path) else { return nil }
        // The old path may now hold a different file (an atomic save by
        // another app): that is a modification, not a move.
        if let atOld = try? FileStat.of(path: url.path), atOld.inode != info.st_ino { return nil }
        if AtomicWriter.resolve(URL(fileURLWithPath: path)).path == AtomicWriter.resolve(url).path { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: Vnode source

    private func openWatch() {
        closeWatch()
        let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        descriptor = fd
        watchedInode = (try? FileStat.of(descriptor: fd))?.inode
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib, .link], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.noteEvent() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func closeWatch() {
        source?.cancel()
        source = nil
        descriptor = -1
        watchedInode = nil
    }
}
