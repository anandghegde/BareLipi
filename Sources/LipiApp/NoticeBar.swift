import AppKit

/// A non-modal bar docked above the editor (§8.6): external change, deleted
/// on disk, encoding, file errors. One message and a row of buttons; the
/// bar never takes focus from the editor.
@MainActor
public final class NoticeBar: NSView {
    /// What the bar is about; a window shows at most one bar per kind.
    public enum Kind: Int, Sendable, Comparable {
        case externalChange, deleted, fileError, encoding
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Action {
        public var title: String
        public var isEnabled: Bool
        public var handler: @MainActor () -> Void

        public init(_ title: String, isEnabled: Bool = true, handler: @escaping @MainActor () -> Void) {
            self.title = title
            self.isEnabled = isEnabled
            self.handler = handler
        }
    }

    public let kind: Kind
    public let message: String
    private let label: NSTextField
    private var buttons: [NSButton] = []
    private var actions: [Action] = []
    public static let height: CGFloat = 34

    public init(kind: Kind, message: String, actions: [Action]) {
        self.kind = kind
        self.message = message
        label = NSTextField(labelWithString: message)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: NoticeBar.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.blended(withFraction: 0.08, of: .systemYellow)?.cgColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.actions = actions
        for (i, action) in actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(press(_:)))
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.tag = i
            button.isEnabled = action.isEnabled
            button.refusesFirstResponder = true
            buttons.append(button)
        }
        let stack = NSStackView(views: [label] + buttons)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        stack.setCustomSpacing(16, after: label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel(message)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Button titles, in order (tests and accessibility).
    public var actionTitles: [String] { actions.map(\.title) }

    /// Runs the action titled `title`, as a click would.
    public func perform(_ title: String) {
        guard let action = actions.first(where: { $0.title == title }), action.isEnabled else { return }
        action.handler()
    }

    @objc private func press(_ sender: NSButton) {
        guard sender.tag < actions.count else { return }
        actions[sender.tag].handler()
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// The window's content: notice bars stacked at the top, then the find
/// bar when it is open, the editor's scroll view below them.
@MainActor
public final class DocumentContentView: NSView {
    public let scrollView: NSScrollView
    public private(set) var bars: [NoticeBar] = []
    /// A bar docked between the notice bars and the editor (the find bar);
    /// it reports its height through `intrinsicContentSize`.
    public var accessory: NSView? {
        didSet {
            if oldValue !== accessory { oldValue?.removeFromSuperview() }
            if let accessory, accessory.superview !== self { addSubview(accessory) }
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    public init(scrollView: NSScrollView, frame: NSRect) {
        self.scrollView = scrollView
        super.init(frame: frame)
        autoresizesSubviews = false
        addSubview(scrollView)
        needsLayout = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// Shows `bar`, replacing any bar of the same kind.
    public func show(_ bar: NoticeBar) {
        hide(bar.kind)
        bars.append(bar)
        bars.sort { $0.kind < $1.kind }
        addSubview(bar)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    public func hide(_ kind: NoticeBar.Kind) {
        for bar in bars where bar.kind == kind { bar.removeFromSuperview() }
        bars.removeAll { $0.kind == kind }
        needsLayout = true
    }

    public func bar(_ kind: NoticeBar.Kind) -> NoticeBar? { bars.first { $0.kind == kind } }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        for bar in bars {
            bar.frame = NSRect(x: 0, y: y, width: bounds.width, height: NoticeBar.height)
            y += NoticeBar.height
        }
        if let accessory {
            let height = accessory.intrinsicContentSize.height
            accessory.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
        let frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
        if scrollView.frame != frame { scrollView.frame = frame }
    }
}
