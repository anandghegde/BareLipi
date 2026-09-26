import CTreeSitter
import Foundation

/// A compiled highlights query with its text predicates.
///
/// Upstream queries are written against their own grammar revision and for
/// different hosts, so a pattern can name a node the vendored parser lacks.
/// Such patterns are dropped one at a time until the rest compiles
/// (`droppedPatterns` counts them); the text predicates tree-sitter leaves to
/// the host (`#eq?`, `#match?`, `#any-of?`, Neovim's `#lua-match?` and their
/// negations) are evaluated here, and directives such as `#set!` are ignored.
public final class HighlightQuery: @unchecked Sendable {
    let query: OpaquePointer
    /// Token per capture id (`nil`: plain, or an internal `_capture`).
    let tokens: [SyntaxToken?]
    /// Captures whose name starts with `_` never paint.
    let internalCaptures: [Bool]
    /// `@embedded` / `@none`: reset to the plain code colour (the code
    /// inside a string interpolation). Other plain captures (variables,
    /// punctuation) inherit the colour of the node around them, so the `+`
    /// of a diff line stays green.
    let resets: [Bool]
    let predicates: [[Predicate]]
    let laterPatternsWin: Bool
    public let patternCount: Int
    public private(set) var droppedPatterns = 0

    enum Operand {
        case capture(UInt32)
        case string(String)
    }

    enum Predicate {
        case eq(capture: UInt32, operand: Operand, negated: Bool, any: Bool)
        case match(capture: UInt32, regex: NSRegularExpression, negated: Bool, any: Bool)
        case anyOf(capture: UInt32, values: Set<String>, negated: Bool)
    }

    init?(language: OpaquePointer, source: String, laterPatternsWin: Bool) {
        var text = source
        var dropped = 0
        var compiled: OpaquePointer? = nil
        for _ in 0..<200 {
            var errorOffset: UInt32 = 0
            var errorType = TSQueryErrorNone
            let utf8 = Array(text.utf8)
            compiled = utf8.withUnsafeBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                    ts_query_new(language, $0, UInt32(buffer.count), &errorOffset, &errorType)
                }
            }
            if compiled != nil { break }
            guard let range = HighlightQuery.patternRange(in: utf8, containing: Int(errorOffset)) else { return nil }
            var bytes = utf8
            bytes.replaceSubrange(range, with: [])
            text = String(decoding: bytes, as: UTF8.self)
            dropped += 1
        }
        guard let compiled else { return nil }
        query = compiled
        droppedPatterns = dropped
        self.laterPatternsWin = laterPatternsWin
        patternCount = Int(ts_query_pattern_count(compiled))

        var tokens: [SyntaxToken?] = []
        var internalCaptures: [Bool] = []
        var resets: [Bool] = []
        for id in 0..<ts_query_capture_count(compiled) {
            let name = HighlightQuery.captureName(compiled, id)
            tokens.append(SyntaxToken.forCapture(name))
            internalCaptures.append(name.hasPrefix("_"))
            resets.append(name == "none" || name == "embedded" || name.hasPrefix("embedded."))
        }
        self.tokens = tokens
        self.internalCaptures = internalCaptures
        self.resets = resets

        var predicates: [[Predicate]] = []
        for pattern in 0..<UInt32(patternCount) {
            predicates.append(HighlightQuery.parsePredicates(compiled, pattern: pattern))
        }
        self.predicates = predicates
    }

    deinit { ts_query_delete(query) }

    static func captureName(_ query: OpaquePointer, _ id: UInt32) -> String {
        var length: UInt32 = 0
        guard let pointer = ts_query_capture_name_for_id(query, id, &length) else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(length)), as: UTF8.self)
    }

    static func stringValue(_ query: OpaquePointer, _ id: UInt32) -> String {
        var length: UInt32 = 0
        guard let pointer = ts_query_string_value_for_id(query, id, &length) else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(length)), as: UTF8.self)
    }

    private static func parsePredicates(_ query: OpaquePointer, pattern: UInt32) -> [Predicate] {
        var count: UInt32 = 0
        guard let steps = ts_query_predicates_for_pattern(query, pattern, &count), count > 0 else { return [] }
        var result: [Predicate] = []
        var current: [TSQueryPredicateStep] = []
        for i in 0..<Int(count) {
            let step = steps[i]
            if step.type == TSQueryPredicateStepTypeDone {
                if let predicate = makePredicate(query, current) { result.append(predicate) }
                current.removeAll()
            } else {
                current.append(step)
            }
        }
        return result
    }

    private static func makePredicate(_ query: OpaquePointer, _ steps: [TSQueryPredicateStep]) -> Predicate? {
        guard steps.count >= 2, steps[0].type == TSQueryPredicateStepTypeString,
              steps[1].type == TSQueryPredicateStepTypeCapture else { return nil }
        var name = stringValue(query, steps[0].value_id)
        let capture = steps[1].value_id
        let negated = name.hasPrefix("not-")
        if negated { name.removeFirst(4) }
        let any = name.hasPrefix("any-") && name != "any-of?"
        if any { name.removeFirst(4) }
        let args = steps.dropFirst(2).map { step -> Operand in
            step.type == TSQueryPredicateStepTypeCapture ? .capture(step.value_id) : .string(stringValue(query, step.value_id))
        }
        switch name {
        case "eq?":
            guard let first = args.first else { return nil }
            return .eq(capture: capture, operand: first, negated: negated, any: any)
        case "match?", "lua-match?", "vim-match?":
            guard case .string(var pattern) = args.first else { return nil }
            if name == "lua-match?" { pattern = luaPatternToRegex(pattern) }
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return .match(capture: capture, regex: regex, negated: negated, any: any)
        case "any-of?":
            var values = Set<String>()
            for arg in args { if case .string(let s) = arg { values.insert(s) } }
            return .anyOf(capture: capture, values: values, negated: negated)
        default:
            return nil
        }
    }

    /// Lua patterns (`%a`, `%d`, `%.`) as ICU regular expressions.
    static func luaPatternToRegex(_ pattern: String) -> String {
        var out = ""
        var chars = pattern.makeIterator()
        while let c = chars.next() {
            guard c == "%", let n = chars.next() else {
                out.append(c == "-" ? "*?" : String(c))
                continue
            }
            switch n {
            case "a": out += "[A-Za-z]"
            case "d": out += "[0-9]"
            case "l": out += "[a-z]"
            case "u": out += "[A-Z]"
            case "w": out += "[A-Za-z0-9]"
            case "s": out += "\\s"
            case "x": out += "[0-9A-Fa-f]"
            case "p": out += "[[:punct:]]"
            case "A": out += "[^A-Za-z]"
            case "D": out += "[^0-9]"
            case "S": out += "\\S"
            case "W": out += "[^A-Za-z0-9]"
            default: out += "\\" + String(n)
            }
        }
        return out
    }

    // MARK: Pattern splitting

    /// Byte range of the top-level pattern around `offset`: a pattern is a
    /// parenthesised or bracketed group, a string or a wildcard, followed by
    /// its captures and quantifiers.
    static func patternRange(in text: [UInt8], containing offset: Int) -> Range<Int>? {
        var starts: [Int] = []
        var i = 0
        var depth = 0
        let n = text.count
        var atTopItem = false
        while i < n {
            let c = text[i]
            if c == UInt8(ascii: ";") {
                while i < n, text[i] != UInt8(ascii: "\n") { i += 1 }
                continue
            }
            if c == UInt8(ascii: "\"") {
                if depth == 0 { starts.append(i); atTopItem = true }
                i += 1
                while i < n, text[i] != UInt8(ascii: "\"") { i += text[i] == UInt8(ascii: "\\") ? 2 : 1 }
                i += 1
                continue
            }
            if c == UInt8(ascii: "(") || c == UInt8(ascii: "[") {
                if depth == 0 { starts.append(i); atTopItem = true }
                depth += 1
            } else if c == UInt8(ascii: ")") || c == UInt8(ascii: "]") {
                depth = max(0, depth - 1)
            } else if depth == 0, !(c == 32 || c == 9 || c == 10 || c == 13) {
                // Captures, quantifiers and anchors belong to the previous item;
                // anything else (`_`, a bare node name) starts a pattern.
                let continues = c == UInt8(ascii: "@") || c == UInt8(ascii: "*") || c == UInt8(ascii: "+")
                    || c == UInt8(ascii: "?") || c == UInt8(ascii: ".")
                if !continues && !atTopItem { starts.append(i) }
                if c == UInt8(ascii: "@") || !continues {
                    // Skip the identifier.
                    i += 1
                    while i < n, !(text[i] == 32 || text[i] == 9 || text[i] == 10 || text[i] == 13
                                   || text[i] == UInt8(ascii: "(") || text[i] == UInt8(ascii: ")")
                                   || text[i] == UInt8(ascii: "[") || text[i] == UInt8(ascii: "]")) { i += 1 }
                    atTopItem = false
                    continue
                }
            }
            if depth == 0, c == UInt8(ascii: ")") || c == UInt8(ascii: "]") { atTopItem = false }
            i += 1
        }
        guard !starts.isEmpty else { return nil }
        let clamped = min(max(offset, 0), n)
        guard let index = starts.lastIndex(where: { $0 <= clamped }) else { return starts[0]..<(starts.count > 1 ? starts[1] : n) }
        let end = index + 1 < starts.count ? starts[index + 1] : n
        return starts[index]..<end
    }

    // MARK: Running

    /// Highlights of `root` over `utf16` (the parsed text), as a token per
    /// UTF-16 unit run-length encoded into spans. With `window` (UTF-16),
    /// only matches intersecting it are run (very large fences, §6.5).
    func spans(root: TSNode, utf16: UnsafeBufferPointer<UInt16>, window: Range<Int>? = nil) -> [HighlightSpan] {
        let length = utf16.count
        guard length > 0 else { return [] }
        guard let cursor = ts_query_cursor_new() else { return [] }
        defer { ts_query_cursor_delete(cursor) }
        ts_query_cursor_set_match_limit(cursor, 2048)
        if let window {
            let lo = min(max(0, window.lowerBound), length), hi = min(max(lo, window.upperBound), length)
            ts_query_cursor_set_byte_range(cursor, UInt32(lo * 2), UInt32(hi * 2))
        }
        ts_query_cursor_exec(cursor, query, root)

        struct Hit {
            var start: Int
            var end: Int
            var pattern: UInt32
            var token: SyntaxToken?
            var reset: Bool
            /// Whether this capture says anything about colour.
            var paints: Bool { token != nil || reset }
        }
        // Winning capture per node range.
        var hits: [Int64: Hit] = [:]
        var match = TSQueryMatch()
        while ts_query_cursor_next_match(cursor, &match) {
            let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
            if !predicatesHold(pattern: Int(match.pattern_index), captures: captures, utf16: utf16) { continue }
            for capture in captures {
                let id = Int(capture.index)
                if internalCaptures[id] { continue }
                let start = Int(ts_node_start_byte(capture.node)) / 2
                let end = min(Int(ts_node_end_byte(capture.node)) / 2, length)
                guard start < end else { continue }
                let key = Int64(start) << 32 | Int64(end)
                let hit = Hit(start: start, end: end, pattern: UInt32(match.pattern_index), token: tokens[id], reset: resets[id])
                if let existing = hits[key] {
                    // A colouring capture beats a plain one whatever the
                    // order: queries written for tree-sitter-highlight lead
                    // with `(identifier) @variable`, which hosts without a
                    // `variable` colour skip.
                    let replace: Bool
                    if hit.paints != existing.paints {
                        replace = hit.paints
                    } else {
                        replace = laterPatternsWin ? hit.pattern >= existing.pattern : hit.pattern < existing.pattern
                    }
                    if replace { hits[key] = hit }
                } else {
                    hits[key] = hit
                }
            }
        }
        // Paint outer nodes first so inner ones (an escape in a string) win.
        let ordered = hits.values.sorted { a, b in
            a.start != b.start ? a.start < b.start : a.end > b.end
        }
        var paint = [UInt8](repeating: 0, count: length)
        for hit in ordered where hit.paints {
            let value = hit.token?.rawValue ?? 0
            for i in hit.start..<hit.end { paint[i] = value }
        }
        var spans: [HighlightSpan] = []
        var i = 0
        while i < length {
            let value = paint[i]
            var j = i + 1
            while j < length, paint[j] == value { j += 1 }
            if value != 0, let token = SyntaxToken(rawValue: value) {
                spans.append(HighlightSpan(range: i..<j, token: token))
            }
            i = j
        }
        return spans
    }

    private func predicatesHold(pattern: Int, captures: UnsafeBufferPointer<TSQueryCapture>,
                                utf16: UnsafeBufferPointer<UInt16>) -> Bool {
        let list = predicates[pattern]
        if list.isEmpty { return true }
        func texts(_ id: UInt32) -> [String] {
            captures.filter { $0.index == id }.map { capture in
                let start = Int(ts_node_start_byte(capture.node)) / 2
                let end = min(Int(ts_node_end_byte(capture.node)) / 2, utf16.count)
                guard start < end else { return "" }
                return String(decoding: UnsafeBufferPointer(rebasing: utf16[start..<end]), as: UTF16.self)
            }
        }
        for predicate in list {
            switch predicate {
            case let .eq(capture, operand, negated, any):
                let values = texts(capture)
                if values.isEmpty { continue }
                let other: [String]
                switch operand {
                case .string(let s): other = [s]
                case .capture(let id): other = texts(id)
                }
                let test = { (v: String) in other.contains(v) != negated }
                if any ? !values.contains(where: test) : !values.allSatisfy(test) { return false }
            case let .match(capture, regex, negated, any):
                let values = texts(capture)
                if values.isEmpty { continue }
                let test = { (v: String) in
                    (regex.firstMatch(in: v, range: NSRange(location: 0, length: (v as NSString).length)) != nil) != negated
                }
                if any ? !values.contains(where: test) : !values.allSatisfy(test) { return false }
            case let .anyOf(capture, values, negated):
                for v in texts(capture) where values.contains(v) == negated { return false }
            }
        }
        return true
    }
}
