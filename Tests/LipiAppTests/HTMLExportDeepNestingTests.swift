import Foundation
@testable import LipiExport
import Testing

/// Export runs off the main thread (512 KB stacks); cmark-gfm's renderer and
/// the syntax rewriter walk the tree iteratively, so any depth exports.
@Suite("HTML export: deep nesting")
struct HTMLExportDeepNestingTests {
    @Test func deepDocumentsExportOnAWorkerStack() {
        let docs = [
            String(repeating: ">", count: 5_000) + " a\n",
            String(repeating: "- ", count: 5_000) + "a\n",
            String(repeating: "*a ", count: 5_000) + "b" + String(repeating: " a*", count: 5_000) + "\n",
            String(repeating: "~~a ", count: 2_000) + "==b== :smile:" + String(repeating: " a~~", count: 2_000) + "\n",
        ]
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var bodies: [String] = []
        let thread = Thread {
            let exporter = HTMLExporter(syntax: HTMLExporter.optionalSyntax, highlighter: nil)
            bodies = docs.map { exporter.body(markdown: $0) }
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        #expect(bodies.count == docs.count)
        #expect(bodies.allSatisfy { !$0.isEmpty })
    }
}
