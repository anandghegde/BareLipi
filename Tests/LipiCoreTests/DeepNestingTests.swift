import Foundation
import Testing
@testable import LipiCore

/// cmark-gfm accepts any nesting depth; the value AST caps it so no walk
/// over it can overflow a worker thread's 512 KB stack.
@Suite("Deep nesting")
struct DeepNestingTests {
    static let depth = 5_000

    static let inputs: [(name: String, text: String)] = {
        let n = depth
        return [
            ("quotes", String(repeating: ">", count: n) + " a\n"),
            ("quote lines", (0..<300).map { String(repeating: "> ", count: $0 + 1) + "q\($0)" }.joined(separator: "\n") + "\n"),
            ("bullets", String(repeating: "- ", count: n) + "a\n"),
            ("ordered", String(repeating: "1. ", count: n) + "a\r\n"),
            ("indented items", (0..<400).map { String(repeating: "  ", count: $0) + "- i\($0)" }.joined(separator: "\r") + "\r"),
            ("emphasis", String(repeating: "*a ", count: n) + "b" + String(repeating: " a*", count: n) + "\n"),
            ("strong", String(repeating: "**a ", count: n) + "b" + String(repeating: " a**", count: n) + "\n"),
            ("links", String(repeating: "[", count: n) + "a" + String(repeating: "](u)", count: n) + "\n"),
            ("strikethrough", String(repeating: "~~a ", count: n) + "b" + String(repeating: " a~~", count: n) + "\n"),
            ("mixed", String(repeating: "> - ", count: 2_000) + String(repeating: "*_", count: 2_000) + "x"
                + String(repeating: "_*", count: 2_000) + "\n\n[r]: /u\n"),
            ("definition past cap", String(repeating: ">", count: 100) + " [r]: /u\n" + String(repeating: ">", count: 100) + " [x][r]\n"),
        ]
    }()

    /// Runs `body` on a thread with the stack size of a GCD worker.
    static func onWorkerStack(_ body: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
    }

    static func blockDepth(_ block: Block) -> Int { 1 + (block.children.map(blockDepth).max() ?? 0) }
    static func inlineDepth(_ inlines: [Inline]) -> Int { inlines.map { 1 + inlineDepth($0.children) }.max() ?? 0 }
    static func maxInlineDepth(_ block: Block) -> Int {
        max(inlineDepth(block.inlines), block.children.map(maxInlineDepth).max() ?? 0)
    }

    @Test(arguments: 0..<inputs.count)
    func parsesProjectsAndEditsOnAWorkerStack(_ i: Int) {
        let (name, text) = Self.inputs[i]
        Self.onWorkerStack {
            var buffer = SourceBuffer(text)
            var parser = LipiParser(options: .editor)
            parser.parse(buffer.rope)
            let blocks = parser.index.blocks
            #expect(!blocks.isEmpty, "\(name)")
            #expect(blocks.map(Self.blockDepth).max()! <= 34, "\(name)")
            #expect(blocks.map(Self.maxInlineDepth).max()! <= 33, "\(name)")

            let policy = RevealPolicy(preset: .balanced)
            var projection = Projection(preset: .balanced)
            for caret in [0, text.utf8.count / 2, text.utf8.count] {
                let reveal = policy.revealSet(caret: caret, index: parser.index, rope: buffer.rope)
                projection.update(index: parser.index, rope: buffer.rope, reveal: reveal)
                var checker = ProjectionChecker(buffer.rope.string)
                checker.check(projection)
                #expect(checker.failures.isEmpty, "\(name) caret \(caret): \(checker.failures)")
            }

            // Edit inside the deep part and compare against a fresh parse.
            let at = text.utf8.count / 2
            let delta = buffer.apply(Edit(replacing: at..<at, with: "z"))
            parser.apply(delta, then: buffer.rope)
            var fresh = LipiParser(options: .editor)
            fresh.parse(buffer.rope)
            #expect(parser.index.blocks.count == fresh.index.blocks.count, "\(name)")
            for (a, b) in zip(parser.index.blocks, fresh.index.blocks) {
                #expect(a.isStructurallyEqual(to: b), "\(name)")
            }
            projection.update(index: parser.index, rope: buffer.rope, reveal: .none)
            var checker = ProjectionChecker(buffer.rope.string)
            checker.check(projection)
            #expect(checker.failures.isEmpty, "\(name) after edit: \(checker.failures)")
        }
    }

    @Test func nestingBelowTheCapIsKept() {
        let quotes = String(repeating: ">", count: 30) + " a\n"
        let (_, parser, _) = project(quotes)
        #expect(Self.blockDepth(parser.index.blocks[0]) == 31)

        let emphasis = String(repeating: "*a ", count: 30) + "b" + String(repeating: " a*", count: 30) + "\n"
        let (_, p2, _) = project(emphasis)
        #expect(Self.maxInlineDepth(p2.index.blocks[0]) == 31)
        func textIsExact(_ inlines: [Inline]) -> Bool {
            inlines.allSatisfy { !$0.isApproximate && textIsExact($0.children) }
        }
        #expect(textIsExact(p2.index.blocks[0].inlines))
    }

    @Test func contentPastTheCapShowsAsSource() {
        let text = String(repeating: "> ", count: 40) + "**b**\n" + String(repeating: "> ", count: 40) + "c\n"
        let (projection, _, _) = project(text)
        let shown = projection.blocks.flatMap { $0.block.cells.map(\.text) }.joined(separator: "|")
        // The 33 outer quotes render; the other 7, and the strong emphasis,
        // stay as written, on both lines.
        let rest = String(repeating: "> ", count: 7)
        #expect(shown.contains(rest + "**b**"), "\(shown)")
        #expect(shown.contains(rest + "c"), "\(shown)")
    }
}
