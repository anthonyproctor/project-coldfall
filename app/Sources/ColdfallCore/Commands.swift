import Foundation

/// The command palette: every menu command, findable by typing.
///
/// The commands are the app's own menus, read when the palette opens, so a
/// new menu item is in the palette without anyone listing it twice, and the
/// palette can't offer something the menus wouldn't. This holds the parts
/// worth testing: how a shortcut is written, and which menu items count.
public enum Commands {

    /// One command, as read from the menus.
    public struct Entry: Equatable {
        /// "Desk", "Stop Desk…": the menu, then the item.
        public var path: [String]
        /// The key equivalent as AppKit stores it ("p", "\r", an arrow).
        public var key: String
        /// AppKit's modifier mask, as raw bits (see `Mods`).
        public var modifiers: UInt
        public var enabled: Bool
        public init(path: [String], key: String, modifiers: UInt, enabled: Bool = true) {
            self.path = path; self.key = key; self.modifiers = modifiers; self.enabled = enabled
        }
        public var title: String { path.last ?? "" }
        /// What the fuzzy match looks at: "Desk Stop Desk".
        public var searchKey: String { path.joined(separator: " ").replacingOccurrences(of: "…", with: "") }
        public var shortcut: String { Commands.shortcut(key: key, modifiers: modifiers) }
    }

    /// NSEvent.ModifierFlags bits, so the core can read them without AppKit.
    public enum Mods {
        public static let shift: UInt = 1 << 17
        public static let control: UInt = 1 << 18
        public static let option: UInt = 1 << 19
        public static let command: UInt = 1 << 20
    }

    /// "⌘⇧P", in the order macOS menus write them: ⌃ ⌥ ⇧ ⌘, then the key.
    public static func shortcut(key: String, modifiers: UInt) -> String {
        guard !key.isEmpty else { return "" }
        var s = ""
        if modifiers & Mods.control != 0 { s += "⌃" }
        if modifiers & Mods.option != 0 { s += "⌥" }
        // An upper-case key equivalent means Shift, as AppKit reads it.
        let upper = key.count == 1 && key.uppercased() == key && key.lowercased() != key
        if modifiers & Mods.shift != 0 || upper { s += "⇧" }
        if modifiers & Mods.command != 0 { s += "⌘" }
        return s + keyName(key)
    }

    static func keyName(_ k: String) -> String {
        switch k {
        case "\r": return "↩"
        case "\u{1b}": return "⎋"
        case "\t": return "⇥"
        case " ": return "Space"
        case "\u{8}", "\u{7f}": return "⌫"
        case "\u{F700}": return "↑"
        case "\u{F701}": return "↓"
        case "\u{F702}": return "←"
        case "\u{F703}": return "→"
        default: return k.uppercased()
        }
    }

    /// Whether quick open is being asked for commands: it starts with ">".
    /// Returns the query without it.
    public static func commandQuery(_ q: String) -> String? {
        guard q.hasPrefix(">") else { return nil }
        return String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// The menus a palette shouldn't offer: the system's own lists.
    static let skippedMenus: Set<String> = ["Services", "Open Recent"]

    /// Which entries to offer, in menu order, enabled ones only, and each
    /// title once (a command in two menus is one command).
    public static func offer(_ entries: [Entry]) -> [Entry] {
        var seen = Set<String>()
        return entries.filter { e in
            guard e.enabled, !e.title.isEmpty, !e.path.contains(where: skippedMenus.contains) else { return false }
            return seen.insert(e.title).inserted
        }
    }
}
