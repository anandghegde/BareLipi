import AppKit
import LipiCore
import LipiEditor

/// The window's root view: an optional sidebar on the left, the document
/// content (notice bars, find bar, editor) and the status bar below it.
@MainActor
public final class DocumentChromeView: NSView {
    public let content: NSView
    public let statusBar: StatusBar
    /// Shown at the left edge when set (the outline, §6.8).
    public var sidebar: NSView? {
        didSet {
            if oldValue !== sidebar { oldValue?.removeFromSuperview() }
            if let sidebar, sidebar.superview !== self { addSubview(sidebar) }
            needsLayout = true
        }
    }
    public var sidebarWidth: CGFloat = 240 { didSet { needsLayout = true } }
    public var isStatusBarHidden = false {
        didSet {
            statusBar.isHidden = isStatusBarHidden
            needsLayout = true
        }
    }

    public init(content: NSView, frame: NSRect) {
        self.content = content
        statusBar = StatusBar(frame: NSRect(x: 0, y: 0, width: frame.width, height: StatusBar.height))
        super.init(frame: frame)
        autoresizesSubviews = false
        addSubview(content)
        addSubview(statusBar)
        needsLayout = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        let barHeight = isStatusBarHidden ? 0 : StatusBar.height
        var x: CGFloat = 0
        if let sidebar, !sidebar.isHidden {
            let w = min(sidebarWidth, bounds.width / 2)
            sidebar.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
            x = w
        }
        let height = max(0, bounds.height - barHeight)
        let contentFrame = NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: height)
        if content.frame != contentFrame { content.frame = contentFrame }
        statusBar.frame = NSRect(x: x, y: height, width: max(0, bounds.width - x), height: barHeight)
    }
}

/// The status bar (§6.18): words, characters with and without spaces and
/// reading time, for the document or for the selection when there is one.
@MainActor
public final class StatusBar: NSView {
    public static let height: CGFloat = 22
    private let label = NSTextField(labelWithString: "")

    public override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.lineBreakMode = .byTruncatingHead
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The text shown (tests).
    public var text: String { label.stringValue }

    public func show(document: TextCounts, selection: TextCounts?, wordsPerMinute: Int) {
        let text = StatusBar.format(document: document, selection: selection, wordsPerMinute: wordsPerMinute)
        guard text != label.stringValue else { return }
        label.stringValue = text
        setAccessibilityValue(text)
    }

    /// "1,234 words · 6,789 characters (5,601 without spaces) · 5 min read";
    /// with a selection, "12 of 1,234 words · …" over the selection.
    /// Made once: a `NumberFormatter` costs ~0.1 ms, and the first one in
    /// the process several ms (ICU); formatting is thread-safe.
    private nonisolated(unsafe) static let decimal: NumberFormatter = {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        return n
    }()

    public nonisolated static func format(document: TextCounts, selection: TextCounts?, wordsPerMinute: Int) -> String {
        func f(_ v: Int) -> String { decimal.string(from: NSNumber(value: v)) ?? String(v) }
        func plural(_ v: Int, _ word: String) -> String { v == 1 ? word : word + "s" }
        let shown = selection ?? document
        var words = f(shown.words)
        if selection != nil { words += " of " + f(document.words) }
        words += " " + plural(selection == nil ? shown.words : document.words, "word")
        let characters = "\(f(shown.characters)) \(plural(shown.characters, "character")) (\(f(shown.charactersExcludingSpaces)) without spaces)"
        let minutes = shown.readingMinutes(wordsPerMinute: wordsPerMinute)
        let reading = shown.words == 0 ? "0 min read" : minutes <= 1 ? "1 min read" : "\(f(minutes)) min read"
        return [words, characters, reading].joined(separator: "  ·  ")
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    public override var isFlipped: Bool { false }
}

/// Keeps a window's status bar current: recounts after edits and selection
/// changes, at most once per run-loop turn, from a per-block cache.
@MainActor
final class CountsModel {
    private weak var controller: EditorController?
    private weak var bar: StatusBar?
    private var counter = DocumentCounter()
    private var documentCounts = TextCounts.zero
    private var textDirty = true
    private var scheduled = false
    private var warming = false
    private var warmed = false

    init(controller: EditorController, bar: StatusBar) {
        self.controller = controller
        self.bar = bar
    }

    var options: CountOptions {
        get { counter.options }
        set {
            counter.options = newValue
            setNeedsUpdate(textChanged: true)
        }
    }

    func setNeedsUpdate(textChanged: Bool) {
        if textChanged { textDirty = true }
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.update() }
    }

    func update() {
        scheduled = false
        guard let controller, let bar, !bar.isHidden else { return }
        if textDirty, !warmed, counter.cachedBlocks == 0, controller.count > 256 * 1024 {
            // A cold count of a large document (tens of ms) runs off the
            // main thread; it only fills the per-block cache.
            guard !warming else { return }
            warming = true
            let cold = counter, index = controller.blockIndex, rope = controller.rope
            Task.detached(priority: .userInitiated) {
                var warm = cold
                _ = warm.document(index: index, rope: rope)
                await MainActor.run { [weak self, warm] in
                    guard let self else { return }
                    self.warming = false
                    self.warmed = true
                    if self.counter.cachedBlocks == 0, self.counter.options == warm.options { self.counter = warm }
                    self.update()
                }
            }
            return
        }
        if textDirty {
            documentCounts = counter.document(index: controller.blockIndex, rope: controller.rope)
            textDirty = false
        }
        let range = controller.selection.range
        let selection = range.isEmpty ? nil : counter.selection(range, index: controller.blockIndex, rope: controller.rope)
        bar.show(document: documentCounts, selection: selection, wordsPerMinute: counter.options.wordsPerMinute)
    }
}
