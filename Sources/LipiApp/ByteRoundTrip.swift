import AppKit
import LipiCore
import LipiEditor
import LipiFixtures
import LipiLayout

/// What the byte-preservation check found for one file.
public struct ByteCheckReport: Sendable {
    public var name: String
    public var failures: [String] = []
    /// Command problems in text with a lone `\r` line break, a known
    /// limitation (README): the editor's lines end at `\n` only, so its
    /// commands see such text as one line while the parser does not. The
    /// bytes-outside-the-edits and undo checks still apply.
    public var known: [String] = []
    /// Editing commands run, and how many of them changed the text.
    public var editsTried = 0
    public var editsApplied = 0
    /// The file opened read-only (not UTF-8): no edits were attempted
    /// beyond checking that they are refused.
    public var readOnly = false
    public var passed: Bool { failures.isEmpty }

    public init(name: String) { self.name = name }
}

/// The Phase 1 byte-preservation exit check (PRD §6.1.7, §9.3), usable from
/// tests and from `lipi-roundtrip` over any folder:
///
/// - open → save through `LipiDocument` (read, window, `AtomicWriter`)
///   writes back the exact bytes, read-only files included;
/// - projecting in hybrid mode, moving the caret, source mode, themes,
///   zoom, contrast, widths, optional syntax, focus and typewriter modes and
///   drawing never change the buffer;
/// - a seeded random run of editing commands changes only the bytes inside
///   the edits each change declares (`EditorController.onEdits`), never
///   splits a scalar or a CRLF pair, writes the document's own line ending,
///   and undoing every step restores the exact original bytes (redo the
///   exact final bytes).
@MainActor
public enum ByteRoundTrip {
    public struct Options: Sendable {
        /// Random editing commands per file.
        public var steps = 40
        public var seed: UInt64 = 0x00B1_7E00
        /// Run the document open → save check (needs a scratch directory).
        public var document = true
        /// Run the view check (projection, modes, themes, settings).
        public var views = true
        /// Draw through an `EditorView` during the view check.
        public var render = true
        /// Files larger than this get a quarter of the steps.
        public var largeFile = 256 * 1024

        public init(steps: Int = 40, seed: UInt64 = 0x00B1_7E00, document: Bool = true, views: Bool = true,
                    render: Bool = true) {
            self.steps = steps
            self.seed = seed
            self.document = document
            self.views = views
            self.render = render
        }
    }

    /// Runs every check on `data`. `scratch` is a directory the document
    /// check may write into.
    public static func check(name: String, data: Data, options: Options = Options(), scratch: URL?) -> ByteCheckReport {
        var report = ByteCheckReport(name: name)
        note("file \(name)")
        let decoded = TextCodec.decode(data)
        report.readOnly = decoded.isReadOnly
        report.failures += checkCodec(data).map { "codec: " + $0 }
        if options.document, let scratch {
            report.failures += checkDocument(data, in: scratch).map { "document: " + $0 }
        }
        guard !decoded.isReadOnly else { return report }
        if options.views {
            report.failures += checkViews(decoded.text, render: options.render).map { "views: " + $0 }
        }
        var seed = options.seed
        for b in name.utf8 { seed = (seed ^ UInt64(b)) &* 0x100_0000_01B3 }
        let steps = data.count > options.largeFile ? (options.steps + 3) / 4 : options.steps
        let edits = checkEdits(decoded.text, steps: steps, seed: seed)
        report.failures += edits.failures.map { "edits: " + $0 }
        report.known += edits.known.map { "edits: " + $0 }
        report.editsTried = edits.tried
        report.editsApplied = edits.applied
        return report
    }

    // MARK: (a) Open and save

    /// Decode → encode, the core of `LipiDocument.currentBytes()`.
    public static func checkCodec(_ data: Data) -> [String] {
        let decoded = TextCodec.decode(data)
        let saved = decoded.originalBytes ?? TextCodec.encode(LipiRope(decoded.text), format: decoded.format)
        var failures: [String] = []
        if let diff = firstDifference(Array(saved), Array(data)) { failures.append("decode → encode differs at byte \(diff)") }
        if !decoded.isReadOnly, TextCodec.encode(LipiRope(decoded.text), format: decoded.format) != data {
            failures.append("UTF-8 text does not re-encode to the same bytes")
        }
        return failures
    }

    /// Writes `data` to a file in `directory`, opens it as a `LipiDocument`
    /// with its window, and saves it (Cmd-S and autosave). Editable files
    /// also get an edit that is undone before the save; read-only files get
    /// an edit that must be refused.
    public static func checkDocument(_ data: Data, in directory: URL) -> [String] {
        let url = directory.appendingPathComponent("roundtrip-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        var failures: [String] = []
        do {
            try data.write(to: url)
            let document = LipiDocument()
            try document.read(from: url, ofType: "net.daringfireball.markdown")
            document.fileURL = url
            document.fileType = "net.daringfireball.markdown"
            document.makeWindowControllers()
            defer { document.close() }
            guard let controller = document.windowController?.controller else { return ["no window controller"] }
            let decoded = TextCodec.decode(data)
            if document.isReadOnly != decoded.isReadOnly { failures.append("read-only is \(document.isReadOnly), expected \(decoded.isReadOnly)") }
            let generation = controller.buffer.generation
            controller.moveCaret(to: controller.count)
            controller.insert("x")
            controller.insertNewline()
            if document.isReadOnly {
                if controller.buffer.generation != generation { failures.append("a read-only document accepted an edit") }
            } else {
                controller.undo()
                controller.undo()
                if controller.canUndo { failures.append("undo history left after undoing the edit") }
            }
            if document.currentBytes() != data { failures.append("currentBytes() differs") }
            try document.writeSafely(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation)
            if let diff = firstDifference(Array(try Data(contentsOf: url)), Array(data)) { failures.append("save differs at byte \(diff)") }
            try document.writeSafely(to: url, ofType: "net.daringfireball.markdown", for: .autosaveInPlaceOperation)
            if let diff = firstDifference(Array(try Data(contentsOf: url)), Array(data)) { failures.append("autosave differs at byte \(diff)") }
        } catch {
            failures.append("\(error)")
        }
        return failures
    }

    // MARK: (b) Views and settings

    /// Projection, caret reveal, source mode, themes and settings must not
    /// touch the buffer.
    public static func checkViews(_ text: String, render: Bool) -> [String] {
        let want = Data(text.utf8)
        let c = EditorController(text: text, viewportWidth: 800)
        let generation = c.buffer.generation
        var failures: [String] = []
        func verify(_ label: String) {
            if c.buffer.generation != generation || c.canUndo { failures.append("\(label) edited the buffer") }
            if let diff = firstDifference(Array(bytes(c)), Array(want)) { failures.append("\(label) changed byte \(diff)") }
        }
        func prepareAll() {
            let height = max(c.contentHeight, 600)
            _ = c.prepare(CGRect(x: 0, y: 0, width: 1200, height: 1800))
            _ = c.prepare(CGRect(x: 0, y: max(0, height - 1200), width: 1200, height: 1200))
        }
        verify("open")
        prepareAll()
        verify("hybrid projection")
        var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: want.count) &+ 17)
        let bytesArray = Array(want)
        for _ in 0..<8 {
            c.moveCaret(to: caretPosition(in: bytesArray, &rng))
            _ = c.prepare(CGRect(x: 0, y: max(0, c.caretRect(forSource: c.caret).minY - 400), width: 1200, height: 800))
        }
        let a = caretPosition(in: bytesArray, &rng), b = caretPosition(in: bytesArray, &rng)
        c.select(min(a, b)..<max(a, b))
        c.move(.right, extend: true)
        c.move(.wordLeft)
        c.move(.down)
        verify("caret reveal")
        c.setMode(.source)
        prepareAll()
        verify("source mode")
        c.setMode(.hybrid)
        prepareAll()
        verify("back to hybrid")
        for theme in Theme.all {
            c.setTheme(theme, zoom: 1.3)
            prepareAll()
        }
        c.setTheme(.taalegari, zoom: 1)
        c.increaseContrast = true
        c.increaseContrast = false
        verify("themes")
        c.setOptionalSyntax(subscript: true, superscript: true, highlight: true)
        prepareAll()
        c.setOptionalSyntax(subscript: false, superscript: false, highlight: false)
        c.setViewportWidth(320)
        prepareAll()
        c.setViewportWidth(1400)
        c.settings = EditorSettings(emphasisMarker: "_", hardBreak: .twoSpaces, autoPair: false, completeTables: false)
        _ = c.makeOutline()
        verify("settings")
        if render {
            let view = EditorView(controller: c, frame: NSRect(x: 0, y: 0, width: 900, height: 700))
            view.caretBlinks = false
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            if let ctx = CGContext(data: nil, width: 900, height: 700, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                view.render(in: ctx, dirty: view.bounds)
                view.focusMode = true
                view.typewriterMode = true
                view.displayOptions = AccessibilityDisplayOptions(increaseContrast: true, reduceMotion: true, reduceTransparency: true)
                view.render(in: ctx, dirty: view.bounds)
                view.toggleSourceMode(nil)
                view.render(in: ctx, dirty: view.bounds)
                view.toggleSourceMode(nil)
                view.focusMode = false
                view.typewriterMode = false
                view.render(in: ctx, dirty: view.bounds)
            }
            _ = view.accessibilityValue()
            verify("drawing")
        }
        return failures
    }

    // MARK: (c) Editing

    /// Runs `steps` random editing commands on `text` and checks each
    /// change against the edits it declared, then undoes and redoes all.
    public static func checkEdits(_ text: String, steps: Int, seed: UInt64) -> (failures: [String], known: [String], tried: Int, applied: Int) {
        let original = Array(text.utf8)
        let c = EditorController(text: text, viewportWidth: 800)
        c.coalescingInterval = -1  // every keystroke its own undo step
        let find = FindSession(controller: c)
        var rng = SplitMix64(seed: seed)
        var model = original
        var snapshots: [[UInt8]] = [original]
        var failures: [String] = []
        var known: [String] = []
        var tried = 0, applied = 0
        var declared: [[Edit]] = []
        c.onEdits = { [unowned c] edits in
            declared.append(edits)
            // The state before each change: with the final state, every
            // state an undo may return to.
            let before = Array(bytes(c))
            if snapshots.last != before { snapshots.append(before) }
        }

        for step in 0..<steps {
            guard failures.count < 5 else { break }
            declared.removeAll()
            if let trace = traceDirectory {
                try? Data(model).write(to: trace.appendingPathComponent("before-step-\(step).md"))
                note("step \(step)")
            }
            // Line breaks written must match the document's as it stands
            // (the editor copies them from nearby lines; a document left
            // with none, or with mixed ones, is not checked).
            let style = lineEnding(of: model)
            let loneCR = model.indices.contains { model[$0] == 0x0D && ($0 + 1 == model.count || model[$0 + 1] != 0x0A) }
            let generation = c.buffer.generation
            let label = "step \(step) " + runCommand(c, find: find, model: model, rng: &rng)
            note(label)
            tried += 1
            let actual = Array(bytes(c))
            // Replay the declared edits on the model.
            var expected: [UInt8]? = model
            for edits in declared {
                guard let before = expected else { break }
                switch apply(edits, to: before, style: style) {
                case .success(let next): expected = next
                case .failure(let problem):
                    if loneCR { known.append("\(label): \(problem.message)") } else { failures.append("\(label): \(problem.message)") }
                    expected = nil
                }
            }
            if let expected, let diff = firstDifference(actual, expected) {
                failures.append("\(label): bytes outside the declared edits changed (first difference at byte \(diff))")
            }
            if c.buffer.generation != generation {
                applied += 1
            } else if actual != model {
                failures.append("\(label): bytes changed without a new generation")
            }
            model = actual
        }

        // Undo every step: each state is one seen before, in order, ending
        // at the original bytes. Then redo back to the final bytes.
        let final = model
        if snapshots.last != final { snapshots.append(final) }
        var index = snapshots.count - 1
        var undos = 0
        while c.canUndo && undos <= steps * 4 {
            c.undo()
            undos += 1
            let now = Array(bytes(c))
            guard let k = snapshots[..<index].lastIndex(of: now) else {
                failures.append("undo \(undos) produced bytes that no earlier step had")
                if let trace = traceDirectory {
                    try? Data(now).write(to: trace.appendingPathComponent("undo-\(undos)-got.md"))
                    try? Data(snapshots[index]).write(to: trace.appendingPathComponent("undo-\(undos)-from.md"))
                }
                break
            }
            index = k
        }
        if let diff = firstDifference(Array(bytes(c)), original) {
            failures.append("undoing every step does not restore the original (first difference at byte \(diff))")
        }
        var redos = 0
        while c.canRedo && redos <= steps * 4 {
            c.redo()
            redos += 1
        }
        if let diff = firstDifference(Array(bytes(c)), final) {
            failures.append("redoing every step does not restore the final bytes (first difference at byte \(diff))")
        }
        return (failures, known, tried, applied)
    }

    // MARK: Commands

    static let typed = ["a", "Z", " ", "1", "ಕ", "್", "ನ", "क", "़", "é", "😀", "👩‍👩‍👧", "🇮🇳", "\t", "#", "-", ">", ".", "\\", "<", "&", "|", "\u{0}"]
    static let openers = ["*", "_", "`", "(", "[", "{", "\"", "$", "~", "'", "\u{201C}"]

    /// Runs one random command and returns its name.
    static func runCommand(_ c: EditorController, find: FindSession, model: [UInt8], rng: inout SplitMix64) -> String {
        let eol = lineEnding(of: model).terminator
        func caret() -> Int { caretPosition(in: model, &rng) }
        func place() {
            let p = caret()
            note("caret \(p)")
            c.moveCaret(to: p)
        }
        func selectRange() {
            let a = caret()
            let lineEnd = lineContentEnd(in: model, from: a)
            var b = min(lineEnd, a + 1 + rng.below(24))
            b = snap(b, in: model)
            if rng.chance(0.5) { c.select(a..<max(a, b)) } else { c.moveCaret(to: a) }
        }
        switch rng.below(19) {
        case 0:
            place()
            let s = rng.pick(typed)
            c.insert(s)
            return "type \(s.debugDescription)"
        case 1:
            place()
            for _ in 0..<(1 + rng.below(6)) { c.insert(rng.pick(typed)) }
            return "type run"
        case 2:
            place()
            let o = rng.pick(openers)
            c.insert(o)
            if rng.chance(0.6) { c.insert("w") }
            if rng.chance(0.5) { c.deleteBackward() } else if rng.chance(0.5) { c.insert([")", "]", "*", "`", "$", "\""][rng.below(6)]) }
            return "auto-pair \(o)"
        case 3:
            if rng.chance(0.3) { selectRange() } else { place() }
            c.deleteBackward()
            return "delete backward"
        case 4:
            place()
            c.deleteForward()
            return "delete forward"
        case 5:
            selectRange()
            switch rng.below(4) {
            case 0: c.toggleStrong(); return "toggle strong"
            case 1: c.toggleEmphasis(); return "toggle emphasis"
            case 2: c.toggleStrikethrough(); return "toggle strikethrough"
            default: c.toggleCodeSpan(); return "toggle code"
            }
        case 6:
            c.moveCaret(to: rng.chance(0.6) ? lineContentEnd(in: model, from: caret()) : caret())
            c.insertNewline()
            if rng.chance(0.3) { c.insertNewline() }
            return "smart enter"
        case 7:
            if rng.chance(0.3) { selectRange() } else { place() }
            switch rng.below(4) {
            case 0: let l = rng.below(7); c.setHeading(level: l); return "heading \(l)"
            case 1: c.promoteHeading(); return "promote heading"
            case 2: c.demoteHeading(); return "demote heading"
            default: c.makeParagraph(); return "paragraph"
            }
        case 8:
            if rng.chance(0.3) { selectRange() } else { place() }
            switch rng.below(7) {
            case 0: c.toggleBulletList(); return "bullet list"
            case 1: c.toggleOrderedList(); return "ordered list"
            case 2: c.toggleTaskList(); return "task list"
            case 3: c.toggleTaskDone(); return "task done"
            case 4: c.indentListItem(); return "indent"
            case 5: c.outdentListItem(); return "outdent"
            default: c.toggleBlockQuote(); return "quote"
            }
        case 9:
            let rows = lines(in: model).filter { r in model[r].contains(0x7C) }
            if let row = rows.isEmpty ? nil : rng.pick(rows) {
                c.moveCaret(to: snap(row.lowerBound + rng.below(max(1, row.count + 1)), in: model))
            } else {
                place()
            }
            switch rng.below(6) {
            case 0, 1: c.insertTab(); return "table tab"
            case 2: c.insertBacktab(); return "table shift-tab"
            case 3: c.insertNewline(); return "table enter"
            case 4: c.insertCellLineBreak(); return "table opt-enter"
            default: c.insert("|"); return "table pipe"
            }
        case 10:
            let words = wordsIn(model)
            guard !words.isEmpty else { return "find (no words)" }
            let word = rng.pick(words)
            find.scope = rng.chance(0.25) ? .rendered : .source
            if rng.chance(0.2) {
                find.query = FindQuery("(\\p{L}+)", isRegex: true)
                return "replace all regex (\(find.replaceAll(with: "$1·")))"
            }
            find.query = FindQuery(word, caseSensitive: rng.chance(0.5), wholeWord: rng.chance(0.5))
            let replacement = rng.pick(["", "Z", "ಕನ್ನಡ", word + word, "*"])
            if rng.chance(0.5) {
                return "replace all \(word.debugDescription) (\(find.replaceAll(with: replacement)))"
            }
            place()
            _ = find.next()
            find.replaceCurrent(with: replacement)
            return "replace \(word.debugDescription)"
        case 11:
            let images = imageOffsets(in: model)
            let at = images.isEmpty ? caret() : rng.pick(images)
            let zoom: Int? = rng.chance(0.2) ? nil : rng.pick(ImageTarget.zoomPresets)
            c.setImageZoom(zoom, at: at)
            return "image zoom \(zoom.map(String.init) ?? "original")"
        case 12:
            let outline = c.makeOutline()
            guard !outline.items.isEmpty else { return "outline (no headings)" }
            let k = rng.below(outline.items.count)
            if rng.chance(0.5) {
                let by = rng.chance(0.5) ? -1 : 1
                c.shiftSection(outline, k, by: by, subsections: rng.chance(0.5))
                return "outline \(by < 0 ? "promote" : "demote") \(k)"
            }
            let target: Int? = rng.chance(0.2) ? nil : rng.below(outline.items.count)
            c.moveSection(outline, k, before: target)
            return "outline move \(k) before \(target.map(String.init) ?? "end")"
        case 13:
            place()
            c.selectEnclosingBlock()
            if rng.chance(0.3) { c.selectEnclosingBlock() }
            switch rng.below(4) {
            case 0: c.duplicateBlock(); return "duplicate block"
            case 1: c.moveBlock(up: true); return "move block up"
            case 2: c.moveBlock(up: false); return "move block down"
            default: c.deleteBackward(); return "delete block"
            }
        case 14:
            if rng.chance(0.3) { selectRange() } else { place() }
            switch rng.below(9) {
            case 0: c.insertCodeFence(); return "code fence"
            case 1: c.insertMathBlock(); return "math block"
            case 2: c.insertThematicBreak(); return "rule"
            case 3: c.insertFootnote(); return "footnote"
            case 4: c.insertLink(destination: "https://example.com/a b"); return "link"
            case 5: c.insertImage(alt: "alt [x]", path: "assets/p q.png"); return "image"
            case 6: c.insertHardBreak(); return "hard break"
            case 7: c.exitBlock(); return "exit block"
            default: c.commitLink(c.linkDraft(pasteboard: "https://example.org")); return "commit link"
            }
        case 15:
            let a = caret(), b = caret()
            let snippet = rng.pick(["pasted", "two" + eol + "lines", eol + "- item" + eol, "| x |" + eol, "ಕನ್ನಡ" + eol + eol + "# h"])
            c.replace(min(a, b)..<max(a, b), with: snippet)
            return "paste"
        case 16:
            place()
            c.setMarkedText("ಕ", selected: NSRange(location: 1, length: 0))
            c.setMarkedText("ಕನ್", selected: NSRange(location: 3, length: 0))
            if rng.chance(0.5) { c.insert("ಕನ್ನಡ") } else { c.unmarkText() }
            return "IME"
        case 17:
            c.toggleSourceMode()
            place()
            c.insert(rng.pick(typed))
            c.insertNewline()
            c.toggleSourceMode()
            return "source-mode typing"
        default:
            place()
            c.insert(rng.pick(typed))
            let before = Array(bytes(c))
            c.undo()
            c.redo()
            return Array(bytes(c)) == before ? "undo + redo" : "undo + redo (mismatch)"
        }
    }

    /// `LIPI_ROUNDTRIP_TRACE=<dir>`: before each step, the bytes go to
    /// `<dir>/before-step-N.md` and the step and caret to stderr, so a crash
    /// inside a command can be replayed.
    static let traceDirectory: URL? = ProcessInfo.processInfo.environment["LIPI_ROUNDTRIP_TRACE"].map { URL(fileURLWithPath: $0) }

    static func note(_ s: String) {
        guard traceDirectory != nil else { return }
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    // MARK: Model

    struct Problem: Error { var message: String }

    /// Applies one change's edits (all in the coordinates before it) to
    /// `bytes`, checking that they are disjoint, in bounds, on scalar
    /// boundaries, do not split a CRLF pair and write the document's line
    /// ending.
    static func apply(_ edits: [Edit], to bytes: [UInt8], style: LineEndingStyle) -> Result<[UInt8], Problem> {
        let sorted = edits.sorted { ($0.range.lowerBound.byte, $0.range.upperBound.byte) < ($1.range.lowerBound.byte, $1.range.upperBound.byte) }
        for k in sorted.indices {
            let r = sorted[k].range.byteRange
            guard r.lowerBound >= 0, r.upperBound <= bytes.count else {
                return .failure(Problem(message: "edit \(r) out of bounds (\(bytes.count) bytes)"))
            }
            if k > 0 {
                let p = sorted[k - 1].range.byteRange
                if r.lowerBound < p.upperBound { return .failure(Problem(message: "edits \(p) and \(r) overlap")) }
                if p.isEmpty, r.isEmpty, p.lowerBound == r.lowerBound {
                    return .failure(Problem(message: "two insertions at \(r.lowerBound): order undefined"))
                }
            }
            for bound in [r.lowerBound, r.upperBound] {
                if bound > 0, bound < bytes.count, bytes[bound] & 0xC0 == 0x80 {
                    return .failure(Problem(message: "edit \(r) splits a UTF-8 scalar at byte \(bound)"))
                }
            }
            if !sorted[k].isNoOp {
                for bound in Set([r.lowerBound, r.upperBound]) where bound > 0 && bound < bytes.count && bytes[bound - 1] == 0x0D && bytes[bound] == 0x0A {
                    return .failure(Problem(message: "edit \(r) splits a CRLF pair at byte \(bound)"))
                }
            }
            if let problem = lineEndingProblem(sorted[k].replacement, style: style) {
                return .failure(Problem(message: "edit \(r) with \(sorted[k].replacement.debugDescription): \(problem)"))
            }
        }
        var out = bytes
        for edit in sorted.reversed() {
            out.replaceSubrange(edit.range.byteRange, with: Array(edit.replacement.utf8))
        }
        return .success(out)
    }

    static func lineEndingProblem(_ s: String, style: LineEndingStyle) -> String? {
        let u = Array(s.utf8)
        for (k, b) in u.enumerated() {
            switch style {
            case .lf where b == 0x0D:
                return "writes CR into an LF document"
            case .crlf where b == 0x0A && (k == 0 || u[k - 1] != 0x0D):
                return "writes a bare LF into a CRLF document"
            case .crlf where b == 0x0D && (k + 1 >= u.count || u[k + 1] != 0x0A):
                return "writes a bare CR into a CRLF document"
            // Not checked for CR-only documents: the editor's lines end at
            // `\n` only, so such a file is one line to its commands and
            // Return writes `\n` (a known limitation, see README).
            default:
                continue
            }
        }
        return nil
    }

    // MARK: Helpers

    static func bytes(_ c: EditorController) -> Data { TextCodec.encode(c.rope, format: TextFormat()) }

    /// First offset where `a` and `b` differ, or nil when equal.
    static func firstDifference(_ a: [UInt8], _ b: [UInt8]) -> Int? {
        let n = min(a.count, b.count)
        var i = 0
        while i < n && a[i] == b[i] { i += 1 }
        return i == n && a.count == b.count ? nil : i
    }

    static func lineEnding(of bytes: [UInt8]) -> LineEndingStyle { LineEndingStyle.detect(in: bytes) }

    static func snap(_ p: Int, in bytes: [UInt8]) -> Int {
        var p = max(0, min(p, bytes.count))
        while p > 0 && p < bytes.count && bytes[p] & 0xC0 == 0x80 { p -= 1 }
        if p > 0 && p < bytes.count && bytes[p - 1] == 0x0D && bytes[p] == 0x0A { p -= 1 }
        return p
    }

    /// A caret position a user could reach: a scalar boundary, never
    /// between CR and LF; a line start or content end a third of the time.
    static func caretPosition(in bytes: [UInt8], _ rng: inout SplitMix64) -> Int {
        guard !bytes.isEmpty else { return 0 }
        let p = snap(rng.below(bytes.count + 1), in: bytes)
        switch rng.below(6) {
        case 0: return lineStart(in: bytes, from: p)
        case 1: return lineContentEnd(in: bytes, from: p)
        default: return p
        }
    }

    static func lineStart(in bytes: [UInt8], from p: Int) -> Int {
        var s = min(p, bytes.count)
        while s > 0 && bytes[s - 1] != 0x0A && bytes[s - 1] != 0x0D { s -= 1 }
        return s
    }

    static func lineContentEnd(in bytes: [UInt8], from p: Int) -> Int {
        var e = min(p, bytes.count)
        while e < bytes.count && bytes[e] != 0x0A && bytes[e] != 0x0D { e += 1 }
        return e
    }

    /// Content ranges of the lines (terminators excluded).
    static func lines(in bytes: [UInt8]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var s = 0
        while s <= bytes.count {
            let e = lineContentEnd(in: bytes, from: s)
            out.append(s..<e)
            if e >= bytes.count { break }
            s = e + (bytes[e] == 0x0D && e + 1 < bytes.count && bytes[e + 1] == 0x0A ? 2 : 1)
        }
        return out
    }

    /// Letter runs of 2–12 bytes, for find queries.
    static func wordsIn(_ bytes: [UInt8]) -> [String] {
        let text = String(decoding: bytes.prefix(64 * 1024), as: UTF8.self)
        var words: [String] = []
        for w in text.split(whereSeparator: { !$0.isLetter }) where (2...12).contains(w.utf8.count) {
            words.append(String(w))
            if words.count >= 200 { break }
        }
        return words
    }

    /// Offsets just inside `![` and `<img` occurrences.
    static func imageOffsets(in bytes: [UInt8]) -> [Int] {
        var out: [Int] = []
        let img = Array("<img".utf8), IMG = Array("<IMG".utf8)
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0x21 && bytes[i + 1] == 0x5B { out.append(i + 2) }
            if i + 4 <= bytes.count, Array(bytes[i..<(i + 4)]) == img || Array(bytes[i..<(i + 4)]) == IMG { out.append(i + 2) }
            i += 1
        }
        return out.map { snap($0, in: bytes) }
    }
}

extension LineEndingStyle {
    /// The terminator commands should write for this style.
    var terminator: String {
        switch self {
        case .crlf: "\r\n"
        case .cr: "\r"
        default: "\n"
        }
    }
}
