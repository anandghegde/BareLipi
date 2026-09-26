import AppKit
import LipiEditor
import os

/// One user command (P0-11, PRD §6.11): every menu item and editor action
/// is registered once, with a stable id (the keymap.json key), a title, a
/// category (its top-level menu), where it sits in the menu and its
/// default shortcuts (the BareLipi preset, Appendix B).
///
/// A command is an action sent down the responder chain, so the object
/// that performs it also validates it (`validateMenuItem`), exactly as
/// the menu does: `isEnabled(Context)` and `perform(Context)` of the PRD
/// are the chain's target for the key window.
@MainActor
public struct Command {
    public let id: String
    /// Menu title; `{app}` becomes the application's name.
    public let title: String
    /// Its top-level menu: App, File, Edit, Format, View, Window or Help.
    public let category: String
    /// A submenu of the category ("Heading", "Find", "Export"), if any.
    public let submenu: String?
    /// Separator groups: items in the same menu are separated when their
    /// group changes. `group` places the item (or its submenu) in the
    /// category menu; `subgroup` separates items inside the submenu.
    public let group: Int
    public let subgroup: Int
    public let defaultKeys: [KeyChord]
    public let action: Selector
    /// False for commands that are bound and in the palette but have no
    /// visible menu item (their item is hidden).
    public let showsInMenu: Bool
    /// Only in the document-based app (not the SwiftPM shell).
    public let documentsOnly: Bool

    public init(id: String, title: String, category: String, submenu: String? = nil, group: Int = 0, subgroup: Int = 0,
                keys: [KeyChord] = [], action: Selector, showsInMenu: Bool = true, documentsOnly: Bool = false) {
        self.id = id
        self.title = title
        self.category = category
        self.submenu = submenu
        self.group = group
        self.subgroup = subgroup
        self.defaultKeys = keys
        self.action = action
        self.showsInMenu = showsInMenu
        self.documentsOnly = documentsOnly
    }

    public func title(appName: String) -> String { title.replacingOccurrences(of: "{app}", with: appName) }

    /// "Format › Heading".
    public func path(appName: String) -> String {
        let top = category == "App" ? appName : category
        return submenu.map { "\(top) › \($0)" } ?? top
    }
}

extension Notification.Name {
    /// Posted when the registry's effective bindings change.
    public static let commandBindingsDidChange = Notification.Name("BareLipi.commandBindingsDidChange")
}

/// Every user command and its current bindings; the main menu, the
/// editor's key handler, the command palette and Settings → Keys are all
/// built from it.
@MainActor
public final class CommandRegistry {
    /// The app's registry, with the user's keymap.json applied. Created on
    /// first use (the main menu's construction at launch); loading the
    /// keymap is one `stat` when there is no file.
    public static let shared: CommandRegistry = {
        let registry = CommandRegistry(commands: CommandRegistry.standardCommands(), drivesEditor: true)
        let (keymap, issues) = KeymapStore.shared.load()
        registry.apply(keymap, issues: issues)
        return registry
    }()

    public let commands: [Command]
    private let index: [String: Int]
    public private(set) var keymap = Keymap()
    /// Id → effective chords (first shown in menus, the rest hidden alternates).
    public private(set) var bindings: [String: [KeyChord]] = [:]
    public private(set) var issues: [KeymapIssue] = []
    public private(set) var conflicts: [KeymapConflict] = []
    /// Commands that share a key on purpose (Appendix B): Cmd-0 is
    /// Paragraph while the editor has focus and Actual Size otherwise.
    public let shares: [Set<String>] = [["format.paragraph", "view.actualSize"]]
    /// The menu items made for each command by the last `MainMenu.build`.
    var menuItems: [String: NSMenuItem] = [:]

    /// Whether `apply` sets the editor's key table (`EditorView.activeKeyEquivalents`,
    /// shared by every editor): only the app's registry does.
    public let drivesEditor: Bool

    public init(commands: [Command], keymap: Keymap = Keymap(), issues: [KeymapIssue] = [], drivesEditor: Bool = false) {
        self.drivesEditor = drivesEditor
        var seen: [String: Int] = [:]
        for (n, command) in commands.enumerated() {
            precondition(seen[command.id] == nil, "command \(command.id) registered twice")
            seen[command.id] = n
        }
        self.commands = commands
        index = seen
        apply(keymap, issues: issues)
    }

    public subscript(id: String) -> Command? { index[id].map { commands[$0] } }

    public func command(for action: Selector) -> Command? { commands.first { $0.action == action } }

    public var defaultBindings: [String: [KeyChord]] {
        Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0.defaultKeys) })
    }

    public func keys(for id: String) -> [KeyChord] { bindings[id] ?? [] }

    /// True when the command's binding differs from its preset's.
    public func isOverridden(_ id: String) -> Bool { keymap.overrides[id] != nil }

    /// Ids of the commands whose chords collide with another command's.
    public var conflictingIDs: Set<String> { Set(conflicts.flatMap(\.ids)) }

    /// Applies a keymap: resolves the bindings, reports unknown ids and
    /// conflicts, updates the editor's key table and posts
    /// `commandBindingsDidChange`.
    public func apply(_ keymap: Keymap, issues: [KeymapIssue] = []) {
        self.keymap = keymap
        var found = issues
        for id in keymap.overrides.keys.sorted() where index[id] == nil { found.append(.unknownCommand(id)) }
        self.issues = found
        bindings = keymap.resolve(defaults: defaultBindings)
        conflicts = Keymap.conflicts(in: bindings, shares: shares)
        if drivesEditor { EditorView.activeKeyEquivalents = editorKeyEquivalents() }
        NotificationCenter.default.post(name: .commandBindingsDidChange, object: self)
    }

    /// The editor's key table under the current bindings: one entry per
    /// chord of every command whose action is an `EditorView` command.
    public func editorKeyEquivalents() -> [EditorKeyEquivalent] {
        var out: [EditorKeyEquivalent] = []
        for binding in EditorView.keyEquivalents {
            guard let command = command(for: binding.action) else { continue }
            for chord in keys(for: command.id) {
                out.append(EditorKeyEquivalent(command.title, chord.key, chord.modifiers, command.action))
            }
        }
        return out
    }

    // MARK: Running

    /// Whether the key window's responder chain would perform `id` now,
    /// asking the same validation the menu asks.
    public func isEnabled(_ id: String) -> Bool {
        guard let item = menuItems[id] else { return false }
        item.menu?.update()
        return item.isEnabled
    }

    /// Ids of every enabled command, validating each menu once.
    public func enabledIDs() -> Set<String> {
        var updated = Set<ObjectIdentifier>()
        var out = Set<String>()
        for (id, item) in menuItems {
            if let menu = item.menu, updated.insert(ObjectIdentifier(menu)).inserted { menu.update() }
            if item.isEnabled { out.insert(id) }
        }
        return out
    }

    /// Sends the command's action down the key window's responder chain.
    @discardableResult
    public func perform(_ id: String) -> Bool {
        guard let command = self[id] else { return false }
        return NSApp.sendAction(command.action, to: nil, from: menuItems[id])
    }
}

// MARK: - The standard commands

extension CommandRegistry {
    /// Every command of the app, in menu order. Editor commands take their
    /// titles and default keys from `EditorView.keyEquivalents`.
    public static func standardCommands() -> [Command] {
        var out: [Command] = []
        var category = ""
        var submenu: String?
        var group = 0
        var subgroup = 0
        func key(_ text: String) -> KeyChord {
            guard let chord = KeyChord(parsing: text) else { preconditionFailure("bad default key \(text)") }
            return chord
        }
        func add(_ id: String, _ title: String, _ action: Selector, _ keys: String..., hidden: Bool = false, documentsOnly: Bool = false) {
            out.append(Command(id: id, title: title, category: category, submenu: submenu, group: group, subgroup: subgroup,
                               keys: keys.map(key), action: action, showsInMenu: !hidden, documentsOnly: documentsOnly))
        }
        func editor(_ id: String, _ action: Selector) {
            guard let binding = EditorView.keyEquivalents.first(where: { $0.action == action }) else {
                preconditionFailure("no editor key equivalent for \(action)")
            }
            out.append(Command(id: id, title: binding.title, category: category, submenu: submenu, group: group, subgroup: subgroup,
                               keys: [KeyChord(binding.key, binding.modifiers)], action: action))
        }

        category = "App"
        add("app.about", "About {app}", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        group = 1
        add("app.settings", "Settings…", #selector(NSApplication.lipiShowSettings(_:)), "Cmd-,")
        group = 2
        add("app.hide", "Hide {app}", #selector(NSApplication.hide(_:)), "Cmd-H")
        add("app.hideOthers", "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "Cmd-Opt-H")
        add("app.showAll", "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        group = 3
        add("app.quit", "Quit {app}", #selector(NSApplication.terminate(_:)), "Cmd-Q")

        category = "File"; group = 0
        add("file.new", "New", #selector(NSDocumentController.newDocument(_:)), "Cmd-N")
        add("file.newTab", "New Tab", #selector(NSResponder.newWindowForTab(_:)), "Cmd-T")
        add("file.open", "Open…", #selector(NSDocumentController.openDocument(_:)), "Cmd-O")
        add("file.quickOpen", "Quick Open…", #selector(LipiDocumentController.showQuickOpen(_:)), "Cmd-P", documentsOnly: true)
        group = 1
        add("file.close", "Close", #selector(NSWindow.performClose(_:)), "Cmd-W")
        add("file.closeWindow", "Close Window", #selector(DocumentWindowController.closeWindowAndTabs(_:)), "Cmd-Shift-W", documentsOnly: true)
        add("file.save", "Save", #selector(NSDocument.save(_:)), "Cmd-S")
        add("file.duplicate", "Duplicate", #selector(NSDocument.duplicate(_:)), "Cmd-Shift-S")
        add("file.rename", "Rename…", #selector(NSDocument.rename(_:)))
        add("file.moveTo", "Move To…", #selector(NSDocument.move(_:)))
        submenu = "Revert To"
        add("file.revertToSaved", "Last Saved Version", #selector(NSDocument.revertToSaved(_:)))
        add("file.browseVersions", "Browse All Versions…", #selector(NSDocument.browseVersions(_:)))
        // HTML export is Phase 1 of P0-14; PDF and Print (Cmd-Opt-P) arrive in Phase 2 (§6.13).
        group = 2; submenu = "Export"
        add("file.exportHTML", "HTML…", #selector(LipiDocument.exportHTML(_:)), "Cmd-Shift-E")
        submenu = nil

        category = "Edit"; group = 0
        add("edit.undo", "Undo", #selector(EditorView.undo(_:)), "Cmd-Z")
        add("edit.redo", "Redo", #selector(EditorView.redo(_:)), "Cmd-Shift-Z")
        group = 1
        add("edit.cut", "Cut", #selector(EditorView.cut(_:)), "Cmd-X")
        add("edit.copy", "Copy", #selector(EditorView.copy(_:)), "Cmd-C")
        add("edit.paste", "Paste", #selector(EditorView.paste(_:)), "Cmd-V")
        add("edit.selectAll", "Select All", #selector(NSResponder.selectAll(_:)), "Cmd-A")
        add("edit.selectBlock", "Select Block", #selector(EditorView.selectEnclosingBlock(_:)))
        group = 2; submenu = "Find"
        add("find.show", "Find…", #selector(DocumentWindowController.showFind(_:)), "Cmd-F")
        add("find.replace", "Find and Replace…", #selector(DocumentWindowController.showFindAndReplace(_:)), "Cmd-Opt-F")
        add("find.next", "Find Next", #selector(DocumentWindowController.findNextMatch(_:)), "Cmd-G")
        add("find.previous", "Find Previous", #selector(DocumentWindowController.findPreviousMatch(_:)), "Cmd-Shift-G")
        add("find.useSelection", "Use Selection for Find", #selector(DocumentWindowController.useSelectionForFind(_:)))
        submenu = nil; group = 3
        add("edit.emoji", "Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), "Cmd-Ctrl-E")

        // §6.1.5: inline marks, headings, lists and blocks.
        category = "Format"; group = 0
        editor("format.bold", #selector(EditorView.toggleStrong(_:)))
        editor("format.italic", #selector(EditorView.toggleEmphasis(_:)))
        editor("format.strikethrough", #selector(EditorView.toggleStrikethrough(_:)))
        editor("format.code", #selector(EditorView.toggleCodeSpan(_:)))
        editor("format.link", #selector(EditorView.insertLink(_:)))
        editor("format.image", #selector(EditorView.insertImage(_:)))
        editor("format.footnote", #selector(EditorView.insertFootnote(_:)))
        editor("format.showFootnote", #selector(EditorView.showFootnote(_:)))
        group = 1; submenu = "Heading"
        for (level, action) in [#selector(EditorView.setHeading1(_:)), #selector(EditorView.setHeading2(_:)), #selector(EditorView.setHeading3(_:)),
                                #selector(EditorView.setHeading4(_:)), #selector(EditorView.setHeading5(_:)), #selector(EditorView.setHeading6(_:))].enumerated() {
            editor("format.heading\(level + 1)", action)
        }
        editor("format.paragraph", #selector(EditorView.makeParagraph(_:)))
        subgroup = 1
        editor("format.promoteHeading", #selector(EditorView.promoteHeading(_:)))
        editor("format.demoteHeading", #selector(EditorView.demoteHeading(_:)))
        submenu = nil; subgroup = 0; group = 2
        editor("format.bulletList", #selector(EditorView.toggleBulletList(_:)))
        editor("format.numberedList", #selector(EditorView.toggleOrderedList(_:)))
        editor("format.taskList", #selector(EditorView.toggleTaskList(_:)))
        editor("format.toggleTask", #selector(EditorView.toggleTaskDone(_:)))
        editor("format.indent", #selector(EditorView.indentListItem(_:)))
        editor("format.outdent", #selector(EditorView.outdentListItem(_:)))
        group = 3
        editor("format.quote", #selector(EditorView.toggleBlockQuote(_:)))
        editor("format.codeBlock", #selector(EditorView.insertCodeFence(_:)))
        editor("format.mathBlock", #selector(EditorView.insertMathBlock(_:)))
        editor("format.horizontalRule", #selector(EditorView.insertThematicBreak(_:)))
        editor("format.exitBlock", #selector(EditorView.exitBlock(_:)))
        editor("format.duplicateBlock", #selector(EditorView.duplicateBlock(_:)))
        // Shift-Return is handled by the editor itself; this is its palette entry.
        add("format.hardBreak", "Hard Break", #selector(EditorView.insertHardBreak(_:)), hidden: true)

        category = "View"; group = 0
        editor("view.sourceMode", #selector(EditorView.toggleSourceMode(_:)))
        add("view.commandPalette", "Command Palette…", #selector(NSApplication.lipiShowCommandPalette(_:)), "Cmd-Shift-P")
        group = 1
        // §6.11: sidebars on Cmd-Ctrl-1…3 (files and backlinks arrive with
        // workspaces in Phase 2), Cmd-Shift-L hides or restores them.
        add("view.outline", "Outline", #selector(DocumentWindowController.toggleOutline(_:)), "Cmd-Ctrl-2", documentsOnly: true)
        add("view.toggleSidebar", "Toggle Sidebar", #selector(DocumentWindowController.toggleSidebarPanes(_:)), "Cmd-Shift-L", documentsOnly: true)
        group = 2
        add("view.focusMode", "Focus Mode", #selector(EditorView.toggleFocusMode(_:)), "F8")
        add("view.typewriterMode", "Typewriter Mode", #selector(EditorView.toggleTypewriterMode(_:)), "F9")
        add("view.zenMode", "Zen Mode", #selector(DocumentWindowController.toggleZenMode(_:)), "Cmd-Ctrl-Shift-F")
        group = 3
        add("view.zoomIn", "Zoom In", #selector(DocumentWindowController.zoomIn(_:)), "Cmd-=", "Cmd-+")
        add("view.zoomOut", "Zoom Out", #selector(DocumentWindowController.zoomOut(_:)), "Cmd--")
        add("view.actualSize", "Actual Size", #selector(DocumentWindowController.resetZoom(_:)), "Cmd-0")
        group = 4
        add("view.showTabBar", "Show Tab Bar", #selector(NSWindow.toggleTabBar(_:)))
        add("view.showAllTabs", "Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "Cmd-Shift-\\")
        group = 5
        add("view.fullScreen", "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "Cmd-Ctrl-F")

        category = "Window"; group = 0
        add("window.minimize", "Minimize", #selector(NSWindow.performMiniaturize(_:)), "Cmd-M")
        add("window.zoom", "Zoom", #selector(NSWindow.performZoom(_:)))
        group = 1
        add("window.previousTab", "Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "Ctrl-Shift-Tab")
        add("window.nextTab", "Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "Ctrl-Tab")
        add("window.moveTabToNewWindow", "Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:)))
        add("window.mergeAllWindows", "Merge All Windows", #selector(NSWindow.mergeAllWindows(_:)))
        group = 2
        add("window.bringAllToFront", "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))

        category = "Help"; group = 0
        add("help.show", "{app} Help", #selector(NSApplication.showHelp(_:)), "Cmd-?")
        return out
    }
}

// MARK: - Application-level commands

extension NSApplication {
    /// Cmd-Shift-P: the command palette (Quick Open in `>` mode).
    @objc public func lipiShowCommandPalette(_ sender: Any?) { CommandPalette.show() }
    /// Cmd-,: Settings.
    @objc public func lipiShowSettings(_ sender: Any?) { SettingsWindowController.shared.showWindow(sender) }
}

let commandLog = Logger(subsystem: "com.barelipi.app", category: "commands")
