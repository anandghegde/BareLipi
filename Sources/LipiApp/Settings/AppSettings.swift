import Foundation
import LipiCore
import LipiEditor
import LipiExport
import LipiLayout

/// A typed facade over `UserDefaults` for the Editing, Counts and Images
/// panes. Every setter posts `AppSettings.didChange`, and open windows
/// re-read what they use (`DocumentWindowController.applySettings()`).
public struct AppSettings {
    public static let didChange = Notification.Name("BareLipi.settingsDidChange")

    /// Defaults keys. The image keys predate this facade (`AssetStore`).
    public enum Key {
        public static let autoPair = "editing.autoPair"
        public static let emphasisMarker = "editing.emphasisMarker"
        public static let hardBreak = "editing.hardBreak"
        public static let completeTables = "editing.completeTables"
        public static let codeLineNumbers = "editing.code.lineNumbers"
        public static let codeWrap = "editing.code.wrap"
        public static let wordsPerMinute = "counts.wordsPerMinute"
        public static let cjkByCharacter = "counts.cjkByCharacter"
        public static let countCode = "counts.includeCode"
        public static let countMath = "counts.includeMath"
        public static let imageNaming = "ImageNaming"
        public static let convertHEIC = "ConvertHEICToJPEG"
        public static let exportImages = "export.html.images"
    }

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: defaults, userInfo: ["key": key])
    }

    // MARK: Editing

    public var autoPair: Bool {
        get { bool(Key.autoPair, true) }
        nonmutating set { store(newValue, Key.autoPair) }
    }

    /// `*` (the default) or `_`.
    public var emphasisMarker: Character {
        get { defaults.string(forKey: Key.emphasisMarker) == "_" ? "_" : "*" }
        nonmutating set { store(newValue == "_" ? "_" : "*", Key.emphasisMarker) }
    }

    public var hardBreak: EditorSettings.HardBreak {
        get { defaults.string(forKey: Key.hardBreak) == "twoSpaces" ? .twoSpaces : .backslash }
        nonmutating set { store(newValue == .twoSpaces ? "twoSpaces" : "backslash", Key.hardBreak) }
    }

    public var completeTables: Bool {
        get { bool(Key.completeTables, true) }
        nonmutating set { store(newValue, Key.completeTables) }
    }

    public var codeLineNumbers: Bool {
        get { bool(Key.codeLineNumbers, false) }
        nonmutating set { store(newValue, Key.codeLineNumbers) }
    }

    public var codeWrap: Bool {
        get { bool(Key.codeWrap, true) }
        nonmutating set { store(newValue, Key.codeWrap) }
    }

    public var editorSettings: EditorSettings {
        EditorSettings(emphasisMarker: emphasisMarker, hardBreak: hardBreak, autoPair: autoPair, completeTables: completeTables)
    }

    public var codeOptions: CodeBlockOptions { CodeBlockOptions(lineNumbers: codeLineNumbers, wrap: codeWrap) }

    // MARK: Counts

    public static let wordsPerMinuteRange = 50...1000

    /// The reading speed: 275 by default, clamped to `wordsPerMinuteRange`.
    public var wordsPerMinute: Int {
        get {
            let n = defaults.integer(forKey: Key.wordsPerMinute)
            return n == 0 ? 275 : Self.clampWPM(n)
        }
        nonmutating set { store(Self.clampWPM(newValue), Key.wordsPerMinute) }
    }

    static func clampWPM(_ n: Int) -> Int {
        min(max(n, wordsPerMinuteRange.lowerBound), wordsPerMinuteRange.upperBound)
    }

    public var cjkByCharacter: Bool {
        get { bool(Key.cjkByCharacter, false) }
        nonmutating set { store(newValue, Key.cjkByCharacter) }
    }

    public var countCode: Bool {
        get { bool(Key.countCode, true) }
        nonmutating set { store(newValue, Key.countCode) }
    }

    public var countMath: Bool {
        get { bool(Key.countMath, true) }
        nonmutating set { store(newValue, Key.countMath) }
    }

    public var countOptions: CountOptions {
        CountOptions(includeCode: countCode, includeMath: countMath, cjkByCharacter: cjkByCharacter, wordsPerMinute: wordsPerMinute)
    }

    // MARK: Images

    public var imageNaming: AssetPolicy.Naming {
        get { AssetPolicy.Naming(rawValue: defaults.string(forKey: Key.imageNaming) ?? "") ?? .timestamp }
        nonmutating set { store(newValue.rawValue, Key.imageNaming) }
    }

    /// Convert HEIC to JPEG on paste and drop; on by default.
    public var convertHEIC: Bool {
        get { bool(Key.convertHEIC, true) }
        nonmutating set { store(newValue, Key.convertHEIC) }
    }

    /// What HTML export does with local images.
    public var exportImages: ImageExport.Mode {
        get { defaults.string(forKey: Key.exportImages).flatMap(ImageExport.Mode.init(rawValue:)) ?? .reference }
        nonmutating set { store(newValue.rawValue, Key.exportImages) }
    }
}
