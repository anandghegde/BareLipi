import AppKit
import LipiCore
import LipiEditor

/// The opt-in inline syntaxes of §6.13 (`~sub~`, `^sup^`, `==highlight==`):
/// app-wide settings, off by default, applied to every open document.
public enum OptionalSyntax: String, CaseIterable, Sendable {
    case `subscript` = "syntax.subscript"
    case superscript = "syntax.superscript"
    case highlight = "syntax.highlight"

    /// Posted after a setting changes; every document window re-parses.
    public static let didChange = Notification.Name("BareLipi.optionalSyntaxDidChange")

    public func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: rawValue) }

    public func setEnabled(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: rawValue)
        NotificationCenter.default.post(name: OptionalSyntax.didChange, object: nil)
    }

    @MainActor public static func apply(to controller: EditorController, _ defaults: UserDefaults = .standard) {
        controller.setOptionalSyntax(subscript: OptionalSyntax.subscript.isEnabled(defaults),
                                     superscript: superscript.isEnabled(defaults),
                                     highlight: highlight.isEnabled(defaults))
    }
}

extension DocumentWindowController {
    /// Applies the current settings now and whenever they change.
    func observeOptionalSyntax() {
        OptionalSyntax.apply(to: controller)
        NotificationCenter.default.addObserver(self, selector: #selector(optionalSyntaxDidChange(_:)),
                                               name: OptionalSyntax.didChange, object: nil)
    }

    @objc private func optionalSyntaxDidChange(_ note: Notification) {
        let state = editorState()
        OptionalSyntax.apply(to: controller)
        apply(state)
        editor.needsDisplay = true
    }

    @objc public func toggleSubscriptSyntax(_ sender: Any?) { OptionalSyntax.subscript.setEnabled(!OptionalSyntax.subscript.isEnabled()) }
    @objc public func toggleSuperscriptSyntax(_ sender: Any?) { OptionalSyntax.superscript.setEnabled(!OptionalSyntax.superscript.isEnabled()) }
    @objc public func toggleHighlightSyntax(_ sender: Any?) { OptionalSyntax.highlight.setEnabled(!OptionalSyntax.highlight.isEnabled()) }

    func validateSyntaxItem(_ item: NSMenuItem) -> Bool? {
        let syntax: OptionalSyntax
        switch item.action {
        case #selector(toggleSubscriptSyntax(_:)): syntax = .subscript
        case #selector(toggleSuperscriptSyntax(_:)): syntax = .superscript
        case #selector(toggleHighlightSyntax(_:)): syntax = .highlight
        default: return nil
        }
        item.state = syntax.isEnabled() ? .on : .off
        return true
    }
}
