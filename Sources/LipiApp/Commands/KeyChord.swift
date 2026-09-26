import AppKit

/// One keyboard shortcut (P0-11): a key in `NSMenuItem.keyEquivalent` form
/// (lowercase letters, `"\r"` for Return, the private-use characters for
/// function and arrow keys) and the Command, Control, Option and Shift
/// modifiers.
///
/// Written in `keymap.json` in the PRD's notation, modifiers first in the
/// order Cmd, Ctrl, Opt, Shift: `"Cmd-Shift-P"`, `"Cmd-Opt--"`, `"F8"`,
/// `"Cmd-Shift-Enter"`. Parsing accepts any order and case, and the
/// aliases Command, Control, Option, Alt, Return.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public var key: String
    public var modifiers: NSEvent.ModifierFlags

    public static let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    public init(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
        self.key = key.count == 1 && key.lowercased() != key.uppercased() ? key.lowercased() : key
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
    }

    public static func == (a: KeyChord, b: KeyChord) -> Bool {
        a.key == b.key && a.modifiers.rawValue == b.modifiers.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }

    // MARK: Names

    private static func scalarString(_ value: Int) -> String { String(Character(UnicodeScalar(UInt16(value))!)) }

    /// Named keys, by their keymap spelling.
    private static let named: [(name: String, key: String, glyph: String)] = {
        var out: [(String, String, String)] = [
            ("Enter", "\r", "↩"), ("Tab", "\t", "⇥"), ("Space", " ", "Space"), ("Esc", "\u{1b}", "⎋"),
            ("Delete", "\u{8}", "⌫"), ("ForwardDelete", scalarString(NSDeleteFunctionKey), "⌦"),
            ("Up", scalarString(NSUpArrowFunctionKey), "↑"), ("Down", scalarString(NSDownArrowFunctionKey), "↓"),
            ("Left", scalarString(NSLeftArrowFunctionKey), "←"), ("Right", scalarString(NSRightArrowFunctionKey), "→"),
            ("Home", scalarString(NSHomeFunctionKey), "↖"), ("End", scalarString(NSEndFunctionKey), "↘"),
            ("PageUp", scalarString(NSPageUpFunctionKey), "⇞"), ("PageDown", scalarString(NSPageDownFunctionKey), "⇟"),
        ]
        for n in 1...20 { out.append(("F\(n)", scalarString(NSF1FunctionKey + n - 1), "F\(n)")) }
        return out
    }()

    private static let aliases: [String: String] = ["return": "Enter", "escape": "Esc", "backspace": "Delete", "del": "ForwardDelete"]

    /// True for F1…F20, which menus match with the Function modifier.
    public var isFunctionKey: Bool {
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return false }
        return scalar.value >= UInt32(NSF1FunctionKey) && scalar.value <= UInt32(NSF20FunctionKey)
    }

    // MARK: Parsing

    /// Parses `"Cmd-Shift-P"`; nil when a modifier or key name is unknown
    /// or the key is missing.
    public init?(parsing text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var key: String
        // A trailing "-" after a separator is the minus key: "Cmd--".
        if s == "-" {
            key = "-"; s = ""
        } else if s.hasSuffix("--") {
            key = "-"; s.removeLast(2)
        } else if let dash = s.lastIndex(of: "-") {
            key = String(s[s.index(after: dash)...]); s = String(s[..<dash])
        } else {
            key = s; s = ""
        }
        var mods: NSEvent.ModifierFlags = []
        for part in s.split(separator: "-", omittingEmptySubsequences: false) where !(s.isEmpty) {
            switch part.lowercased() {
            case "cmd", "command", "⌘": mods.insert(.command)
            case "ctrl", "control", "⌃": mods.insert(.control)
            case "opt", "option", "alt", "⌥": mods.insert(.option)
            case "shift", "⇧": mods.insert(.shift)
            default: return nil
            }
        }
        if key.count > 1 {
            let wanted = Self.aliases[key.lowercased()] ?? key
            guard let hit = Self.named.first(where: { $0.name.lowercased() == wanted.lowercased() }) else { return nil }
            key = hit.key
        } else if key.isEmpty {
            return nil
        }
        self.init(key, mods)
    }

    /// The keymap spelling: `"Cmd-Shift-P"`.
    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Cmd") }
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Opt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(Self.named.first { $0.key == key }?.name ?? key.uppercased())
        return parts.joined(separator: "-")
    }

    /// The menu glyphs: `"⇧⌘P"`.
    public var glyphs: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out + (Self.named.first { $0.key == key }?.glyph ?? key.uppercased())
    }

    // MARK: Events

    /// The chord a key-down event types, as a menu would bind it: letters
    /// by their unshifted key, shifted punctuation (Cmd-Shift-= types "+")
    /// by the character with Shift dropped. Option uses the key's
    /// unmodified character so Opt-letter chords do not become symbols.
    public init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let mods = event.modifierFlags.intersection(Self.relevantModifiers)
        if event.keyCode == 36 || event.keyCode == 76 { self.init("\r", mods); return }
        if event.keyCode == 48 { self.init("\t", mods); return }
        if event.keyCode == 51 { self.init("\u{8}", mods); return }
        if event.keyCode == 53 { self.init("\u{1b}", mods); return }
        let plain = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        guard !plain.isEmpty else { return nil }
        if mods.contains(.shift), plain.lowercased() == plain.uppercased(), plain.unicodeScalars.first.map({ $0.value < 0xF700 }) ?? false,
           let shifted = event.characters(byApplyingModifiers: .shift), !shifted.isEmpty, shifted != plain {
            self.init(shifted, mods.subtracting(.shift))
            return
        }
        self.init(plain, mods)
    }
}
