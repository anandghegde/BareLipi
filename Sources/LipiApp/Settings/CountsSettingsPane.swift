import AppKit

/// Settings → Counts (§6.18): the reading speed, CJK counting, and whether
/// code and math count.
@MainActor
public final class CountsSettingsPane: SettingsFormPane, NSTextFieldDelegate {
    private(set) var speedField: NSTextField?

    public override func buildRows() {
        let s = settings
        let field = NSTextField(string: String(s.wordsPerMinute))
        field.alignment = .right
        field.formatter = {
            let f = NumberFormatter()
            f.allowsFloats = false
            f.minimum = NSNumber(value: AppSettings.wordsPerMinuteRange.lowerBound)
            f.maximum = NSNumber(value: AppSettings.wordsPerMinuteRange.upperBound)
            return f
        }()
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        field.setAccessibilityLabel("Reading speed in words per minute")
        field.delegate = self
        let t = target { control in s.wordsPerMinute = Int(control.stringValue) ?? 275 }
        field.target = t
        field.action = #selector(ClosureTarget.fire(_:))
        speedField = field
        let speed = NSStackView(views: [field, NSTextField(labelWithString: "words per minute")])
        speed.orientation = .horizontal
        row("Reading time:", speed)
        checkbox("Count Chinese, Japanese and Korean by character", label: "Words:", get: s.cjkByCharacter) { s.cjkByCharacter = $0 }
        checkbox("Include code blocks", get: s.countCode) { s.countCode = $0 }
        checkbox("Include math", get: s.countMath) { s.countMath = $0 }
        note("Front matter is never counted.")
    }

    public func controlTextDidEndEditing(_ note: Notification) {
        guard let field = note.object as? NSTextField, field === speedField else { return }
        settings.wordsPerMinute = Int(field.stringValue) ?? 275
        field.stringValue = String(settings.wordsPerMinute)
    }
}
