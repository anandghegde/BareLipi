/// GitHub emoji shortcodes (`:smile:` → 😄), PRD §6.13: rendered in place of
/// the shortcode and offered by the completion popover after `:` plus two
/// characters. The data is gemoji's (`EmojiShortcodeTable.swift`).
public enum EmojiShortcodes {
    public struct Entry: Sendable, Hashable {
        /// The alias without colons (`smile`).
        public let name: String
        public let emoji: String
        public let tags: [String]
    }

    /// Every alias, in gemoji's order (grouped by category, common first).
    public static let all: [Entry] = table.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 2 else { return nil }
        let tags = fields.count > 2 ? fields[2].split(separator: " ").map(String.init) : []
        return Entry(name: String(fields[0]), emoji: String(fields[1]), tags: tags)
    }

    private static let byName: [String: String] = {
        var out: [String: String] = [:]
        for e in all where out[e.name] == nil { out[e.name] = e.emoji }
        return out
    }()

    /// The emoji for an alias (`smile`), or nil.
    public static func emoji(for name: String) -> String? { byName[name] }

    /// Bytes allowed in an alias: `a-z 0-9 _ + -`.
    public static func isNameByte(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x5F || b == 0x2B || b == 0x2D
    }

    /// Completions for a partial alias: aliases starting with `query`, then
    /// aliases containing it, then those whose tags start with it.
    public static func completions(for query: String, limit: Int = 12) -> [Entry] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var prefix: [Entry] = [], infix: [Entry] = [], tagged: [Entry] = []
        var seen = Set<String>()
        for e in all {
            if e.name.hasPrefix(q) { prefix.append(e) }
            else if e.name.contains(q) { infix.append(e) }
            else if e.tags.contains(where: { $0.hasPrefix(q) }) { tagged.append(e) }
        }
        var out: [Entry] = []
        for e in prefix + infix + tagged where seen.insert(e.name).inserted {
            out.append(e)
            if out.count == limit { break }
        }
        return out
    }

    /// Shortcodes in `bytes`: ranges of `:alias:` with a known alias.
    public static func matches(in bytes: some Collection<UInt8>) -> [(range: Range<Int>, emoji: String)] {
        let b = Array(bytes)
        var out: [(Range<Int>, String)] = []
        var i = 0
        while i < b.count {
            guard b[i] == 0x3A else { i += 1; continue }
            var j = i + 1
            while j < b.count, isNameByte(b[j]) { j += 1 }
            if j < b.count, b[j] == 0x3A, j > i + 1,
               let name = String(bytes: b[(i + 1)..<j], encoding: .utf8), let emoji = byName[name] {
                out.append((i..<(j + 1), emoji))
                i = j + 1
            } else {
                // A colon at `j` may open the next shortcode.
                i = j
            }
        }
        return out
    }
}
