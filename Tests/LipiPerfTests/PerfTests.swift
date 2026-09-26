import CoreGraphics
import Foundation
import LipiCore
import LipiEditor
import LipiFixtures
import LipiHighlight
import LipiLayout
import XCTest

@MainActor
final class PerfTests: XCTestCase {
    static let frame120: Double = 1.0 / 120 * 1000  // ms
    static let frame60: Double = 1.0 / 60 * 1000

    override class func tearDown() {
        Perf.printTable()
        Perf.writeBaselineIfRecording()
    }

    // MARK: Launch (application process; see `BareLipi --measure`)

    func testPreMainTime() throws {
        throw XCTSkip("pre-main ≤ 40 ms needs the app bundle and dyld timing; run `BareLipi --measure 5` (process start → main)")
    }

    func testLaunchToFirstFrame() throws {
        throw XCTSkip("launch → first frame ≤ 50 ms is measured in-process by `BareLipi --measure 5` (launch.firstFrame signpost)")
    }

    func testBaselineMemory() throws {
        throw XCTSkip("baseline memory ≤ 80 MB is an app-process figure; `BareLipi --measure` prints phys_footprint")
    }

    // MARK: Open → first frame

    private func measureOpen(_ fixture: PerfFixture, key: String, budget: Double, engine: LayoutEngineKind = .lipi) {
        let text = fixture.text()  // generation is not part of "open"
        let before = physFootprint()
        var screen: Screen!
        let open = seconds {
            screen = Screen(text, engine: engine)
            screen.draw(atY: 0)
        }
        let added = Double(physFootprint() - before) / 1_048_576
        Perf.report(key, open * 1000, unit: "ms", budget: budget, note: "\(text.utf8.count / 1024) KB, +\(String(format: "%.1f", added)) MB")
        Perf.report(key + ".memory", added, unit: "MB", budget: nil)
        withExtendedLifetime(screen) {}
    }

    func testOpen50kWordsToFirstFrame() { measureOpen(.lorem50k, key: "open.lorem-50k", budget: 60) }
    func testOpen1MBToFirstFrame() { measureOpen(.words170k, key: "open.words-170k", budget: 80) }
    func testOpenTable10kx10() { measureOpen(.tables10kx10, key: "open.tables-10kx10", budget: 500) }
    func testOpenKannada20k() { measureOpen(.kannada20k, key: "open.kannada-20k", budget: 60) }

    // MARK: Keystroke → draw

    /// 1,000 keystrokes in the middle of the document, each followed by the
    /// draw of the screen holding the caret; p50 ≤ 3 ms, p99 ≤ 6 ms.
    private func measureTyping(_ fixture: PerfFixture, key: String, keystrokes: Int = 1000, engine: LayoutEngineKind = .lipi,
                               p50Budget: Double? = 3, p99Budget: Double? = 6, memoryBudget: Double? = nil) -> [Double] {
        let screen = Screen(fixture.text(), engine: engine)
        screen.draw(atY: 0)
        var caret = screen.controller.rope.floorScalarBoundary(screen.controller.count / 2)
        if fixture == .tables600x6 {
            // Inside a cell on a body row: two bytes after the line start.
            let rope = screen.controller.rope
            var line = rope.line(at: caret)
            while rope.string(in: rope.lineRange(line)).contains("---") { line += 1 }
            caret = rope.lineRange(line).lowerBound + 2
        }
        screen.controller.moveCaret(to: caret)
        screen.drawAroundCaret(screen.controller.caretRect(forSource: caret))
        var rng = SplitMix64(seed: 3)
        var samples: [Double] = []
        let keystrokes = Perf.scaled(keystrokes)
        samples.reserveCapacity(keystrokes)
        // Warm up (glyph caches, layout cache) before the memory reading,
        // and have malloc return freed pages so the footprint is live memory.
        for _ in 0..<50 { _ = screen.keystroke("x") }
        malloc_zone_pressure_relief(nil, 0)
        let before = physFootprint()
        for _ in 0..<keystrokes {
            let word = rng.pick(Words.latin)
            let text = rng.chance(0.15) ? " " : String(word[word.index(word.startIndex, offsetBy: rng.below(word.count))])
            samples.append(screen.keystroke(text) * 1000)
        }
        malloc_zone_pressure_relief(nil, 0)
        let added = Double(physFootprint() - before) / 1_048_576
        let sorted = samples.sorted()
        Perf.report(key + ".p50", percentile(sorted, 0.5), unit: "ms", budget: p50Budget)
        Perf.report(key + ".p99", percentile(sorted, 0.99), unit: "ms", budget: p99Budget, note: String(format: "max %.2f ms", sorted.last ?? 0))
        let cache = screen.controller.layout.cache
        Perf.report(key + ".memory", added, unit: "MB", budget: memoryBudget,
                    note: "added while typing \(keystrokes) keystrokes; layout cache \(cache.count) blocks, \(cache.weight) lines")
        return samples
    }

    func testKeystrokeToDrawLorem50k() { _ = measureTyping(.lorem50k, key: "key.lorem-50k") }
    func testKeystrokeToDrawKannada20k() { _ = measureTyping(.kannada20k, key: "key.kannada-20k") }
    func testKeystrokeToDrawMixedScripts() { _ = measureTyping(.mixedScripts, key: "key.mixed-scripts") }
    /// Typing inside a 300-line fence (P0-05): highlighting runs off the
    /// main thread, so the keystroke keeps the §9.1 budget.
    func testKeystrokeToDrawInCodeFence() { _ = measureTyping(.codeFences, key: "key.code-fences") }

    /// Background highlight of one 300-line fence (parse + query), per
    /// language; no PRD budget, it is off the keystroke path.
    func testHighlightThroughput() {
        let text = PerfFixture.codeFences.text()
        var times: [Double] = []
        for part in text.components(separatedBy: "```").enumerated() where part.offset % 2 == 1 {
            let newline = part.element.firstIndex(of: "\n")!
            let info = String(part.element[..<newline])
            let code = String(part.element[part.element.index(after: newline)...])
            let grammar = GrammarBundle.grammar(forInfo: info)!
            _ = grammar.query  // compiled once per grammar, not per block
            times.append(seconds { _ = HighlightService(capacity: 1).highlight(code: code, grammar: grammar) } * 1000)
        }
        let sorted = times.sorted()
        Perf.report("highlight.fence-300-lines.p50", percentile(sorted, 0.5), unit: "ms", budget: nil,
                    note: String(format: "max %.2f ms over %d fences", sorted.last ?? 0, sorted.count))
    }

    /// Typing at 120 fps: the per-keystroke work must fit an 8.33 ms frame.
    func testTypingFrameBudget() {
        for fixture in [PerfFixture.lorem50k, .kannada20k, .mixedScripts] {
            let samples = measureTyping(fixture, key: "typing.\(fixture.rawValue)", keystrokes: 600, p50Budget: nil, p99Budget: Self.frame120)
            let dropped = samples.filter { $0 > Self.frame120 }.count
            Perf.report("typing.\(fixture.rawValue).dropped", Double(dropped), unit: "frames", budget: 0, note: "of \(samples.count) at 120 Hz")
        }
    }

    // MARK: Scrolling

    /// A full-document scroll in screen-height steps, each step laying out
    /// and drawing a fresh viewport (worst case: nothing cached below).
    private func measureScroll(_ fixture: PerfFixture, key: String, frameBudget: Double, maxSteps: Int = 400) {
        let screen = Screen(fixture.text())
        screen.draw(atY: 0)
        var times: [Double] = []
        var y: CGFloat = 0
        let step = Screen.size.height
        let maxSteps = Perf.scaled(maxSteps)
        while y < screen.controller.contentHeight, times.count < maxSteps {
            times.append(seconds { screen.draw(atY: y) } * 1000)
            y += step
        }
        let sorted = times.sorted()
        Perf.report(key + ".p50", percentile(sorted, 0.5), unit: "ms", budget: nil, note: "\(times.count) screens")
        Perf.report(key + ".p99", percentile(sorted, 0.99), unit: "ms", budget: frameBudget, note: String(format: "max %.2f ms", sorted.last ?? 0))
        // Second pass: everything is laid out, so this is the draw cost alone.
        var warm: [Double] = []
        y = 0
        while y < screen.controller.contentHeight, warm.count < maxSteps {
            warm.append(seconds { screen.draw(atY: y) } * 1000)
            y += step
        }
        let warmSorted = warm.sorted()
        Perf.report(key + ".warm.p99", percentile(warmSorted, 0.99), unit: "ms", budget: frameBudget)
    }

    func testScrollLorem50k() { measureScroll(.lorem50k, key: "scroll.lorem-50k", frameBudget: Self.frame120) }
    func testScrollImages200() { measureScroll(.images200, key: "scroll.images-200", frameBudget: Self.frame120) }

    // MARK: Hybrid mode (large documents)

    func testHybrid3MB() {
        measureOpen(.words500k, key: "open.words-500k", budget: 300)
        _ = measureTyping(.words500k, key: "key.words-500k", keystrokes: 300, p50Budget: Self.frame120, p99Budget: Self.frame120)
        measureScroll(.words500k, key: "scroll.words-500k", frameBudget: Self.frame120, maxSteps: 200)
    }

    func testHybrid10MB() throws {
        if !Perf.isRelease { throw XCTSkip("10 MB fixture runs in release only (swift test -c release)") }
        measureOpen(.tenMB, key: "open.10mb", budget: 1000)
        _ = measureTyping(.tenMB, key: "key.10mb", keystrokes: 300, p50Budget: Self.frame60, p99Budget: Self.frame60)
        measureScroll(.tenMB, key: "scroll.10mb", frameBudget: Self.frame60, maxSteps: 200)
    }

    // MARK: Find (P0-10)

    /// Find over the 10 MB fixture. The PRD budget is 2 s per GB, so 20 ms
    /// here, for the default search (literal, case-insensitive) including
    /// the flat copy of the rope it scans; median of 5 runs, each with a
    /// fresh session so nothing is cached. Regex and replace-all rows are
    /// reported against their baselines only.
    func testFind() throws {
        if !Perf.isRelease { throw XCTSkip("10 MB fixture runs in release only (swift test -c release)") }
        let controller = EditorController(text: PerfFixture.tenMB.text())
        let mb = Double(controller.count) / 1_048_576
        func median(_ runs: Int = 5, _ body: () -> Void) -> Double {
            (0..<runs).map { _ in seconds(body) * 1000 }.sorted()[runs / 2]
        }
        var count = 0
        let literal = median {
            let session = FindSession(controller: controller)
            session.query = FindQuery("dolor")
            count = session.count
        }
        XCTAssertGreaterThan(count, 1000)
        Perf.report("find.10mb", literal, unit: "ms", budget: 20,
                    note: "\"dolor\", \(count) matches, \(String(format: "%.1f", mb)) MB")
        var misses = -1
        let miss = median {
            let session = FindSession(controller: controller)
            session.query = FindQuery("zqxj", caseSensitive: true)
            misses = session.count
        }
        XCTAssertEqual(misses, 0)
        Perf.report("find.10mb.no-match", miss, unit: "ms", budget: 20, note: "case-sensitive, 0 matches")
        var words = 0
        let regex = median(3) {
            let session = FindSession(controller: controller)
            session.query = FindQuery(#"\bdol\w+"#, isRegex: true)
            words = session.count
        }
        Perf.report("find.10mb.regex", regex, unit: "ms", budget: nil, note: "\\bdol\\w+, \(words) matches")
        let session = FindSession(controller: controller)
        session.query = FindQuery("dolor", caseSensitive: true)
        var replaced = 0
        let replaceAll = seconds { replaced = session.replaceAll(with: "DOLOR") } * 1000
        XCTAssertGreaterThan(replaced, 1000)
        Perf.report("find.10mb.replace-all", replaceAll, unit: "ms", budget: nil, note: "\(replaced) edits, one undo step")
    }

    // MARK: Reveal / fold compensation

    /// Walks the reveal matrix with up to 100 caret positions per block and
    /// checks the caret's screen y after the view applies the controller's
    /// compensation: |actual − shift − expected| ≤ 0.5 pt, where `expected`
    /// is the caret's y under the pre-reveal layout.
    func testRevealCaretDrift() {
        let screen = Screen(PerfFixture.revealMatrix.text())
        screen.draw(atY: 0)
        let c = screen.controller
        let rope = c.rope
        var positions: [Int] = []
        var kinds = Set<BlockRole>()
        // Sample every line: up to 100 evenly spaced scalar boundaries.
        var offset = 0
        while offset < c.count {
            let line = rope.line(at: offset)
            let range = rope.lineRange(line)
            let length = max(1, range.count)
            let step = max(1, length / 100)
            var o = range.lowerBound
            while o < range.upperBound {
                positions.append(rope.floorScalarBoundary(o))
                o += step
            }
            offset = range.upperBound
        }
        positions = Array(Set(positions)).sorted()
        var worst: (drift: CGFloat, at: Int) = (0, 0)
        var uncompensated: CGFloat = 0
        var shifted = 0
        var samples = 0
        func probe(_ target: Int) {
            let expected = c.caretRect(forSource: target)
            let change = c.moveCaret(to: target)
            let residual = abs((change.caretRect.minY - change.viewportShift) - expected.minY)
            if change.viewportShift != 0 { shifted += 1 }
            uncompensated = max(uncompensated, abs(change.caretRect.minY - expected.minY))
            if residual > worst.drift { worst = (residual, target) }
            samples += 1
            if let block = c.displayBlock(atSource: target) { kinds.insert(block.role) }
        }
        // Sequential walk (arrow keys), then random jumps (mouse clicks).
        for p in positions { probe(p) }
        var rng = SplitMix64(seed: 9)
        for _ in 0..<min(positions.count, 2000) { probe(rng.pick(positions)) }
        Perf.report("reveal.caret-drift", worst.drift, unit: "pt", budget: 0.5,
                    note: "\(samples) caret moves, \(shifted) compensated, \(kinds.count) block kinds, worst at byte \(worst.at)")
        Perf.report("reveal.caret-drift.uncompensated", uncompensated, unit: "pt", budget: nil, note: "largest line move a reveal/fold caused")
        XCTAssertLessThanOrEqual(worst.drift, 0.5, "caret y drifted \(worst.drift) pt at byte \(worst.at)")
    }

    // MARK: Tables

    func testTable600x6Typing() {
        _ = measureTyping(.tables600x6, key: "key.tables-600x6", keystrokes: 600, p50Budget: Self.frame120, p99Budget: Self.frame120, memoryBudget: 20)
    }

    // MARK: Not in Phase 0

    func testKeystrokeToPhoton() throws { throw XCTSkip("keystroke → photon needs Typometer on a real display") }
    func testMathRendering() throws { throw XCTSkip("math ≤ 1 ms/formula: renderer is Phase 2") }
    func testDiagramRendering() throws { throw XCTSkip("diagram ≤ 300 ms: Mermaid island is Phase 2") }
    func testPDFExport() throws { throw XCTSkip("PDF export ≤ 5 s: Phase 2") }
    func testIdleCPU() throws { throw XCTSkip("idle CPU: app-process figure, Phase 1") }
    func testBundleSize() throws { throw XCTSkip("bundle size: needs the app bundle, Phase 1") }
}
