import AppKit
import LipiEditor

/// Settings → Editing, Counts and Images applied to one window, at open
/// and whenever a pane changes a value.
extension DocumentWindowController {
    func observeSettings() {
        applySettings()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange(_:)), name: AppSettings.didChange, object: nil)
    }

    @objc private func settingsDidChange(_ note: Notification) {
        let key = note.userInfo?["key"] as? String
        // A window's header Wrap/Lines toggles survive unrelated changes.
        applySettings(code: key == nil || key == AppSettings.Key.codeWrap || key == AppSettings.Key.codeLineNumbers)
    }

    /// Pushes the current settings into the editor, the counter and the
    /// document's image store; unchanged values cost nothing. `code` also
    /// resets the code blocks' wrap and line numbers to the defaults.
    public func applySettings(_ settings: AppSettings = AppSettings(), code: Bool = true) {
        let editing = settings.editorSettings
        if controller.settings != editing { controller.settings = editing }
        if code { controller.codeOptions = settings.codeOptions }
        let counting = settings.countOptions
        if counts.options != counting { counts.options = counting }
        // The store reads both at creation; this keeps an existing one current.
        if let assets = (document as? LipiDocument)?.assets {
            assets.naming = settings.imageNaming
            assets.convertHEIC = settings.convertHEIC
        }
    }
}
