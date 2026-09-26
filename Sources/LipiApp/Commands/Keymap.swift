import AppKit

/// The user's key bindings (P0-11, PRD §6.11): a preset plus per-command
/// overrides, stored as `~/Library/Application Support/BareLipi/keymap.json`
/// (Appendix A.3):
///
/// ```json
/// {
///   "preset": "BareLipi",
///   "bindings": {
///     "format.bold": "Cmd-Shift-B",
///     "view.zoomIn": ["Cmd-=", "Cmd-+"],
///     "file.quickOpen": null
///   }
/// }
/// ```
///
/// A binding is one chord, a list (the first is shown in menus, the rest
/// are hidden alternates), or `null` / `""` / `[]` to unbind. Bindings are
/// resolved as the registry's defaults, then the preset's differences,
/// then the overrides. Presets are code, not files: BareLipi (the default)
/// and Typora (Appendix B, "Typora preset differences").
public struct Keymap: Equatable, Sendable {
    public static let defaultPreset = "BareLipi"

    public var preset: String
    /// Command id → chords; an empty list unbinds the command.
    public var overrides: [String: [KeyChord]]

    public init(preset: String = Keymap.defaultPreset, overrides: [String: [KeyChord]] = [:]) {
        self.preset = preset
        self.overrides = overrides
    }

    // MARK: Presets

    /// Each preset's differences from the registry's defaults (which are
    /// the BareLipi preset, Appendix B).
    public static let presets: [String: [String: [KeyChord]]] = [
        "BareLipi": [:],
        // Appendix B: Quick Open moves to Cmd-Shift-O so Cmd-P is free for
        // Print (Print itself arrives with PDF export, P0-14 Phase 2),
        // Cmd-Ctrl-1 is the outline, Cmd-Shift-` the code span, Cmd-= and
        // Cmd-- promote and demote, Cmd-Shift-= and Cmd-Shift-- zoom.
        "Typora": [
            "file.quickOpen": [KeyChord("o", [.command, .shift])],
            "view.outline": [KeyChord("1", [.command, .control])],
            "format.code": [KeyChord("~", [.command])],
            "format.promoteHeading": [KeyChord("=", [.command])],
            "format.demoteHeading": [KeyChord("-", [.command])],
            "view.zoomIn": [KeyChord("+", [.command])],
            "view.zoomOut": [KeyChord("_", [.command])],
        ],
    ]

    public static var presetNames: [String] { presets.keys.sorted { $0 == defaultPreset ? true : $1 == defaultPreset ? false : $0 < $1 } }

    // MARK: Resolution

    /// Defaults, then the preset, then the overrides.
    public func resolve(defaults: [String: [KeyChord]]) -> [String: [KeyChord]] {
        var out = defaults
        for (id, keys) in Keymap.presets[preset] ?? [:] where out[id] != nil { out[id] = keys }
        for (id, keys) in overrides where out[id] != nil { out[id] = keys }
        return out
    }

    /// The command's chords under the preset alone.
    public func presetKeys(for id: String, defaults: [String: [KeyChord]]) -> [KeyChord] {
        Keymap.presets[preset]?[id] ?? defaults[id] ?? []
    }

    /// This keymap with `id` bound to `keys`; binding a command to its
    /// preset's chords drops the override instead of storing a copy.
    public func binding(_ id: String, to keys: [KeyChord], defaults: [String: [KeyChord]]) -> Keymap {
        var out = self
        out.overrides[id] = keys == presetKeys(for: id, defaults: defaults) ? nil : keys
        return out
    }

    /// Chords bound to more than one command, ignoring the pairs in
    /// `shares` (commands that share a key on purpose, told apart by
    /// validation: Cmd-0 is Paragraph in the editor and Actual Size
    /// elsewhere, Appendix B).
    public static func conflicts(in bindings: [String: [KeyChord]], shares: [Set<String>] = []) -> [KeymapConflict] {
        var byChord: [KeyChord: [String]] = [:]
        for (id, keys) in bindings {
            for key in Set(keys.map(\.canonical)) { byChord[key, default: []].append(id) }
        }
        var out: [KeymapConflict] = []
        for (chord, ids) in byChord where ids.count > 1 {
            let set = Set(ids)
            if shares.contains(where: { set.isSubset(of: $0) }) { continue }
            out.append(KeymapConflict(chord: chord, ids: ids.sorted()))
        }
        return out.sorted { $0.chord.description < $1.chord.description }
    }

    // MARK: JSON

    /// Parses keymap.json. Invalid JSON gives the default keymap and one
    /// issue; bad entries are skipped and reported, the rest apply.
    public static func parse(_ data: Data) -> (Keymap, [KeymapIssue]) {
        guard !data.isEmpty else { return (Keymap(), []) }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return (Keymap(), [.invalidJSON((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription)])
        }
        guard let root = object as? [String: Any] else { return (Keymap(), [.invalidJSON("the top level is not an object")]) }
        var issues: [KeymapIssue] = []
        var keymap = Keymap()
        if let preset = root["preset"] {
            if let name = preset as? String, let match = presets.keys.first(where: { $0.lowercased() == name.lowercased() }) {
                keymap.preset = match
            } else {
                issues.append(.unknownPreset("\(preset)"))
            }
        }
        if let bindings = root["bindings"] {
            guard let dict = bindings as? [String: Any] else {
                return (keymap, issues + [.invalidJSON("\"bindings\" is not an object")])
            }
            for (id, value) in dict.sorted(by: { $0.key < $1.key }) {
                let texts: [Any]
                switch value {
                case is NSNull: texts = []
                case let s as String: texts = s.isEmpty ? [] : [s]
                case let a as [Any]: texts = a
                default: issues.append(.badChord(command: id, text: "\(value)")); continue
                }
                var chords: [KeyChord] = []
                var ok = true
                for text in texts {
                    guard let s = text as? String, let chord = KeyChord(parsing: s) else {
                        issues.append(.badChord(command: id, text: "\(text)"))
                        ok = false
                        break
                    }
                    if !chords.contains(chord) { chords.append(chord) }
                }
                if ok { keymap.overrides[id] = chords }
            }
        }
        return (keymap, issues)
    }

    /// keymap.json for this keymap: the preset and the overrides, sorted.
    public func encoded() -> Data {
        var out = "{\n  \"preset\": \(Self.quote(preset)),\n  \"bindings\": {"
        let ids = overrides.keys.sorted()
        for (n, id) in ids.enumerated() {
            let keys = overrides[id] ?? []
            let value: String
            switch keys.count {
            case 0: value = "null"
            case 1: value = Self.quote(keys[0].description)
            default: value = "[" + keys.map { Self.quote($0.description) }.joined(separator: ", ") + "]"
            }
            out += "\n    \(Self.quote(id)): \(value)" + (n < ids.count - 1 ? "," : "")
        }
        out += ids.isEmpty ? "}\n}\n" : "\n  }\n}\n"
        return Data(out.utf8)
    }

    private static func quote(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(s)\""
    }
}

/// A problem found in keymap.json.
public enum KeymapIssue: Equatable, Sendable, CustomStringConvertible {
    case invalidJSON(String)
    case unknownPreset(String)
    case unknownCommand(String)
    case badChord(command: String, text: String)

    public var description: String {
        switch self {
        case .invalidJSON(let why): return "keymap.json is not valid JSON (\(why)); using the default bindings."
        case .unknownPreset(let name): return "Unknown preset “\(name)”; using \(Keymap.defaultPreset)."
        case .unknownCommand(let id): return "Unknown command “\(id)”."
        case .badChord(let id, let text): return "“\(text)” for \(id) is not a shortcut (write it like \"Cmd-Shift-P\")."
        }
    }
}

/// One chord bound to several commands.
public struct KeymapConflict: Equatable, Sendable {
    public var chord: KeyChord
    public var ids: [String]
}

extension KeyChord {
    /// US-layout shifted punctuation, as typed with Shift and as menus bind it.
    static let usShifted: [String: String] = [
        "=": "+", "-": "_", "[": "{", "]": "}", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "\\": "|", "`": "~",
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
    ]

    /// The chord with Shift folded into the key for punctuation, so that
    /// Cmd-Shift-= and Cmd-+ compare equal (they are the same keystroke on
    /// a US layout).
    public var canonical: KeyChord {
        guard modifiers.contains(.shift), let shifted = Self.usShifted[key] else { return self }
        return KeyChord(shifted, modifiers.subtracting(.shift))
    }
}
