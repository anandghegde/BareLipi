import Darwin
import Foundation
import os

/// The only code path that writes a document (PRD §9.3). Resolves symlinks
/// so the target is replaced and the link left alone, then either replaces
/// the file atomically through a temp file in the same directory
/// (`FileManager.replaceItemAt`, `renamex_np(RENAME_SWAP)` on APFS) or, for
/// hard-linked files and on volumes that refuse the replace, writes in place
/// behind a backup. Permissions, extended attributes, the creation date and
/// the file's user flags survive either way.
public struct AtomicWriter: Sendable {
    /// What to do with a file that has more than one hard link.
    public enum HardLinkPolicy: String, Sendable {
        /// Default: write in place with a backup so every link sees the new bytes.
        case writeInPlace
        /// Replace atomically; the other links keep the old bytes.
        case replaceAtomically
    }

    /// How the bytes reached the disk.
    public enum Strategy: String, Sendable, Equatable {
        /// There was no file; a temp file was renamed into place.
        case created
        /// Temp file in the same directory, then `replaceItemAt`.
        case atomicReplace
        /// `open(O_WRONLY)`, `ftruncate`, `write`, `fsync` behind a backup.
        case inPlace
    }

    public struct Options: Sendable {
        /// `fcntl(F_FULLFSYNC)` instead of `fsync`: explicit Cmd-S only.
        public var fullSync = false
        /// Run inside `NSFileCoordinator.coordinate(writingItemAt:options:.forReplacing)`.
        /// `NSDocument` has already coordinated its saves, so it passes false.
        public var coordinate = true
        public var hardLinks: HardLinkPolicy = .writeInPlace
        /// Where in-place writes keep their backup until the write succeeds.
        public var backupDirectory: URL = FileManager.barelipiSupportDirectory("Backups")
        /// `com.apple.TextEncoding` to set on the file; nil leaves it alone.
        public var textEncodingAttribute: String? = "utf-8;134217984"

        public init() {}
    }

    /// The result of a write.
    public struct Outcome: Sendable {
        /// The file actually written (symlinks resolved).
        public var resolvedURL: URL
        public var strategy: Strategy
        /// Why an atomic replace fell back to an in-place write, if it did.
        public var fallbackReason: String?
        /// `stat` and hash of the written file, for external-change detection.
        public var fingerprint: FileFingerprint
    }

    public var options: Options
    static let log = Logger(subsystem: "com.barelipi.app", category: "files")

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Writes `data` to `url` per §9.3. `presenter` is excluded from the
    /// coordination's notifications (the document itself).
    @discardableResult
    public func write(_ data: Data, to url: URL, presenter: NSFilePresenter? = nil) throws -> Outcome {
        let resolved = AtomicWriter.resolve(url)
        guard options.coordinate else { return try perform(data, at: resolved) }
        var coordinationError: NSError?
        var result: Result<Outcome, Error>?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: resolved, options: .forReplacing, error: &coordinationError) { target in
            result = Result { try perform(data, at: target) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    // MARK: Resolve

    /// `realpath(3)` of `url`; for a file that does not exist yet, the real
    /// path of its directory plus its name. A dangling symlink resolves to
    /// the path it points at, so the link survives the first save.
    public static func resolve(_ url: URL) -> URL {
        var path = url.standardizedFileURL.path
        for _ in 0..<32 {
            if let real = realpath(path, nil) {
                defer { free(real) }
                return URL(fileURLWithPath: String(cString: real))
            }
            var info = stat()
            if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(path, &buffer, buffer.count - 1)
                guard n > 0 else { break }
                let target = String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                path = target.hasPrefix("/") ? target : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
                continue
            }
            break
        }
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if let real = realpath(directory, nil) {
            defer { free(real) }
            return URL(fileURLWithPath: (String(cString: real) as NSString).appendingPathComponent(name))
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: Strategy

    private func perform(_ data: Data, at url: URL) throws -> Outcome {
        let path = url.path
        let existing: FileStat?
        do { existing = try FileStat.of(path: path) } catch let error as POSIXError where error.code == .ENOENT { existing = nil }
        var strategy: Strategy
        var fallback: String?
        if let existing {
            if existing.flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path]) }
            if existing.linkCount > 1, options.hardLinks == .writeInPlace {
                try writeInPlace(data, at: url)
                strategy = .inPlace
            } else {
                do {
                    try replaceAtomically(data, at: url, original: existing)
                    strategy = .atomicReplace
                } catch let error where AtomicWriter.shouldFallBack(error) {
                    fallback = "\(error.localizedDescription) (\(AtomicWriter.posixCode(error).map { String(cString: strerror($0.rawValue)) } ?? "no POSIX code"))"
                    AtomicWriter.log.notice("atomic replace of \(path, privacy: .private) failed, writing in place: \(fallback!, privacy: .public)")
                    try writeInPlace(data, at: url)
                    strategy = .inPlace
                }
            }
        } else {
            try create(data, at: url)
            strategy = .created
        }
        if let attribute = options.textEncodingAttribute {
            _ = attribute.withCString { setxattr(path, "com.apple.TextEncoding", $0, strlen($0), 0, 0) }
        }
        let fingerprint = FileFingerprint(stat: try FileStat.of(path: path), bytes: data)
        return Outcome(resolvedURL: url, strategy: strategy, fallbackReason: fallback, fingerprint: fingerprint)
    }

    /// EPERM / EACCES (File Provider volumes, unmaterialised iCloud items, an
    /// unwritable directory) and EXDEV fall back to an in-place write.
    static func shouldFallBack(_ error: Error) -> Bool {
        guard let code = posixCode(error) else {
            let ns = error as NSError
            return ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteNoPermission.rawValue
        }
        return code == .EPERM || code == .EACCES || code == .EXDEV
    }

    static func posixCode(_ error: Error) -> POSIXErrorCode? {
        if let posix = error as? POSIXError { return posix.code }
        var ns = error as NSError
        for _ in 0..<4 {
            if ns.domain == NSPOSIXErrorDomain { return POSIXErrorCode(rawValue: Int32(ns.code)) }
            guard let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            ns = underlying
        }
        return nil
    }

    // MARK: Atomic replace

    private func tempURL(for url: URL) -> URL {
        let suffix = String(UInt32.random(in: .min ... .max), radix: 16)
        return url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).barelipi-\(suffix)")
    }

    /// Writes `data` to a new exclusive temp file beside `url` with `mode`.
    private func writeTemp(_ data: Data, beside url: URL, mode: mode_t) throws -> URL {
        let temp = tempURL(for: url)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try AtomicWriter.writeAll(fd, data)
            try sync(fd)
            if fchmod(fd, mode & 0o7777) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            close(fd)
        } catch {
            close(fd)
            unlink(temp.path)
            throw error
        }
        return temp
    }

    private func create(_ data: Data, at url: URL) throws {
        let mask = umask(0)
        umask(mask)
        let temp = try writeTemp(data, beside: url, mode: 0o666 & ~mask)
        if rename(temp.path, url.path) != 0 {
            let code = errno
            unlink(temp.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private func replaceAtomically(_ data: Data, at url: URL, original: FileStat) throws {
        let path = url.path
        let attributes = ExtendedAttributes.read(path: path)
        let created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
        let temp = try writeTemp(data, beside: url, mode: original.mode)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: [])
        } catch {
            unlink(temp.path)
            throw error
        }
        // replaceItemAt carries metadata over on APFS and HFS+; make sure of
        // it on every volume, and never introduce a quarantine flag.
        restoreMetadata(path: path, mode: original.mode, flags: original.flags, created: created, attributes: attributes)
    }

    private func restoreMetadata(path: String, mode: mode_t, flags: UInt32, created: Date?, attributes: [String: Data]) {
        guard let now = try? FileStat.of(path: path) else { return }
        if now.mode & 0o7777 != mode & 0o7777 { chmod(path, mode & 0o7777) }
        let userFlags = flags & UInt32(UF_SETTABLE) & ~UInt32(UF_IMMUTABLE | UF_APPEND)
        if now.flags & UInt32(UF_SETTABLE) != userFlags { chflags(path, (now.flags & ~UInt32(UF_SETTABLE)) | userFlags) }
        if let created, let current = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date,
           abs(current.timeIntervalSince(created)) > 0.001 {
            try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: path)
        }
        let present = ExtendedAttributes.read(path: path)
        for (name, value) in attributes where present[name] != value {
            ExtendedAttributes.set(name, value, path: path)
        }
        if attributes["com.apple.quarantine"] == nil, present["com.apple.quarantine"] != nil {
            removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    // MARK: In place

    /// Copies the current bytes to the backup directory, rewrites the file
    /// through its existing inode, and removes the backup on success.
    private func writeInPlace(_ data: Data, at url: URL) throws {
        let path = url.path
        let backups = options.backupDirectory
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appendingPathComponent(pathDigest(path) + ".md")
        let current = try Data(contentsOf: url)
        try current.write(to: backup, options: .atomic)
        let fd = open(path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard ftruncate(fd, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try AtomicWriter.writeAll(fd, data)
        try sync(fd)
        try? FileManager.default.removeItem(at: backup)
    }

    // MARK: Primitives

    private func sync(_ fd: Int32) throws {
        if options.fullSync, fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += n
            }
        }
    }
}

/// Extended attributes of a file (not following symlinks).
enum ExtendedAttributes {
    static func read(path: String) -> [String: Data] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [:] }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { return [:] }
        var result: [String: Data] = [:]
        var start = 0
        for i in 0..<size where names[i] == 0 {
            let name = String(decoding: names[start..<i].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            start = i + 1
            let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { continue }
            var value = Data(count: length)
            let read = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
            if read >= 0 { result[name] = value.prefix(read) }
        }
        return result
    }

    static func set(_ name: String, _ value: Data, path: String) {
        _ = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
    }
}
