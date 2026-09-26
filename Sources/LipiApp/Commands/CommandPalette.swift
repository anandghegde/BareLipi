import AppKit

/// The command palette (P0-11, Cmd-Shift-P): Quick Open's panel in `>`
/// mode. Rows are the registry's enabled commands with their current
/// shortcuts; matching is fuzzy on the title, then the id, then the menu
/// path; recently run commands come first and are boosted while typing.
@MainActor
public enum CommandPalette {
    /// Defaults key: the ids of the last commands run from the palette,
    /// most recent first.
    public static let historyKey = "RecentCommands"
    public static let historyLimit = 12

    /// Palette rows for `registry`. `enabled` limits them to those ids
    /// (nil: every command); `history` orders recent ones first.
    public static func items(registry: CommandRegistry, appName: String = "BareLipi", enabled: Set<String>?,
                             history: [String] = [], documents: Bool = true) -> [QuickOpenItem] {
        var out: [QuickOpenItem] = []
        for command in registry.commands where documents || !command.documentsOnly {
            if let enabled, !enabled.contains(command.id) { continue }
            let title = command.title(appName: appName).replacingOccurrences(of: "…", with: "")
            let shortcut = registry.keys(for: command.id).first?.glyphs ?? ""
            out.append(QuickOpenItem(kind: .command(id: command.id), title: title, subtitle: command.path(appName: appName),
                                     recency: history.firstIndex(of: command.id), shortcut: shortcut, keywords: command.id))
        }
        return out
    }

    public static func history(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: historyKey) ?? []
    }

    public static func record(_ id: String, _ defaults: UserDefaults = .standard) {
        var list = history(defaults).filter { $0 != id }
        list.insert(id, at: 0)
        defaults.set(Array(list.prefix(historyLimit)), forKey: historyKey)
    }

    /// Shows Quick Open with `>` typed.
    public static func show() { QuickOpen.show(prefix: ">") }
}
