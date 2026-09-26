import CoreText
import Foundation
import LipiLayout
import Testing

@Suite("Script runs")
struct ScriptRunTests {
    @Test func latinKannadaLatin() {
        let runs = scriptRuns(of: "Hello ಕನ್ನಡ world")
        #expect(runs.map(\.script) == [.latin, .kannada, .latin])
        #expect(runs.first?.range.lowerBound == 0)
        #expect(runs.last?.range.upperBound == "Hello ಕನ್ನಡ world".utf16.count)
        for (a, b) in zip(runs, runs.dropFirst()) { #expect(a.range.upperBound == b.range.lowerBound) }
    }

    @Test func commonCharactersJoinTheCurrentRun() {
        // Digits, spaces and punctuation never start a run of their own.
        let runs = scriptRuns(of: "ಕನ್ನಡ 2024, ok")
        #expect(runs.count == 2)
        #expect(runs[0].script == .kannada)
        #expect(runs[0].range == 0..<12)
        #expect(runs[1].script == .latin)
    }

    @Test func leadingCommonCharactersJoinTheFirstRun() {
        let runs = scriptRuns(of: "  (हिन्दी)")
        #expect(runs.count == 1)
        #expect(runs[0].script == .devanagari)
        #expect(runs[0].range.lowerBound == 0)
    }

    @Test func allCommonIsOneLatinRun() {
        let runs = scriptRuns(of: "12 34 !?")
        #expect(runs == [ScriptRun(range: 0..<8, script: .latin)])
        #expect(scriptRuns(of: "").isEmpty)
    }

    @Test func emojiAndSupplementaryPlanes() {
        // Emoji are two UTF-16 units; ranges are UTF-16.
        let runs = scriptRuns(of: "a😀b")
        #expect(runs.map(\.script) == [.latin, .emoji, .latin])
        #expect(runs[1].range == 1..<3)
    }

    @Test func scriptClassification() {
        #expect(Script.of("ಕ") == .kannada)
        #expect(Script.of("क") == .devanagari)
        #expect(Script.of("த") == .tamil)
        #expect(Script.of("日") == .han)
        #expect(Script.of("あ") == .hiragana)
        #expect(Script.of("ア") == .katakana)
        #expect(Script.of("한") == .hangul)
        #expect(Script.of("ع") == .arabic)
        #expect(Script.of("א") == .hebrew)
        #expect(Script.of("😀") == .emoji)
        #expect(Script.of(" ") == nil)
        #expect(Script.of("1") == nil)
        #expect(Script.arabic.isRightToLeft)
        #expect(!Script.kannada.isRightToLeft)
    }
}

@Suite("Font cascade (§8.3)")
struct FontCascadeTests {
    let cascade = FontCascade(theme: .paper)

    @Test func tallScriptsAndSizeFactors() {
        #expect(Script.kannada.lineHeightClass == .tall)
        #expect(Script.devanagari.lineHeightClass == .tall)
        #expect(Script.tamil.lineHeightClass == .tall)
        #expect(Script.latin.lineHeightClass == .standard)
        #expect(Script.han.lineHeightClass == .standard)
        #expect(cascade.sizeFactor(for: .kannada) == 1.08)
        #expect(cascade.sizeFactor(for: .devanagari) == 1.05)
        #expect(cascade.sizeFactor(for: .tamil) == 1.06)
        #expect(cascade.sizeFactor(for: .latin) == 1)
    }

    @Test func resolvedFamiliesAreInstalled() {
        for family in FontFamily.allCases {
            let name = cascade.resolved[family]
            #expect(name != nil)
            #expect(InstalledFonts.isInstalled(name ?? ""), "\(family) resolved to \(name ?? "nil")")
        }
    }

    @Test func indicCascadesUseInstalledSystemFonts() {
        for script in [Script.kannada, .devanagari, .tamil, .telugu, .malayalam, .bengali, .gujarati, .gurmukhi] {
            let families = cascade.families(for: script)
            #expect(!families.isEmpty, "\(script) has no installed fallback")
            for f in families { #expect(InstalledFonts.isInstalled(f)) }
        }
        #expect(cascade.families(for: .kannada).contains { $0.contains("Kannada") })
        #expect(cascade.families(for: .devanagari).contains { $0.contains("Devanagari") })
    }

    @Test func hanCascadeFollowsLanguage() {
        let ja = FontCascade(theme: .paper, language: "ja").families(for: .han)
        let hans = FontCascade(theme: .paper, language: "zh-Hans").families(for: .han)
        let hant = FontCascade(theme: .paper, language: "zh-Hant").families(for: .han)
        #expect(ja.first?.contains("Hiragino") == true)
        #expect(hans.first?.contains("PingFang SC") == true)
        #expect(hant.first?.contains("PingFang TC") == true)
    }

    @Test func fontSizeAppliesScriptFactor() {
        let latin = cascade.font(family: .body, script: .latin, size: 17)
        let kannada = cascade.font(family: .body, script: .kannada, size: 17)
        #expect(CTFontGetSize(latin) == 17)
        #expect(approximately(CTFontGetSize(kannada), 17 * 1.08, within: 0.25))
    }

    @Test func fontsAreCachedAndCarryCascadeLists() {
        let a = cascade.font(family: .body, script: .kannada, size: 17)
        let b = cascade.font(family: .body, script: .kannada, size: 17)
        #expect(a === b)
        let descriptor = CTFontCopyFontDescriptor(a)
        let list = CTFontDescriptorCopyAttribute(descriptor, kCTFontCascadeListAttribute) as? [CTFontDescriptor]
        #expect((list?.count ?? 0) >= 1)
    }

    @Test func weightsAndItalics() {
        let regular = cascade.font(family: .body, script: .latin, size: 17)
        let semibold = cascade.font(family: .body, script: .latin, weight: .semibold, size: 17)
        let bold = cascade.font(family: .body, script: .latin, weight: .bold, size: 17)
        #expect(weightTrait(of: semibold) > weightTrait(of: regular))
        #expect(weightTrait(of: bold) >= weightTrait(of: semibold))
        let italic = cascade.font(family: .body, script: .latin, italic: true, size: 17)
        #expect(isItalic(italic))
        #expect(!isItalic(regular))
        // Kannada system fonts have no italic face: the oblique is synthesised.
        let kannadaItalic = cascade.font(family: .body, script: .kannada, italic: true, size: 17)
        #expect(isItalic(kannadaItalic))
    }

    @Test func zeroAdvanceIsPlausible() {
        let advance = cascade.zeroAdvance(size: 17)
        #expect(advance > 6 && advance < 14)
        #expect(cascade.zeroAdvance(size: 34) > advance * 1.9)
    }

    @Test func themesResolveDifferentBodyFamilies() {
        let serif = FontCascade(theme: .paper).resolved[.body]!
        let sans = FontCascade(theme: .snow).resolved[.body]!
        #expect(serif != sans)
    }
}

@Suite("Language tagging")
struct LanguageTaggerTests {
    @Test func frontMatterWins() {
        #expect(LanguageTagger.tag(frontMatter: "ja", sample: "中文写作") == "ja")
        #expect(LanguageTagger.tag(frontMatter: " zh-Hant \n", sample: "") == "zh-Hant")
    }

    @Test func recognisesJapaneseAndChinese() {
        let ja = LanguageTagger.tag(frontMatter: nil, sample: "日本語の文章を書くことは楽しいです。エディタが軽くて速いと気持ちがいい。")
        #expect(ja == "ja")
        let zh = LanguageTagger.tag(frontMatter: nil, sample: "编辑器应该轻快而可靠。中文写作是一种乐趣。")
        #expect(zh?.hasPrefix("zh") == true)
    }

    @Test func noHanMeansNoTag() {
        #expect(LanguageTagger.tag(frontMatter: nil, sample: "plain latin text ಕನ್ನಡ") == nil)
        #expect(LanguageTagger.tag(frontMatter: "", sample: "no han here") == nil)
    }
}
