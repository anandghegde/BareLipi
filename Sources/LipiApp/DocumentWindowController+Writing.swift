import AppKit
import LipiEditor

/// The §6.12 writing-mode settings (Settings → Editing): focus scope,
/// typewriter line position and scroll ease. App-wide, applied to every
/// open document.
public enum WritingSettings {
    public static let focusScopeKey = "writing.focusScope"
    public static let typewriterFractionKey = "writing.typewriterFraction"
    public static let typewriterEaseKey = "writing.typewriterEase"

    /// Posted after a setting changes; every document window re-applies.
    public static let didChange = Notification.Name("BareLipi.writingSettingsDidChange")

    public static func focusScope(_ defaults: UserDefaults = .standard) -> FocusScopeKind {
        defaults.string(forKey: focusScopeKey).flatMap(FocusScopeKind.init(rawValue:)) ?? .block
    }

    /// 0.3–0.7; 0.5 when unset.
    public static func typewriterFraction(_ defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: typewriterFractionKey) != nil else { return 0.5 }
        let r = EditorView.typewriterRange
        return min(max(CGFloat(defaults.double(forKey: typewriterFractionKey)), r.lowerBound), r.upperBound)
    }

    public static func typewriterEases(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: typewriterEaseKey)
    }

    public static func set(_ value: Any, forKey key: String, _ defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    @MainActor public static func apply(to editor: EditorView, _ defaults: UserDefaults = .standard) {
        editor.focusScopeKind = focusScope(defaults)
        editor.typewriterFraction = typewriterFraction(defaults)
        editor.typewriterEases = typewriterEases(defaults)
    }
}

extension DocumentWindowController {
    /// Applies the current settings now and whenever they change.
    func observeWritingSettings() {
        WritingSettings.apply(to: editor)
        NotificationCenter.default.addObserver(self, selector: #selector(writingSettingsDidChange(_:)),
                                               name: WritingSettings.didChange, object: nil)
    }

    @objc private func writingSettingsDidChange(_ note: Notification) {
        WritingSettings.apply(to: editor)
    }

    @objc public func toggleFocusSentence(_ sender: Any?) {
        let next: FocusScopeKind = WritingSettings.focusScope() == .sentence ? .block : .sentence
        WritingSettings.set(next.rawValue, forKey: WritingSettings.focusScopeKey)
    }

    @objc public func toggleTypewriterEase(_ sender: Any?) {
        WritingSettings.set(!WritingSettings.typewriterEases(), forKey: WritingSettings.typewriterEaseKey)
    }

    func validateWritingItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(toggleFocusSentence(_:)): item.state = WritingSettings.focusScope() == .sentence ? .on : .off
        case #selector(toggleTypewriterEase(_:)): item.state = WritingSettings.typewriterEases() ? .on : .off
        default: return nil
        }
        return true
    }
}
