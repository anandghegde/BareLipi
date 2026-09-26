import AppKit
import LipiEditor

/// The application's main menu, built in code for both hosts: App, File
/// (with Open Recent, managed by `NSDocumentController`), Edit, Format, View,
/// Window and Help. Every item is a first-responder action, so the editor,
/// the document, the window and `NSDocumentController` validate them.
@MainActor
public enum MainMenu {
    /// Builds the menu and registers the Window and Help menus with `NSApp`.
    public static func build(appName: String = "BareLipi", documents: Bool = true) -> NSMenu {
        let main = NSMenu(title: "Main Menu")
        main.addItem(submenu(appMenu(appName)))
        main.addItem(submenu(fileMenu(documents: documents)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(formatMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        let help = NSMenu(title: "Help")
        help.addItem(item("\(appName) Help", #selector(NSApplication.showHelp(_:)), "?"))
        main.addItem(submenu(help))
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func functionKey(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt16(key))!))
    }

    private static func appMenu(_ name: String) -> NSMenu {
        let menu = NSMenu(title: name)
        menu.addItem(item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        // Settings… (Cmd-,) arrives with the SwiftUI Settings scene (ADR-010).
        let services = NSMenu(title: "Services")
        let servicesItem = item("Services", nil)
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu(documents: Bool) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item("New Tab", #selector(NSResponder.newWindowForTab(_:)), "t"))
        menu.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        if documents {
            menu.addItem(item("Quick Open…", #selector(LipiDocumentController.showQuickOpen(_:)), "p"))
            // NSDocumentController fills the submenu that holds clearRecentDocuments:.
            let recent = NSMenu(title: "Open Recent")
            recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
            let recentItem = item("Open Recent", nil)
            recentItem.submenu = recent
            menu.addItem(recentItem)
        }
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save", #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item("Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        menu.addItem(item("Rename…", #selector(NSDocument.rename(_:))))
        menu.addItem(item("Move To…", #selector(NSDocument.move(_:))))
        let revert = NSMenu(title: "Revert To")
        revert.addItem(item("Last Saved Version", #selector(NSDocument.revertToSaved(_:))))
        revert.addItem(item("Browse All Versions…", #selector(NSDocument.browseVersions(_:))))
        let revertItem = item("Revert To", nil)
        revertItem.submenu = revert
        menu.addItem(revertItem)
        menu.addItem(.separator())
        // HTML export is Phase 1 of P0-14; PDF and Print arrive in Phase 2 (§6.13).
        let export = NSMenu(title: "Export")
        export.addItem(item("HTML…", #selector(LipiDocument.exportHTML(_:)), "e", [.command, .shift]))
        let exportItem = item("Export", nil)
        exportItem.submenu = export
        menu.addItem(exportItem)
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", #selector(EditorView.undo(_:)), "z"))
        menu.addItem(item("Redo", #selector(EditorView.redo(_:)), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(EditorView.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(EditorView.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(EditorView.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        menu.addItem(.separator())
        // Find (P0-10): the window's find bar. Formatting commands live in
        // the Format menu.
        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(DocumentWindowController.showFind(_:)), "f"))
        find.addItem(item("Find and Replace…", #selector(DocumentWindowController.showFindAndReplace(_:)), "f", [.command, .option]))
        find.addItem(item("Find Next", #selector(DocumentWindowController.findNextMatch(_:)), "g"))
        find.addItem(item("Find Previous", #selector(DocumentWindowController.findPreviousMatch(_:)), "g", [.command, .shift]))
        find.addItem(item("Use Selection for Find", #selector(DocumentWindowController.useSelectionForFind(_:))))
        menu.addItem(submenu(find))
        menu.addItem(.separator())
        menu.addItem(item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), "e", [.command, .control]))
        return menu
    }

    /// Every §6.1.5 command, in the order of `EditorView.keyEquivalents`,
    /// grouped as inline marks, headings, lists and blocks. Titles, keys
    /// and actions come from the editor so the menu and the key handler
    /// can never disagree.
    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        let inline: [Selector] = [
            #selector(EditorView.toggleStrong(_:)), #selector(EditorView.toggleEmphasis(_:)),
            #selector(EditorView.toggleStrikethrough(_:)), #selector(EditorView.toggleCodeSpan(_:)),
            #selector(EditorView.insertLink(_:)), #selector(EditorView.insertImage(_:)),
            #selector(EditorView.insertFootnote(_:)),
        ]
        let headings: [Selector] = [
            #selector(EditorView.setHeading1(_:)), #selector(EditorView.setHeading2(_:)), #selector(EditorView.setHeading3(_:)),
            #selector(EditorView.setHeading4(_:)), #selector(EditorView.setHeading5(_:)), #selector(EditorView.setHeading6(_:)),
            #selector(EditorView.makeParagraph(_:)),
        ]
        let headingLevels: [Selector] = [#selector(EditorView.promoteHeading(_:)), #selector(EditorView.demoteHeading(_:))]
        let lists: [Selector] = [
            #selector(EditorView.toggleBulletList(_:)), #selector(EditorView.toggleOrderedList(_:)),
            #selector(EditorView.toggleTaskList(_:)), #selector(EditorView.toggleTaskDone(_:)),
            #selector(EditorView.indentListItem(_:)), #selector(EditorView.outdentListItem(_:)),
        ]
        let blocks: [Selector] = [
            #selector(EditorView.toggleBlockQuote(_:)), #selector(EditorView.insertCodeFence(_:)),
            #selector(EditorView.insertMathBlock(_:)), #selector(EditorView.insertThematicBreak(_:)),
            #selector(EditorView.exitBlock(_:)), #selector(EditorView.duplicateBlock(_:)),
        ]
        for action in inline { menu.addItem(editorItem(action)) }
        menu.addItem(.separator())
        let heading = NSMenu(title: "Heading")
        for action in headings { heading.addItem(editorItem(action)) }
        heading.addItem(.separator())
        for action in headingLevels { heading.addItem(editorItem(action)) }
        menu.addItem(submenu(heading))
        menu.addItem(.separator())
        for action in lists { menu.addItem(editorItem(action)) }
        menu.addItem(.separator())
        for action in blocks { menu.addItem(editorItem(action)) }
        return menu
    }

    /// The menu item for one `EditorView` action, titled and keyed from
    /// `EditorView.keyEquivalents`.
    private static func editorItem(_ action: Selector) -> NSMenuItem {
        guard let binding = EditorView.keyEquivalents.first(where: { $0.action == action }) else {
            preconditionFailure("no key equivalent for \(action)")
        }
        return item(binding.title, binding.action, binding.key, binding.modifiers)
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(editorItem(#selector(EditorView.toggleSourceMode(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Outline", #selector(DocumentWindowController.toggleOutline(_:)), "2", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Focus Mode", #selector(EditorView.toggleFocusMode(_:)), functionKey(NSF8FunctionKey), [.function]))
        menu.addItem(item("Typewriter Mode", #selector(EditorView.toggleTypewriterMode(_:)), functionKey(NSF9FunctionKey), [.function]))
        menu.addItem(item("Zen Mode", #selector(DocumentWindowController.toggleZenMode(_:)), "f", [.command, .control, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Zoom In", #selector(DocumentWindowController.zoomIn(_:)), "="))
        let zoomInPlus = item("Zoom In", #selector(DocumentWindowController.zoomIn(_:)), "+")
        zoomInPlus.isHidden = true
        zoomInPlus.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInPlus)
        menu.addItem(item("Zoom Out", #selector(DocumentWindowController.zoomOut(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(DocumentWindowController.resetZoom(_:)), "0"))
        menu.addItem(.separator())
        // Reveal presets go here when EditorView implements them.
        menu.addItem(item("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:))))
        menu.addItem(item("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift]))
        menu.addItem(item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", .control))
        menu.addItem(item("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:))))
        menu.addItem(item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
