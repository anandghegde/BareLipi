import AppKit
import LipiEditor
import Testing
@testable import LipiApp

// MARK: - Key chords

@Suite("Key chords")
@MainActor
struct KeyChordTests {
    @Test func parsesAndFormats() throws {
        let p = try #require(KeyChord(parsing: "Cmd-Shift-P"))
        #expect(p == KeyChord("p", [.command, .shift]))
        #expect(p.description == "Cmd-Shift-P")
        #expect(p.glyphs == "⇧⌘P")
        #expect(KeyChord(parsing: "shift-command-p") == p, "any order and case")
        #expect(KeyChord(parsing: "Cmd--") == KeyChord("-", .command))
        #expect(KeyChord(parsing: "Cmd-Opt--") == KeyChord("-", [.command, .option]))
        #expect(KeyChord(parsing: "Cmd-+") == KeyChord("+", .command))
        #expect(KeyChord(parsing: "Ctrl-Shift-Tab") == KeyChord("\t", [.control, .shift]))
        #expect(KeyChord(parsing: "Alt-Return") == KeyChord("\r", .option))
        #expect(KeyChord(parsing: "Esc")?.glyphs == "⎋")
        let f8 = try #require(KeyChord(parsing: "F8"))
        #expect(f8.isFunctionKey && f8.modifiers.isEmpty && f8.description == "F8")
        #expect(KeyChord(parsing: "Cmd-Ctrl-1")?.glyphs == "⌃⌘1")
        for bad in ["", "Cmd-", "Hyper-P", "Cmd-Banana"] { #expect(KeyChord(parsing: bad) == nil, "\(bad)") }
    }

    @Test func roundTripsEveryDefault() {
        for command in CommandRegistry.standardCommands() {
            for chord in command.defaultKeys {
                #expect(KeyChord(parsing: chord.description) == chord, "\(command.id) \(chord)")
            }
        }
    }

    @Test func canonicalFoldsShiftedPunctuation() {
        #expect(KeyChord("=", [.command, .shift]).canonical == KeyChord("+", .command))
        #expect(KeyChord("p", [.command, .shift]).canonical == KeyChord("p", [.command, .shift]))
    }
}

// MARK: - Keymap

@Suite("Keymap")
@MainActor
struct KeymapTests {
    func json(_ s: String) -> Data { Data(s.utf8) }

    @Test func parsesBindings() {
        let (map, issues) = Keymap.parse(json("""
        {"preset": "typora", "bindings": {
          "format.bold": "Cmd-Shift-B",
          "view.zoomIn": ["Cmd-=", "Cmd-+", "Cmd-="],
          "file.quickOpen": null,
          "format.italic": "",
          "format.code": [],
          "format.link": "Cmd-Banana",
          "format.image": 3
        }}
        """))
        #expect(map.preset == "Typora")
        #expect(map.overrides["format.bold"] == [KeyChord("b", [.command, .shift])])
        #expect(map.overrides["view.zoomIn"] == [KeyChord("=", .command), KeyChord("+", .command)], "duplicates dropped")
        #expect(map.overrides["file.quickOpen"] == [])
        #expect(map.overrides["format.italic"] == [])
        #expect(map.overrides["format.code"] == [])
        #expect(map.overrides["format.link"] == nil && map.overrides["format.image"] == nil)
        #expect(issues == [.badChord(command: "format.image", text: "3"), .badChord(command: "format.link", text: "Cmd-Banana")])
    }

    @Test func reportsBadFiles() {
        #expect(Keymap.parse(Data()) == (Keymap(), []))
        let (bad, badIssues) = Keymap.parse(json("{ nope"))
        #expect(bad == Keymap())
        guard case .invalidJSON = badIssues.first else { Issue.record("expected invalidJSON"); return }
        #expect(Keymap.parse(json("[1]")).1 == [.invalidJSON("the top level is not an object")])
        let (map, issues) = Keymap.parse(json(#"{"preset": "Emacs"}"#))
        #expect(map.preset == "BareLipi" && issues == [.unknownPreset("Emacs")])
        #expect(Keymap.parse(json(#"{"bindings": 1}"#)).1 == [.invalidJSON("\"bindings\" is not an object")])
    }

    @Test func encodesAndRoundTrips() {
        let map = Keymap(preset: "Typora", overrides: [
            "format.bold": [KeyChord("b", [.command, .shift])],
            "view.zoomIn": [KeyChord("=", .command), KeyChord("+", .command)],
            "file.quickOpen": [],
            "view.focusMode": [KeyChord(parsing: "F7")!],
        ])
        let text = String(decoding: map.encoded(), as: UTF8.self)
        #expect(text.contains(#""format.bold": "Cmd-Shift-B""#))
        #expect(text.contains(#""file.quickOpen": null"#))
        #expect(text.contains(#""view.zoomIn": ["Cmd-=", "Cmd-+"]"#))
        #expect(Keymap.parse(map.encoded()) == (map, []))
        #expect(Keymap.parse(Keymap().encoded()) == (Keymap(), []))
    }

    @Test func resolvesPresetThenOverrides() {
        let defaults = ["file.quickOpen": [KeyChord("p", .command)], "format.bold": [KeyChord("b", .command)]]
        #expect(Keymap().resolve(defaults: defaults) == defaults)
        let typora = Keymap(preset: "Typora").resolve(defaults: defaults)
        #expect(typora["file.quickOpen"] == [KeyChord("o", [.command, .shift])])
        let over = Keymap(preset: "Typora", overrides: ["file.quickOpen": [], "nope": [KeyChord("x", .command)]]).resolve(defaults: defaults)
        #expect(over["file.quickOpen"] == [] && over["nope"] == nil)
    }

    @Test func bindingToThePresetDropsTheOverride() {
        let defaults = ["format.bold": [KeyChord("b", .command)], "file.quickOpen": [KeyChord("p", .command)]]
        var map = Keymap().binding("format.bold", to: [KeyChord("k", .command)], defaults: defaults)
        #expect(map.overrides["format.bold"] == [KeyChord("k", .command)])
        map = map.binding("format.bold", to: [KeyChord("b", .command)], defaults: defaults)
        #expect(map.overrides.isEmpty)
        let typora = Keymap(preset: "Typora").binding("file.quickOpen", to: [KeyChord("o", [.command, .shift])], defaults: defaults)
        #expect(typora.overrides.isEmpty)
    }

    @Test func findsConflicts() {
        let bindings = [
            "a": [KeyChord("+", .command)],
            "b": [KeyChord("=", [.command, .shift])],
            "c": [KeyChord("0", .command)],
            "d": [KeyChord("0", .command)],
            "e": [KeyChord("e", .command), KeyChord("e", .command)],
        ]
        let found = Keymap.conflicts(in: bindings, shares: [["c", "d"]])
        #expect(found == [KeymapConflict(chord: KeyChord("+", .command), ids: ["a", "b"])], "Cmd-Shift-= is Cmd-+; shared keys and self-repeats are fine")
        #expect(Keymap.conflicts(in: bindings).count == 2)
    }

    @Test func typoraPresetHasNoConflicts() {
        let registry = CommandRegistry(commands: CommandRegistry.standardCommands(), keymap: Keymap(preset: "Typora"))
        #expect(registry.conflicts.isEmpty, "\(registry.conflicts)")
        #expect(registry.keys(for: "file.quickOpen") == [KeyChord("o", [.command, .shift])])
        for id in Keymap.presets["Typora"]!.keys { #expect(registry[id] != nil, "\(id)") }
    }
}

// MARK: - Registry and menu

@Suite("Command registry")
@MainActor
struct CommandRegistryTests {
    func registry(_ keymap: Keymap = Keymap()) -> CommandRegistry {
        CommandRegistry(commands: CommandRegistry.standardCommands(), keymap: keymap)
    }

    func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    @Test func registersEveryCommandOnce() {
        let r = registry()
        #expect(Set(r.commands.map(\.id)).count == r.commands.count)
        #expect(r.commands.allSatisfy { MainMenu.categories.contains($0.category) })
        // Every editor key equivalent is a registered command with the same default.
        for binding in EditorView.keyEquivalents {
            let command = r.command(for: binding.action)
            #expect(command?.defaultKeys.first == KeyChord(binding.key, binding.modifiers), "\(binding.title)")
        }
        #expect(r.conflicts.isEmpty, "\(r.conflicts)")
        #expect(r.issues.isEmpty)
    }

    @Test func phaseOneShortcuts() {
        let r = registry()
        #expect(r.keys(for: "view.commandPalette") == [KeyChord("p", [.command, .shift])])
        #expect(r.keys(for: "file.quickOpen") == [KeyChord("p", .command)], "BareLipi preset: Cmd-P is Quick Open")
        #expect(r.keys(for: "view.outline") == [KeyChord("2", [.command, .control])])
        #expect(r.keys(for: "view.toggleSidebar") == [KeyChord("l", [.command, .shift])])
        #expect(r.keys(for: "file.closeWindow") == [KeyChord("w", [.command, .shift])])
        #expect(r.keys(for: "view.zoomIn") == [KeyChord("=", .command), KeyChord("+", .command)])
    }

    @Test func menuIsBuiltFromTheRegistry() throws {
        _ = NSApplication.shared
        let r = registry()
        let menu = MainMenu.build(registry: r)
        #expect(menu.items.map(\.title) == ["BareLipi", "File", "Edit", "Format", "View", "Window", "Help"])
        let items = allItems(menu)
        for command in r.commands {
            let item = try #require(r.menuItems[command.id], "\(command.id)")
            #expect(items.contains(item))
            #expect(item.action == command.action)
            #expect(item.isHidden == !command.showsInMenu)
            if let chord = r.keys(for: command.id).first {
                #expect(item.keyEquivalent == chord.key, "\(command.id)")
            }
        }
        let view = try #require(menu.item(withTitle: "View")?.submenu)
        #expect(view.item(withTitle: "Command Palette…")?.keyEquivalentModifierMask == [.command, .shift])
        #expect(view.item(withTitle: "Focus Mode")?.keyEquivalent == KeyChord(parsing: "F8")?.key)
        let file = try #require(menu.item(withTitle: "File")?.submenu)
        #expect(file.item(withTitle: "Open Recent")?.submenu != nil)
        #expect(file.item(withTitle: "Quick Open…")?.keyEquivalent == "p")
        // The shell host has no document-only commands.
        let shell = MainMenu.build(documents: false, registry: registry())
        #expect(shell.item(withTitle: "File")?.submenu?.item(withTitle: "Quick Open…") == nil)
    }

    @Test func overridesRebindMenusAndTheEditor() throws {
        _ = NSApplication.shared
        let r = CommandRegistry(commands: CommandRegistry.standardCommands(), drivesEditor: true)
        defer { r.apply(Keymap()) }
        r.apply(Keymap(overrides: ["format.bold": [KeyChord("b", [.command, .control, .option])], "file.quickOpen": [KeyChord("o", [.command, .shift])]]))
        #expect(r.isOverridden("format.bold") && !r.isOverridden("format.italic"))
        let menu = MainMenu.build(registry: r)
        let bold = try #require(menu.item(withTitle: "Format")?.submenu?.item(withTitle: "Bold"))
        #expect(bold.keyEquivalentModifierMask == [.command, .control, .option])
        func key(_ mods: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                             characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)
        }
        #expect(EditorView.binding(for: try #require(key([.command, .control, .option])))?.action == #selector(EditorView.toggleStrong(_:)))
        #expect(EditorView.binding(for: try #require(key(.command))) == nil)
        #expect(r.conflicts.isEmpty)
        r.apply(Keymap(overrides: ["format.bold": [KeyChord("b", [.command, .control, .option])], "format.italic": [KeyChord("b", [.command, .control, .option])], "bogus": []]))
        #expect(r.conflicts.map(\.ids) == [["format.bold", "format.italic"]])
        #expect(r.conflictingIDs == ["format.bold", "format.italic"])
        #expect(r.issues == [.unknownCommand("bogus")])
        #expect(KeymapStore.problemLines(of: r).count == 2)
    }

    @Test func sidebarAndCloseWindowActionsExist() {
        #expect(DocumentWindowController.instancesRespond(to: #selector(DocumentWindowController.toggleSidebarPanes(_:))))
        #expect(DocumentWindowController.instancesRespond(to: #selector(DocumentWindowController.closeWindowAndTabs(_:))))
    }
}

// MARK: - Palette

@Suite("Command palette")
@MainActor
struct CommandPaletteTests {
    let registry = CommandRegistry(commands: CommandRegistry.standardCommands())

    @Test func matchesTitlesAndIDsWithShortcuts() throws {
        let model = QuickOpenModel(commands: CommandPalette.items(registry: registry, enabled: nil))
        let bold = try #require(model.results(for: ">bold").first)
        #expect(bold.title == "Bold" && bold.shortcut == "⌘B" && bold.subtitle == "Format")
        #expect(model.results(for: ">heading 2").first?.title == "Heading 2")
        #expect(model.results(for: ">format.strike").first?.title == "Strikethrough", "ids match too")
        #expect(model.results(for: ">palette").first?.shortcut == "⇧⌘P")
        #expect(model.results(for: ">settings").first?.title == "Settings", "ellipsis dropped")
        #expect(model.results(for: ">qqqzzz").isEmpty)
    }

    @Test func recentCommandsComeFirst() throws {
        let fresh = QuickOpenModel(commands: CommandPalette.items(registry: registry, enabled: nil))
        #expect(fresh.results(for: ">").first?.title == "About BareLipi")
        let model = QuickOpenModel(commands: CommandPalette.items(registry: registry, enabled: nil, history: ["view.zenMode", "format.bold"]))
        #expect(model.results(for: ">").prefix(2).map(\.title) == ["Zen Mode", "Bold"])
    }

    @Test func onlyEnabledCommandsAndRebindingsShow() {
        let items = CommandPalette.items(registry: registry, enabled: ["format.bold"])
        #expect(items.map(\.title) == ["Bold"])
        let rebound = CommandRegistry(commands: CommandRegistry.standardCommands(), keymap: Keymap(overrides: ["format.bold": []]))
        #expect(CommandPalette.items(registry: rebound, enabled: ["format.bold"]).first?.shortcut == "")
        #expect(CommandPalette.items(registry: registry, enabled: nil, documents: false).contains { $0.keywords == "file.quickOpen" } == false)
    }

    @Test func historyIsMostRecentFirstAndCapped() throws {
        let defaults = try #require(UserDefaults(suiteName: "CommandPaletteTests-\(UUID().uuidString)"))
        for n in 0..<20 { CommandPalette.record("c\(n)", defaults) }
        CommandPalette.record("c5", defaults)
        let history = CommandPalette.history(defaults)
        #expect(history.count == CommandPalette.historyLimit)
        #expect(history.prefix(2) == ["c5", "c19"])
        #expect(history.filter { $0 == "c5" }.count == 1)
    }
}

// MARK: - keymap.json on disk

@Suite("Keymap store")
@MainActor
struct KeymapStoreTests {
    @Test func loadsSavesAndReloads() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let store = KeymapStore(url: dir.file("BareLipi/keymap.json"))
        #expect(store.load() == (Keymap(), []), "a missing file is the default keymap")
        let registry = CommandRegistry(commands: CommandRegistry.standardCommands())
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .commandBindingsDidChange, object: registry, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let custom = Keymap(overrides: ["format.bold": [KeyChord("b", [.command, .control, .option])]])
        try store.save(custom, to: registry)
        #expect(registry.keymap == custom && posted == 1)
        #expect(!store.reloadIfChanged(into: registry), "our own write is not a change")
        #expect(KeymapStore(url: store.url).load() == (custom, []))

        // An external edit (another editor) is picked up.
        try Data(#"{"preset": "Typora", "bindings": {"format.bold": "Cmd-Banana"}}"#.utf8).write(to: store.url)
        #expect(store.reloadIfChanged(into: registry))
        #expect(registry.keymap.preset == "Typora" && registry.keymap.overrides.isEmpty)
        #expect(registry.issues == [.badChord(command: "format.bold", text: "Cmd-Banana")])
        #expect(registry.keys(for: "file.quickOpen") == [KeyChord("o", [.command, .shift])])

        // Deleting the file goes back to the defaults.
        try FileManager.default.removeItem(at: store.url)
        #expect(store.reloadIfChanged(into: registry))
        #expect(registry.keymap == Keymap() && registry.issues.isEmpty)
    }

    @Test func watchesTheFile() async throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("keymap.json")
        let store = KeymapStore(url: url)
        let registry = CommandRegistry(commands: CommandRegistry.standardCommands())
        store.target = registry
        _ = store.load()
        store.startWatching()
        defer { store.stopWatching() }
        try Data(#"{"bindings": {"format.bold": "Cmd-Opt-B"}}"#.utf8).write(to: url, options: .atomic)
        for _ in 0..<60 where registry.keymap.overrides.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(registry.keys(for: "format.bold") == [KeyChord("b", [.command, .option])])
        // An in-place edit of the watched file.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(#"{"bindings": {"format.bold": "Cmd-Ctrl-B"}}"#.utf8))
        try handle.close()
        for _ in 0..<60 where registry.keys(for: "format.bold") != [KeyChord("b", [.command, .control])] {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(registry.keys(for: "format.bold") == [KeyChord("b", [.command, .control])])
    }

    /// Launch cost of the keymap (P0-11 asks for lazy and cheap loading):
    /// registry construction plus load, with and without a file.
    @Test func loadingIsCheap() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let missing = KeymapStore(url: dir.file("none.json"))
        let present = KeymapStore(url: dir.file("keymap.json"))
        try present.save(Keymap(preset: "Typora", overrides: ["format.bold": [KeyChord("b", [.command, .control, .option])]]),
                         to: CommandRegistry(commands: []))
        func time(_ store: KeymapStore) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            let registry = CommandRegistry(commands: CommandRegistry.standardCommands())
            let (keymap, issues) = store.load()
            registry.apply(keymap, issues: issues)
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        _ = time(missing)
        let a = (0..<5).map { _ in time(missing) }.min()!
        let b = (0..<5).map { _ in time(present) }.min()!
        print("keymap load: no file \(String(format: "%.3f", a)) ms, with file \(String(format: "%.3f", b)) ms")
        _ = NSApplication.shared
        let registry = CommandRegistry(commands: CommandRegistry.standardCommands())
        let menu = (0..<5).map { _ -> Double in
            let start = DispatchTime.now().uptimeNanoseconds
            _ = MainMenu.build(registry: registry)
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }.min()!
        print("menu build from the registry: \(String(format: "%.3f", menu)) ms")
        #expect(a < 20 && b < 20)
    }
}

// MARK: - Settings → Keys

@Suite("Settings keys pane")
@MainActor
struct KeysSettingsPaneTests {
    @Test func rowsSearchAndMarkers() {
        let registry = CommandRegistry(commands: CommandRegistry.standardCommands(),
                                       keymap: Keymap(overrides: ["format.bold": [KeyChord("i", .command)]]))
        let all = KeysSettingsPane.rows(registry: registry, query: "")
        #expect(all.count == registry.commands.count + KeysSettingsPane.contextRows.count)
        let bold = all.first { $0.id == "format.bold" }
        #expect(bold?.overridden == true && bold?.conflict == true && bold?.shortcut == "⌘I")
        #expect(all.first { $0.id == "format.italic" }?.conflict == true)
        #expect(KeysSettingsPane.rows(registry: registry, query: "zen").compactMap(\.id) == ["view.zenMode"])
        #expect(KeysSettingsPane.rows(registry: registry, query: "⌃⌘2").compactMap(\.id) == ["view.outline"])
        #expect(KeysSettingsPane.rows(registry: registry, query: "next cell").map(\.title) == ["Next Cell"])
    }

    @Test func paneLoads() {
        _ = NSApplication.shared
        let pane = KeysSettingsPane(registry: CommandRegistry(commands: CommandRegistry.standardCommands()),
                                    store: KeymapStore(url: URL(fileURLWithPath: "/nonexistent/keymap.json")))
        pane.loadView()
        #expect(pane.view.subviews.isEmpty == false)
    }
}
