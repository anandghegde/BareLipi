import CryptoKit
import Darwin
import Foundation

/// What `stat(2)` says about a file, reduced to the fields external-change
/// detection needs (§9.3).
public struct FileStat: Sendable, Equatable {
    public var device: Int32
    public var inode: UInt64
    public var size: Int64
    public var modificationSeconds: Int
    public var modificationNanoseconds: Int
    public var linkCount: Int
    public var mode: mode_t
    public var flags: UInt32

    /// `stat`s `path` (following symlinks). Throws a POSIX error.
    public static func of(path: String) throws -> FileStat {
        var info = stat()
        guard stat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileStat(info)
    }

    /// `fstat`s an open descriptor.
    public static func of(descriptor: Int32) throws -> FileStat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileStat(info)
    }

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modificationSeconds = info.st_mtimespec.tv_sec
        modificationNanoseconds = info.st_mtimespec.tv_nsec
        linkCount = Int(info.st_nlink)
        mode = info.st_mode
        flags = info.st_flags
    }

    public var modificationDate: Date {
        Date(timeIntervalSince1970: Double(modificationSeconds) + Double(modificationNanoseconds) / 1e9)
    }
}

/// The known state of a document's file, recorded at every read and write:
/// `st_ino`, `st_mtimespec`, size and a SHA-256 of the bytes (ADR-008). The
/// next change event is compared against it, so events the app caused
/// itself and a bare `touch` are ignored.
public struct FileFingerprint: Sendable, Equatable {
    public var stat: FileStat
    public var sha256: Data

    public init(stat: FileStat, sha256: Data) {
        self.stat = stat
        self.sha256 = sha256
    }

    /// Fingerprint for bytes just read from or written to a file with `stat`.
    public init(stat: FileStat, bytes: Data) {
        self.init(stat: stat, sha256: FileFingerprint.hash(bytes))
    }

    public static func hash(_ bytes: Data) -> Data {
        Data(SHA256.hash(data: bytes))
    }

    /// Same inode, size and modification time: nothing to read.
    public func metadataMatches(_ other: FileStat) -> Bool {
        stat.inode == other.inode && stat.device == other.device && stat.size == other.size
            && stat.modificationSeconds == other.modificationSeconds
            && stat.modificationNanoseconds == other.modificationNanoseconds
    }
}

extension FileManager {
    /// `~/Library/Application Support/BareLipi/<name>`, created on demand.
    static func barelipiSupportDirectory(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BareLipi", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }
}

/// Hex SHA-256 of a path's file-system representation (backup and snapshot names, §9.3).
func pathDigest(_ path: String) -> String {
    SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
}
