import CTreeSitter
import Foundation

/// Highlights fenced code blocks (PRD §6.5, ADR-007).
///
/// Nothing here runs on the keystroke path: `lookup` answers from the cache
/// and, on a miss, queues the block for a background parse and returns the
/// most similar earlier result for the same language, re-aligned around the
/// edit, so a fence keeps its previous colours until the new ones land.
/// Results are cached by (grammar, code text); when one lands the service
/// posts `didHighlight` on the main queue and the editor re-typesets its
/// code blocks.
public final class HighlightService: @unchecked Sendable {
    public static let shared = HighlightService()

    /// Posted on the main queue after background results were cached.
    public static let didHighlight = Notification.Name("LipiHighlight.didHighlight")

    public struct Result: Sendable {
        public var spans: [HighlightSpan]
        /// Whether these are the spans of exactly this text (false while a
        /// provisional result stands in for a pending parse).
        public var isExact: Bool
        /// Changes whenever `spans` do; part of a layout's cache key.
        public var stamp: UInt64
    }

    private struct Key: Hashable {
        var grammar: String
        var text: String
    }

    private struct Entry {
        var spans: [HighlightSpan]
        var stamp: UInt64
        var lastUse: UInt64
    }

    private let lock = NSLock()
    private var cache: [Key: Entry] = [:]
    private var recent: [String: [Key]] = [:]
    /// Requested texts not parsed yet, with the clock of their request.
    private var pending: [Key: (grammar: Grammar, requested: UInt64)] = [:]
    private var draining = false
    private var clock: UInt64 = 0
    private let queue = DispatchQueue(label: "lipi.highlight", qos: .utility)
    /// Entries kept (each a few spans per line of code).
    public let capacity: Int
    /// Whether results are posted with `didHighlight` (tests turn it off).
    public var postsNotifications = true

    public init(capacity: Int = 512) {
        self.capacity = capacity
    }

    /// Spans for `code` if cached; otherwise schedules it and returns a
    /// provisional result (possibly empty). Cheap: one hash of the text.
    public func lookup(code: String, grammar: Grammar) -> Result {
        let key = Key(grammar: grammar.id, text: code)
        lock.lock()
        clock += 1
        if var entry = cache[key] {
            entry.lastUse = clock
            cache[key] = entry
            lock.unlock()
            return Result(spans: entry.spans, isExact: true, stamp: entry.stamp)
        }
        let provisional = provisionalSpans(for: code, grammar: grammar.id)
        pending[key] = (grammar, clock)
        let schedule = !draining
        draining = true
        lock.unlock()
        if schedule { queue.async { [self] in drain() } }
        return Result(spans: provisional, isExact: false, stamp: HighlightService.stamp(of: provisional) ^ 0x5bd1_e995)
    }

    /// Parses the newest request first and drops older requests that look
    /// like earlier versions of the same fence (same grammar, same first or
    /// last 32 bytes): while someone types in a fence every keystroke asks
    /// for a new text, and only the last one matters. A text dropped by
    /// mistake is asked for again when the editor re-lays out its code
    /// blocks after `didHighlight`.
    private func drain() {
        lock.lock()
        guard let (key, request) = pending.max(by: { $0.value.requested < $1.value.requested }) else {
            draining = false
            lock.unlock()
            return
        }
        pending.removeValue(forKey: key)
        let head = key.text.utf8.prefix(32)
        let tail = key.text.utf8.suffix(32)
        pending = pending.filter { other, _ in
            other.grammar != key.grammar || !(other.text.utf8.prefix(32).elementsEqual(head) || other.text.utf8.suffix(32).elementsEqual(tail))
        }
        lock.unlock()
        let spans = HighlightService.compute(code: key.text, grammar: request.grammar)
        store(key, spans)
        lock.lock()
        let more = !pending.isEmpty
        if !more { draining = false }
        lock.unlock()
        if !more && postsNotifications {
            DispatchQueue.main.async { NotificationCenter.default.post(name: HighlightService.didHighlight, object: self) }
        }
        if more { queue.async { [self] in drain() } }
    }

    /// Computes (or returns the cached) spans synchronously. Used by export
    /// and tests; never on the main thread in the editor.
    public func highlight(code: String, grammar: Grammar) -> [HighlightSpan] {
        let key = Key(grammar: grammar.id, text: code)
        lock.lock()
        if let entry = cache[key] { lock.unlock(); return entry.spans }
        lock.unlock()
        let spans = HighlightService.compute(code: code, grammar: grammar)
        store(key, spans)
        return spans
    }

    /// Blocks until queued background work has finished (tests).
    public func waitUntilIdle() {
        while true {
            queue.sync {}
            lock.lock()
            let idle = !draining
            lock.unlock()
            if idle { return }
        }
    }

    public func removeAll() {
        lock.lock()
        cache.removeAll()
        recent.removeAll()
        lock.unlock()
    }

    private func store(_ key: Key, _ spans: [HighlightSpan]) {
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        cache[key] = Entry(spans: spans, stamp: HighlightService.stamp(of: spans), lastUse: clock)
        var keys = recent[key.grammar] ?? []
        keys.removeAll { $0 == key }
        keys.append(key)
        if keys.count > 8 { keys.removeFirst(keys.count - 8) }
        recent[key.grammar] = keys
        if cache.count > capacity {
            let victims = cache.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(capacity / 4)
            for (victim, _) in victims { cache.removeValue(forKey: victim) }
            for (grammar, keys) in recent { recent[grammar] = keys.filter { cache[$0] != nil } }
        }
    }

    /// The recent result for the same grammar sharing the most text with
    /// `code`, with spans before the edit kept and spans after it shifted.
    /// Caller holds the lock.
    private func provisionalSpans(for code: String, grammar: String) -> [HighlightSpan] {
        guard let keys = recent[grammar], !keys.isEmpty else { return [] }
        let new = Array(code.utf16)
        var best: (spans: [HighlightSpan], score: Int)? = nil
        for key in keys.reversed() {
            guard let entry = cache[key] else { continue }
            let old = Array(key.text.utf16)
            var prefix = 0
            let limit = min(old.count, new.count)
            while prefix < limit, old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < limit - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
            let score = prefix + suffix
            guard score > 0, score > (best?.score ?? 0) else { continue }
            let delta = new.count - old.count
            var spans: [HighlightSpan] = []
            for span in entry.spans {
                if span.range.upperBound <= prefix {
                    spans.append(span)
                } else if span.range.lowerBound >= old.count - suffix {
                    spans.append(HighlightSpan(range: (span.range.lowerBound + delta)..<(span.range.upperBound + delta), token: span.token))
                }
            }
            best = (spans, score)
        }
        return best?.spans ?? []
    }

    static func stamp(of spans: [HighlightSpan]) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ v: Int) { h = (h ^ UInt64(bitPattern: Int64(v))) &* 0x100_0000_01B3 }
        mix(spans.count)
        for span in spans {
            mix(span.range.lowerBound); mix(span.range.upperBound); mix(Int(span.token.rawValue))
        }
        return h
    }

    // MARK: Parsing

    /// Parser per thread: `TSParser` is not thread-safe, and the service
    /// parses on its queue while export may call `highlight` elsewhere.
    private static func withParser<T>(_ body: (OpaquePointer) -> T) -> T {
        let parser = ts_parser_new()!
        defer { ts_parser_delete(parser) }
        return body(parser)
    }

    static func compute(code: String, grammar: Grammar) -> [HighlightSpan] {
        guard !code.isEmpty, let language = grammar.language, let query = grammar.query else { return [] }
        let utf16 = Array(code.utf16)
        return withParser { parser in
            guard ts_parser_set_language(parser, language) else { return [] }
            return utf16.withUnsafeBufferPointer { buffer -> [HighlightSpan] in
                let tree = buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count * 2) {
                    ts_parser_parse_string_encoding(parser, nil, $0, UInt32(buffer.count * 2), TSInputEncodingUTF16LE)
                }
                guard let tree else { return [] }
                defer { ts_tree_delete(tree) }
                return query.spans(root: ts_tree_root_node(tree), utf16: buffer)
            }
        }
    }
}
