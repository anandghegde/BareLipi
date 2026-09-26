import Foundation
import LipiCore
import LipiLayout

/// Work that the first window needs and that is thread-safe, started on a
/// background queue as soon as `main` runs. It overlaps the ~40 ms that
/// `NSApplication` spends initialising itself, so that by the time the
/// first document is created the process-wide caches are warm:
///
/// - the installed font family list (`CTFontManagerCopyAvailableFontFamilyNames`,
///   read by every `FontCascade`);
/// - Core Text's caches for the theme's body, heading and mono faces;
/// - ICU's number formatting data, used by the status bar's first update.
///
/// Nothing here is required: the main thread computes the same values on
/// demand if it gets there first, and `InstalledFonts` is a `static let`,
/// so a race only means waiting for the one in flight.
enum LaunchPrewarm {
    @MainActor private static var started = false

    @MainActor
    static func start(theme: Theme) {
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .userInteractive).async {
            let cascade = FontCascade(theme: theme)
            let size = theme.metrics.bodySize
            _ = cascade.font(family: .body, script: .latin, size: size)
            _ = cascade.font(family: .body, script: .latin, weight: .bold, size: size)
            _ = cascade.font(family: .heading, script: .latin, weight: .bold, size: size * 1.5)
            _ = cascade.font(family: .mono, script: .latin, size: size * 0.9)
            _ = StatusBar.format(document: TextCounts(words: 1234, characters: 5678, charactersExcludingSpaces: 4567),
                                 selection: nil, wordsPerMinute: 275)
        }
    }
}
