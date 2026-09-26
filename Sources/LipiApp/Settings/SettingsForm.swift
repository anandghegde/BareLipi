import AppKit

/// Shared scaffolding for the simple form panes (Editing, Counts, Images):
/// a two-column `NSGridView` of trailing-aligned labels and controls whose
/// actions are closures. AppKit, as `SettingsWindowController` explains.
@MainActor
open class SettingsFormPane: NSViewController {
    let settings: AppSettings
    private var rows: [(String, NSView)] = []
    private var actions: [ClosureTarget] = []

    public init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Subclasses add their rows here.
    open func buildRows() {}

    public override func loadView() {
        buildRows()
        let grid = NSGridView(views: rows.map { label, control in
            [label.isEmpty ? NSGridCell.emptyContentView : NSTextField(labelWithString: label), control]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        view = container
    }

    // MARK: Row builders

    /// A row; an empty label leaves the label column blank.
    func row(_ label: String, _ control: NSView) { rows.append((label, control)) }

    func target(_ action: @escaping (NSControl) -> Void) -> ClosureTarget {
        let t = ClosureTarget(action)
        actions.append(t)
        return t
    }

    /// A checkbox bound to a Bool.
    @discardableResult
    func checkbox(_ title: String, label: String = "", get: Bool, set: @escaping (Bool) -> Void) -> NSButton {
        let t = target { set(($0 as? NSButton)?.state == .on) }
        let box = NSButton(checkboxWithTitle: title, target: t, action: #selector(ClosureTarget.fire(_:)))
        box.state = get ? .on : .off
        row(label, box)
        return box
    }

    /// A pop-up of `choices` (title, value).
    @discardableResult
    func popup<V: Equatable>(_ label: String, _ choices: [(String, V)], get: V, set: @escaping (V) -> Void) -> NSPopUpButton {
        let t = target { control in
            guard let popup = control as? NSPopUpButton, popup.indexOfSelectedItem >= 0 else { return }
            set(choices[popup.indexOfSelectedItem].1)
        }
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: choices.map(\.0))
        popup.selectItem(at: choices.firstIndex { $0.1 == get } ?? 0)
        popup.target = t
        popup.action = #selector(ClosureTarget.fire(_:))
        popup.setAccessibilityLabel(label.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
        row(label, popup)
        return popup
    }

    /// A small explanatory line under the previous row.
    func note(_ text: String) {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 340
        row("", field)
    }
}

/// Target for a control's action.
@MainActor
final class ClosureTarget: NSObject {
    let action: (NSControl) -> Void
    init(_ action: @escaping (NSControl) -> Void) { self.action = action }
    @objc func fire(_ sender: NSControl) { action(sender) }
}
