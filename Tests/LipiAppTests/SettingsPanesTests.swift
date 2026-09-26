import AppKit
import Foundation
import LipiCore
import LipiEditor
import LipiExport
import LipiLayout
import Testing
@testable import LipiApp

private func scratchDefaults() -> UserDefaults {
    let name = "BareLipiTests.settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func controls<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    var out: [T] = []
    for sub in view.subviews {
        if let hit = sub as? T { out.append(hit) }
        out += controls(type, in: sub)
    }
    return out
}

@Suite("Settings: typed defaults")
struct AppSettingsTests {
    @Test func defaultsMatchThePRD() {
        let s = AppSettings(defaults: scratchDefaults())
        #expect(s.wordsPerMinute == 275)
        #expect(s.cjkByCharacter == false && s.countCode && s.countMath)
        #expect(s.convertHEIC, "HEIC conversion is on by default")
        #expect(s.imageNaming == .timestamp)
        #expect(s.autoPair && s.completeTables)
        #expect(s.emphasisMarker == "*" && s.hardBreak == .backslash)
        #expect(s.codeOptions == CodeBlockOptions())
        #expect(s.editorSettings == EditorSettings())
        #expect(s.countOptions == CountOptions())
        #expect(s.exportImages == .reference)
    }

    @Test func valuesRoundTripAndCompose() {
        let s = AppSettings(defaults: scratchDefaults())
        s.emphasisMarker = "_"
        s.hardBreak = .twoSpaces
        s.autoPair = false
        s.codeWrap = false
        s.codeLineNumbers = true
        s.wordsPerMinute = 200
        s.cjkByCharacter = true
        s.countMath = false
        s.imageNaming = .original
        s.convertHEIC = false
        s.exportImages = .embed
        #expect(s.editorSettings == EditorSettings(emphasisMarker: "_", hardBreak: .twoSpaces, autoPair: false))
        #expect(s.codeOptions == CodeBlockOptions(lineNumbers: true, wrap: false))
        #expect(s.countOptions == CountOptions(includeCode: true, includeMath: false, cjkByCharacter: true, wordsPerMinute: 200))
        #expect(s.imageNaming == .original && !s.convertHEIC && s.exportImages == .embed)
    }

    @Test func readingSpeedIsClamped() {
        let s = AppSettings(defaults: scratchDefaults())
        s.wordsPerMinute = 5
        #expect(s.wordsPerMinute == 50)
        s.wordsPerMinute = 99_999
        #expect(s.wordsPerMinute == 1000)
    }

    @Test @MainActor func imageKeysAreTheOnesAssetStoreReads() {
        #expect(AppSettings.Key.imageNaming == AssetStore.namingKey)
        #expect(AppSettings.Key.convertHEIC == AssetStore.convertHEICKey)
    }

    @Test func settersPostTheChangedKey() {
        let defaults = scratchDefaults()
        final class Seen: @unchecked Sendable { var keys: [String] = [] }
        let seen = Seen()
        let token = NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: defaults, queue: nil) { note in
            if let key = note.userInfo?["key"] as? String { seen.keys.append(key) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        AppSettings(defaults: defaults).countCode = false
        #expect(seen.keys == [AppSettings.Key.countCode])
    }
}

@Suite("Settings: panes")
@MainActor
struct SettingsPanesTests {
    @Test func windowHasEditingCountsImagesAndKeys() {
        #expect(SettingsWindowController.makePanes().map(\.label) == ["Editing", "Counts", "Images", "Keys"])
    }

    @Test func editingPaneWritesThrough() throws {
        let s = AppSettings(defaults: scratchDefaults())
        let pane = EditorSettingsPane(settings: s)
        let boxes = controls(NSButton.self, in: pane.view).filter { $0.title.contains("Auto-pair") || $0.title.contains("line numbers") }
        #expect(boxes.count == 2)
        for box in boxes { box.performClick(nil) }
        #expect(!s.autoPair && s.codeLineNumbers)
        let popups = controls(NSPopUpButton.self, in: pane.view)
        let marker = try #require(popups.first { $0.itemTitles.contains("_underscores_") })
        marker.selectItem(at: 1)
        _ = marker.target?.perform(marker.action, with: marker)
        #expect(s.emphasisMarker == "_")
    }

    @Test func countsPaneShowsAndStoresTheSpeed() throws {
        let s = AppSettings(defaults: scratchDefaults())
        s.wordsPerMinute = 300
        let pane = CountsSettingsPane(settings: s)
        _ = pane.view
        let field = try #require(pane.speedField)
        #expect(field.stringValue == "300")
        field.stringValue = "180"
        _ = field.target?.perform(field.action, with: field)
        #expect(s.wordsPerMinute == 180)
        let cjk = try #require(controls(NSButton.self, in: pane.view).first { $0.title.contains("by character") })
        cjk.performClick(nil)
        #expect(s.cjkByCharacter)
    }

    @Test func imagesPaneStartsFromTheStoredValues() throws {
        let s = AppSettings(defaults: scratchDefaults())
        s.convertHEIC = false
        s.exportImages = .copy
        let pane = ImagesSettingsPane(settings: s)
        let heic = try #require(controls(NSButton.self, in: pane.view).first { $0.title.contains("HEIC") })
        #expect(heic.state == .off)
        let export = try #require(controls(NSPopUpButton.self, in: pane.view).first { $0.itemTitles.contains(ImageExport.Mode.embed.title) })
        #expect(export.titleOfSelectedItem == ImageExport.Mode.copy.title)
        heic.performClick(nil)
        #expect(s.convertHEIC)
    }

    @Test func windowAppliesSettingsToEditorAndCounts() {
        let s = AppSettings(defaults: scratchDefaults())
        s.emphasisMarker = "_"
        s.hardBreak = .twoSpaces
        s.codeWrap = false
        s.wordsPerMinute = 100
        let controller = EditorController(text: "Hello", viewportWidth: 800)
        let wc = DocumentWindowController(controller: controller, theme: .taalegari, contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        wc.applySettings(s)
        #expect(controller.settings.emphasisMarker == "_" && controller.settings.hardBreak == .twoSpaces)
        #expect(controller.codeOptions.wrap == false)
        #expect(wc.counts.options.wordsPerMinute == 100)
        controller.codeOptions.lineNumbers = true
        wc.applySettings(s, code: false)
        #expect(controller.codeOptions.lineNumbers, "a window's own toggle survives unrelated changes")
    }
}
