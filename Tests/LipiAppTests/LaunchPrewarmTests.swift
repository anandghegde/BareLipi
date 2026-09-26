import Foundation
import LipiCore
import LipiLayout
import Testing
@testable import LipiApp

@Suite("Launch prewarm")
struct LaunchPrewarmTests {
    @Test @MainActor func startsOnceAndIsHarmless() {
        LaunchPrewarm.start(theme: .taalegari)
        LaunchPrewarm.start(theme: .taalegari)
        #expect(InstalledFonts.isInstalled("Helvetica") || InstalledFonts.isInstalled("Menlo"))
    }

    @Test func sharedFormatterIsSafeAcrossThreads() async {
        let counts = TextCounts(words: 1234, characters: 5678, charactersExcludingSpaces: 4567)
        let expected = StatusBar.format(document: counts, selection: nil, wordsPerMinute: 275)
        let results = await withTaskGroup(of: String.self) { group in
            for _ in 0..<16 { group.addTask { StatusBar.format(document: counts, selection: nil, wordsPerMinute: 275) } }
            return await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0 == expected })
    }
}
