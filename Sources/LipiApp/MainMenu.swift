import AppKit
import LipiEditor

/// The application's main menu, built in code for both hosts from the
/// `CommandRegistry` (P0-11): App, File (with Open Recent, managed by
/// `NSDocumentController`), Edit, Format, View, Window and Help. Every
/// item is a registered command sent down the responder chain, so the
/// editor, the document, the window and `NSDocumentController` validate
/// them, and its key equivalent is the command's current binding.
@MainActor
public enum MainMenu {
    public static let categories = ["App", "File", "Edit", "Format", "View", "Window", "Help"]

    private static var installed: (appName: String, documents: Bool)?
    private static var observer: NSObjectProtocol?

    /// Builds the menu, sets it as `NSApp.mainMenu` and rebuilds it when
    /// the keymap changes.
    public static func install(appName: String = "BareLipi", documents: Bool = true) {
        installed = (appName, documents)
        NSApp.mainMenu = build(appName: appName, documents: documents)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .commandBindingsDidChange, object: nil, queue: .main) { note in
                let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let installed, sender == ObjectIdentifier(CommandRegistry.shared) else { return }
                    NSApp.mainMenu = build(appName: installed.appName, documents: installed.documents)
                }
            }
        }
        KeymapStore.shared.startWatchingSoon()
    }

    /// Builds the menu and registers the Window and Help menus with `NSApp`.
    public static func build(appName: String = "BareLipi", documents: Bool = true, registry: CommandRegistry = .shared) -> NSMenu {
        let main = NSMenu(title: "Main Menu")
        var items: [String: NSMenuItem] = [:]
        for category in categories {
            let menu = NSMenu(title: category == "App" ? appName : category)
            let commands = registry.commands.filter { $0.category == category && (documents || !$0.documentsOnly) }
            var submenus: [String: NSMenu] = [:]
            var lastGroup: Int?
            var lastSubgroup: [String: Int] = [:]
            var hidden: [NSMenuItem] = []
            for command in commands {
                let keys = registry.keys(for: command.id)
                let item = makeItem(command.title(appName: appName), command.action, keys.first)
                items[command.id] = item
                let alternates = keys.dropFirst().map { chord -> NSMenuItem in
                    let alt = makeItem(command.title(appName: appName), command.action, chord)
                    alt.isHidden = true
                    alt.allowsKeyEquivalentWhenHidden = true
                    return alt
                }
                guard command.showsInMenu else {
                    item.isHidden = true
                    item.allowsKeyEquivalentWhenHidden = true
                    hidden.append(item)
                    hidden += alternates
                    continue
                }
                var target = menu
                if let name = command.submenu {
                    if let existing = submenus[name] {
                        target = existing
                    } else {
                        if let g = lastGroup, g != command.group { menu.addItem(.separator()) }
                        lastGroup = command.group
                        let sub = NSMenu(title: name)
                        submenus[name] = sub
                        menu.addItem(submenuItem(sub))
                        target = sub
                    }
                    if let g = lastSubgroup[name], g != command.subgroup { target.addItem(.separator()) }
                    lastSubgroup[name] = command.subgroup
                } else {
                    if let g = lastGroup, g != command.group { menu.addItem(.separator()) }
                    lastGroup = command.group
                }
                target.addItem(item)
                for alt in alternates { target.addItem(alt) }
            }
            for item in hidden { menu.addItem(item) }
            main.addItem(submenuItem(menu))
            switch category {
            case "App":
                // Services after Settings, as in every Mac app.
                let services = NSMenu(title: "Services")
                NSApp.servicesMenu = services
                if let settings = items["app.settings"], let at = menu.items.firstIndex(of: settings) {
                    menu.insertItem(submenuItem(services), at: at + 1)
                    menu.insertItem(.separator(), at: at + 1)
                }
            case "File" where documents:
                // NSDocumentController fills the submenu that holds clearRecentDocuments:.
                let recent = NSMenu(title: "Open Recent")
                recent.addItem(NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: ""))
                if let quick = items["file.quickOpen"], let at = menu.items.firstIndex(of: quick) {
                    menu.insertItem(submenuItem(recent), at: at + 1)
                }
            case "Window":
                NSApp.windowsMenu = menu
            case "Help":
                NSApp.helpMenu = menu
            default: break
            }
        }
        registry.menuItems = items
        return main
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func makeItem(_ title: String, _ action: Selector, _ chord: KeyChord?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: chord?.key ?? "")
        if let chord {
            var mask = chord.modifiers
            if chord.isFunctionKey { mask.insert(.function) }
            item.keyEquivalentModifierMask = mask
        }
        return item
    }
}
