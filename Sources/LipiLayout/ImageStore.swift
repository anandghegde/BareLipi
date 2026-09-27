import CoreGraphics
import Foundation
import ImageIO
import LipiCore

/// Where a document's relative image paths start: its folder, and the
/// `typora-root-url` folder that root-relative `/…` paths resolve under.
public struct ImageBase: Sendable, Hashable {
    public var documentDirectory: URL?
    public var root: URL?

    public init(documentDirectory: URL? = nil, root: URL? = nil) {
        self.documentDirectory = documentDirectory
        self.root = root
    }
}

/// Decodes the editor's images off the main thread (P0-07) and keeps them
/// in a bounded cache, like `HighlightService` does for code: a lookup
/// answers from the cache or `.pending` and queues the work, and
/// `didLoad` is posted on the main thread when a result lands.
///
/// Two tiers: an image's pixel size (small, kept for many images, so the
/// layout does not jump when a bitmap is evicted) and its decoded bitmap
/// (large, least recently used evicted past `byteLimit` / `countLimit`).
/// Bitmaps are downsampled to at most `maxPixelSize` on their long side.
/// Remote (`http:`/`https:`) images are never fetched.
public final class ImageStore: @unchecked Sendable {
    public static let shared = ImageStore()
    /// Posted on the main thread when an image's size or bitmap is known.
    public static let didLoad = Notification.Name("LipiImageStoreDidLoad")

    public enum Status: Sendable, Hashable {
        /// Not decoded yet (the layout shows a placeholder).
        case pending
        /// Decoded; the pixel size after EXIF orientation.
        case ready(CGSize)
        /// Missing, unreadable or not an image: the alt text is shown.
        case failed
        /// An `http(s)` image, not fetched: the alt text is shown.
        case remote

        /// A hash for layout keys: equal stamps mean equal geometry.
        public var stamp: UInt64 {
            switch self {
            case .pending: return 0x11
            case .failed: return 0x23
            case .remote: return 0x37
            case .ready(let size):
                return 0x4B ^ (UInt64(max(0, size.width)) &* 0x100_0000_01B3) ^ (UInt64(max(0, size.height)) << 32)
            }
        }
    }

    struct Key: Hashable, Sendable {
        var source: String
        var base: ImageBase
    }

    private struct Bitmap {
        var image: CGImage
        var cost: Int
        var lastUse: UInt64
    }

    public var byteLimit = 192 << 20
    public var countLimit = 256
    /// Size entries kept (sizes of evicted bitmaps stay known up to this).
    public var sizeLimit = 8192
    public var maxPixelSize = 2560
    /// Off in tests that wait with `waitUntilIdle` instead.
    public var postsNotifications = true

    private let lock = NSLock()
    private var sizes: [Key: Status] = [:]
    private var bitmaps: [Key: Bitmap] = [:]
    private var bitmapBytes = 0
    private var inFlight: Set<Key> = []
    private var clock: UInt64 = 0
    private let queue = DispatchQueue(label: "lipi.images", qos: .userInitiated)

    public init() {}

    // MARK: Lookup

    /// What is known of `image`; queues its decoding the first time.
    public func status(of image: DisplayImage, base: ImageBase) -> Status {
        if image.isRemote { return .remote }
        let key = Key(source: image.source, base: base)
        lock.lock()
        if let status = sizes[key] { lock.unlock(); return status }
        let start = inFlight.insert(key).inserted
        lock.unlock()
        if start { schedule(key) }
        return .pending
    }

    /// The decoded bitmap of `image`, or nil (queuing a decode when its size
    /// is known but the bitmap was evicted).
    public func bitmap(of image: DisplayImage, base: ImageBase) -> CGImage? {
        guard !image.isRemote else { return nil }
        let key = Key(source: image.source, base: base)
        lock.lock()
        clock &+= 1
        if var entry = bitmaps[key] {
            entry.lastUse = clock
            bitmaps[key] = entry
            lock.unlock()
            return entry.image
        }
        var start = false
        if case .ready? = sizes[key] { start = inFlight.insert(key).inserted }
        lock.unlock()
        if start { schedule(key) }
        return nil
    }

    /// Bytes held by decoded bitmaps.
    public var cachedBytes: Int { lock.withLock { bitmapBytes } }
    public var cachedBitmapCount: Int { lock.withLock { bitmaps.count } }

    /// Forgets everything (tests; a file changed on disk).
    public func removeAll() {
        lock.withLock {
            sizes.removeAll()
            bitmaps.removeAll()
            bitmapBytes = 0
        }
    }

    /// Blocks until queued decodes finished (tests).
    public func waitUntilIdle() { queue.sync {} }

    // MARK: Decoding

    private func schedule(_ key: Key) {
        queue.async { [self] in
            let result = Self.decode(key, maxPixelSize: maxPixelSize)
            lock.lock()
            inFlight.remove(key)
            if sizes[key] == nil, sizes.count >= sizeLimit { sizes.removeAll(keepingCapacity: true) }
            sizes[key] = result.status
            if let image = result.image {
                clock &+= 1
                let cost = image.bytesPerRow * image.height
                if let old = bitmaps[key] { bitmapBytes -= old.cost }
                bitmaps[key] = Bitmap(image: image, cost: cost, lastUse: clock)
                bitmapBytes += cost
                evict()
            }
            lock.unlock()
            guard postsNotifications else { return }
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didLoad, object: self) }
        }
    }

    /// Drops least recently used bitmaps past the limits (lock held).
    private func evict() {
        guard bitmapBytes > byteLimit || bitmaps.count > countLimit else { return }
        for (key, entry) in bitmaps.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
            guard bitmapBytes > byteLimit || bitmaps.count > countLimit, bitmaps.count > 1 else { break }
            bitmaps[key] = nil
            bitmapBytes -= entry.cost
        }
    }

    static func decode(_ key: Key, maxPixelSize: Int) -> (status: Status, image: CGImage?) {
        guard let url = ImageSource.resolve(key.source, documentDirectory: key.base.documentDirectory, root: key.base.root),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else {
            return (.failed, nil)
        }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let size = orientation >= 5 && orientation <= 8 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), maxPixelSize),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return (.failed, nil) }
        return (.ready(size), image)
    }
}
