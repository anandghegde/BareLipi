import CoreText
import Foundation
import NaturalLanguage

// MARK: - Scripts

/// Writing systems the cascade distinguishes (PRD §8.3 table). Scripts that
/// share a row (Telugu, Malayalam, …) are separate cases so a theme can
/// override one of them.
public enum Script: Sendable, Hashable, CaseIterable {
    case latin          // Latin, Cyrillic, Greek and everything unlisted
    case kannada
    case devanagari
    case tamil
    case telugu
    case malayalam
    case bengali
    case gujarati
    case gurmukhi
    case han
    case hiragana
    case katakana
    case hangul
    case arabic
    case hebrew
    case emoji

    public var isRightToLeft: Bool { self == .arabic || self == .hebrew }

    /// Classifies one scalar. `nil` means "common": spaces, punctuation,
    /// digits, combining marks and format characters join the surrounding run.
    public static func of(_ scalar: Unicode.Scalar) -> Script? {
        let v = scalar.value
        switch v {
        case 0x0000...0x0040, 0x005B...0x0060, 0x007B...0x00BF, 0x2000...0x206F, 0x0300...0x036F,
             0x20D0...0x20FF, 0xFE00...0xFE0F, 0x200B...0x200F, 0xFF00...0xFF0F:
            return nil
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF, 0x0370...0x03FF, 0x0400...0x052F:
            return .latin
        case 0x0590...0x05FF, 0xFB1D...0xFB4F:
            return .hebrew
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return .arabic
        case 0x0900...0x097F, 0xA8E0...0xA8FF, 0x1CD0...0x1CFF:
            return .devanagari
        case 0x0980...0x09FF:
            return .bengali
        case 0x0A00...0x0A7F:
            return .gurmukhi
        case 0x0A80...0x0AFF:
            return .gujarati
        case 0x0B80...0x0BFF:
            return .tamil
        case 0x0C00...0x0C7F:
            return .telugu
        case 0x0C80...0x0CFF:
            return .kannada
        case 0x0D00...0x0D7F:
            return .malayalam
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF:
            return .hangul
        case 0x3040...0x309F:
            return .hiragana
        case 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:
            return .katakana
        case 0x2E80...0x2FDF, 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2FA1F, 0x30000...0x3134F, 0xFF10...0xFF65:
            return .han
        case 0x1F000...0x1FAFF, 0x2600...0x27BF, 0x2B00...0x2BFF, 0x1F1E6...0x1F1FF, 0x231A...0x23FF, 0x2190...0x21FF:
            return .emoji
        default:
            return .latin
        }
    }
}

/// A maximal run of one script, in UTF-16 units of the string it was made from.
public struct ScriptRun: Sendable, Hashable {
    public var range: Range<Int>
    public var script: Script

    public init(range: Range<Int>, script: Script) {
        self.range = range
        self.script = script
    }
}

/// Splits `string` into script runs. Common characters join the run in
/// progress (or the first explicit run when they open the string), so a
/// Kannada word with Latin digits and spaces is one Kannada run.
public func scriptRuns(of string: String) -> [ScriptRun] {
    var runs: [ScriptRun] = []
    var current: Script? = nil
    var runStart = 0
    var offset = 0
    var pendingCommonStart: Int? = nil
    for scalar in string.unicodeScalars {
        let width = scalar.utf16.count
        if let s = Script.of(scalar) {
            if current == nil {
                current = s
                runStart = pendingCommonStart ?? offset
            } else if s != current {
                runs.append(ScriptRun(range: runStart..<offset, script: current!))
                current = s
                runStart = offset
            }
        } else if current == nil, pendingCommonStart == nil {
            pendingCommonStart = offset
        }
        offset += width
    }
    if let c = current {
        runs.append(ScriptRun(range: runStart..<offset, script: c))
    } else if offset > 0 {
        runs.append(ScriptRun(range: 0..<offset, script: .latin))
    }
    return runs
}

// MARK: - Cascade table

public enum LineHeightClass: Sendable, Hashable {
    case standard
    case tall
}

public struct CascadeEntry: Sendable, Hashable {
    /// Families tried in order for the light and dark variants; the first
    /// installed one leads the cascade list and the rest follow.
    public var light: [String]
    public var dark: [String]
    /// Applied to the font size, not the line height (§8.3).
    public var sizeFactor: CGFloat
    public var lineHeight: LineHeightClass

    public init(light: [String], dark: [String]? = nil, sizeFactor: CGFloat = 1, lineHeight: LineHeightClass = .standard) {
        self.light = light
        self.dark = dark ?? light
        self.sizeFactor = sizeFactor
        self.lineHeight = lineHeight
    }

    public func families(dark isDark: Bool) -> [String] { isDark ? dark : light }
}

extension Script {
    /// The §8.3 table. `.latin` has no entry: it uses the theme font as is.
    public static let cascadeTable: [Script: CascadeEntry] = [
        .kannada: CascadeEntry(light: ["Noto Serif Kannada", "Kannada MN", "Kannada Sangam MN"],
                               dark: ["Noto Sans Kannada", "Kannada Sangam MN", "Kannada MN"], sizeFactor: 1.08, lineHeight: .tall),
        .devanagari: CascadeEntry(light: ["Kohinoor Devanagari", "Devanagari Sangam MN"], sizeFactor: 1.05, lineHeight: .tall),
        .tamil: CascadeEntry(light: ["Tamil Sangam MN", "Tamil MN"], sizeFactor: 1.06, lineHeight: .tall),
        .telugu: CascadeEntry(light: ["Kohinoor Telugu", "Telugu Sangam MN"], sizeFactor: 1.05, lineHeight: .tall),
        .malayalam: CascadeEntry(light: ["Kohinoor Malayalam", "Malayalam Sangam MN"], sizeFactor: 1.05, lineHeight: .tall),
        .bengali: CascadeEntry(light: ["Kohinoor Bangla", "Bangla Sangam MN"], sizeFactor: 1.05, lineHeight: .tall),
        .gujarati: CascadeEntry(light: ["Kohinoor Gujarati", "Gujarati Sangam MN"], sizeFactor: 1.05, lineHeight: .tall),
        .gurmukhi: CascadeEntry(light: ["Kohinoor Gurmukhi", "Gurmukhi Sangam MN"], sizeFactor: 1.05, lineHeight: .tall),
        .han: CascadeEntry(light: ["PingFang SC", "Hiragino Sans"]),
        .hiragana: CascadeEntry(light: ["Hiragino Sans", "Hiragino Mincho ProN"]),
        .katakana: CascadeEntry(light: ["Hiragino Sans", "Hiragino Mincho ProN"]),
        .hangul: CascadeEntry(light: ["Apple SD Gothic Neo"]),
        .arabic: CascadeEntry(light: ["Geeza Pro"]),
        .hebrew: CascadeEntry(light: ["Arial Hebrew"]),
        .emoji: CascadeEntry(light: ["Apple Color Emoji"]),
    ]

    public var lineHeightClass: LineHeightClass { Script.cascadeTable[self]?.lineHeight ?? .standard }
}

/// Han runs take their font from the language tag (§8.3): `ja` → Hiragino,
/// `zh-Hant`/`zh-HK` → PingFang TC/HK, else PingFang SC.
func hanFamilies(language: String?) -> [String] {
    guard let language = language?.lowercased() else { return ["PingFang SC", "Hiragino Sans"] }
    if language.hasPrefix("ja") { return ["Hiragino Sans", "Hiragino Mincho ProN"] }
    if language.hasPrefix("ko") { return ["Apple SD Gothic Neo"] }
    if language.contains("hant") || language.hasSuffix("-tw") { return ["PingFang TC", "Hiragino Sans"] }
    if language.hasSuffix("-hk") { return ["PingFang HK", "Hiragino Sans"] }
    return ["PingFang SC", "Hiragino Sans"]
}

// MARK: - Font server

/// Serialises every call that may ask the font server (fontd) over XPC:
/// listing families, matching descriptors, creating fonts.
///
/// Core Text resolves those with a synchronous XPC round trip. When more
/// workqueue threads than the machine has cores wait in that call at once,
/// the replies never land and the process deadlocks; swift-testing's parallel
/// runner does exactly that with the layout suites (README, "Layout spike").
/// One caller in flight at a time never hangs, and every result is cached by
/// its caller, so the lock is only contended while the caches warm.
enum FontServer {
    private static let lock = NSLock()

    static func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

// MARK: - Installed fonts

/// Which families are installed, resolved once per process.
public enum InstalledFonts {
    nonisolated(unsafe) private static let families: Set<String> = FontServer.sync {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return Set(names.map { $0.lowercased() })
    }

    public static func isInstalled(_ family: String) -> Bool {
        families.contains(family.lowercased())
    }

    /// The first installed family of `candidates`.
    public static func first(of candidates: [String]) -> String? {
        candidates.first(where: isInstalled)
    }
}

// MARK: - FontCascade

/// One `CTFont` per (theme family, script, weight, slant, size), built with
/// the script's families installed in `kCTFontCascadeListAttribute` ahead of
/// the system fallback (PRD §8.3). Fonts are immutable and thread-safe, so
/// the cache is shared between the main thread and the warming queue.
public final class FontCascade: @unchecked Sendable {
    public let theme: Theme
    public let language: String?
    /// Resolved family per theme role, after the fallback chain.
    public let resolved: [FontFamily: String]

    private struct Key: Hashable {
        var family: FontFamily
        var script: Script
        var weight: FontWeight
        var italic: Bool
        var size: Int32 // quarter points
    }

    private let lock = NSLock()
    private var fonts: [Key: CTFont] = [:]
    private var cascadeLists: [Script: CFArray?] = [:]
    private var descriptors: [String: CTFontDescriptor] = [:]

    public init(theme: Theme, language: String? = nil) {
        self.theme = theme
        self.language = language
        var resolved: [FontFamily: String] = [:]
        for family in FontFamily.allCases {
            resolved[family] = InstalledFonts.first(of: theme.fonts.candidates(for: family)) ?? FontCascade.systemFamily(for: family)
        }
        self.resolved = resolved
    }

    static func systemFamily(for family: FontFamily) -> String {
        FontServer.sync {
            let font = family == .mono
                ? CTFontCreateUIFontForLanguage(.userFixedPitch, 12, nil)!
                : CTFontCreateUIFontForLanguage(.system, 12, nil)!
            return CTFontCopyFamilyName(font) as String
        }
    }

    /// Families for `script`, theme override first, then the §8.3 table.
    public func families(for script: Script) -> [String] {
        var names: [String] = theme.fonts.scripts[script] ?? []
        if script == .han {
            names += hanFamilies(language: language)
        } else if let entry = Script.cascadeTable[script] {
            names += entry.families(dark: theme.isDark)
        }
        return names.filter(InstalledFonts.isInstalled)
    }

    public func sizeFactor(for script: Script) -> CGFloat {
        Script.cascadeTable[script]?.sizeFactor ?? 1
    }

    /// The font for a run of `script` in `family` at the role's `size`
    /// (before the script's size factor, which this applies).
    public func font(family: FontFamily, script: Script, weight: FontWeight = .regular, italic: Bool = false, size: CGFloat) -> CTFont {
        let scaled = size * sizeFactor(for: script)
        let key = Key(family: family, script: script, weight: weight, italic: italic, size: Int32((scaled * 4).rounded()))
        lock.lock()
        defer { lock.unlock() }
        if let font = fonts[key] { return font }
        let font = makeFont(key: key, size: CGFloat(key.size) / 4)
        fonts[key] = font
        return font
    }

    /// A matched descriptor for `family`. Matching it once here means the
    /// descriptor's base font is resolved: hashing or comparing it later (as
    /// `NSAttributedString` does for every font attribute it stores) never
    /// has to ask the font server.
    private func descriptor(family: String) -> CTFontDescriptor {
        if let d = descriptors[family] { return d }
        let unmatched = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let d = FontServer.sync { CTFontDescriptorCreateMatchingFontDescriptor(unmatched, nil) } ?? unmatched
        descriptors[family] = d
        return d
    }

    /// The cascade list for `script`, shared by every font of that script so
    /// font comparisons short-circuit on the same array.
    private func cascadeList(for script: Script) -> CFArray? {
        if let list = cascadeLists[script] { return list }
        let list = families(for: script).map(descriptor(family:))
        let array: CFArray? = list.isEmpty ? nil : list as CFArray
        cascadeLists[script] = array
        return array
    }

    private func makeFont(key: Key, size: CGFloat) -> CTFont {
        let base = resolved[key.family] ?? "Helvetica"
        var traits: [CFString: Any] = [kCTFontWeightTrait: key.weight.trait]
        if key.italic { traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.traitItalic.rawValue }
        var attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: base,
            kCTFontTraitsAttribute: traits as CFDictionary,
        ]
        if let cascade = cascadeList(for: key.script) { attributes[kCTFontCascadeListAttribute] = cascade }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return FontServer.sync {
            let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            // A family without an italic face keeps its upright glyphs; synthesise
            // a 12° oblique as AppKit does.
            if key.italic, !CTFontGetSymbolicTraits(font).contains(.traitItalic) {
                var matrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
                return CTFontCreateWithFontDescriptor(descriptor, size, &matrix)
            }
            return font
        }
    }

    /// Advance of the digit zero in the body font: the unit of the measure.
    public func zeroAdvance(size: CGFloat) -> CGFloat {
        let font = self.font(family: .body, script: .latin, size: size)
        var glyph: CGGlyph = 0
        var char: UniChar = 0x30
        guard CTFontGetGlyphsForCharacters(font, &char, &glyph, 1) else { return size * 0.55 }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width
    }
}

// MARK: - Language

/// The language tag for CJK runs (§8.3): front matter `lang`, else the
/// recogniser over a sample, else nil (system default).
public enum LanguageTagger {
    public static func tag(frontMatter: String?, sample: String) -> String? {
        if let tag = frontMatter?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty { return tag }
        guard sample.unicodeScalars.contains(where: { Script.of($0) == .han }) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.japanese, .simplifiedChinese, .traditionalChinese, .korean]
        recognizer.processString(String(sample.prefix(4000)))
        return recognizer.dominantLanguage?.rawValue
    }
}
