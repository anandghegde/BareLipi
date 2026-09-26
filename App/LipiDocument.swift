import AppKit
import LipiCore

/// Minimal NSDocument so the bundle registers as a Markdown editor. The real
/// implementation (AtomicWriter, coordination, external change handling)
/// follows in Phase 1.
final class LipiDocument: NSDocument {
    var buffer = SourceBuffer()

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.center()
        let label = NSTextField(labelWithString: buffer.rope.debugDescription)
        label.alignment = .center
        window.contentView = label
        addWindowController(NSWindowController(window: window))
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(buffer.rope.string.utf8)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        // Concurrent reading is off (canConcurrentlyReadDocuments defaults to
        // false), so NSDocument calls this on the main thread.
        MainActor.assumeIsolated { buffer.reset(to: text) }
    }
}
