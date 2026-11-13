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

/// Your own shortcuts: `~/.config/coldfall/keys.json`, a menu command's name
/// to a shortcut, or "none" to take one away.
///
///     { "Run a Command…": "cmd+k", "Show or Hide Rail": "none" }
///
/// Names are matched without case and without the trailing "…", so "run a
/// command" works too. A shortcut you give a command is taken from whatever
/// command had it, so one key never means two things.
public enum KeyMap {
    public static var path: String {
        (Limits.configDir as NSString).appendingPathComponent("keys.json")
    }

    public struct Shortcut: Equatable, Hashable {
        /// As AppKit's keyEquivalent wants it: lower case, or a special key.
        public var key: String
        public var modifiers: UInt
        public init(key: String, modifiers: UInt) { self.key = key; self.modifiers = modifiers }
        public static let none = Shortcut(key: "", modifiers: 0)
        public var label: String { Commands.shortcut(key: key, modifiers: modifiers) }
    }

    public struct Map: Equatable {
        /// By normalised command name.
        public var shortcuts: [String: Shortcut]
        public var problems: [String]
    }

    public static func normal(_ title: String) -> String {
        title.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    static let named: [String: String] = [
        "return": "\r", "enter": "\r", "esc": "\u{1b}", "escape": "\u{1b}", "tab": "\t", "space": " ",
        "delete": "\u{8}", "backspace": "\u{8}",
        "up": "\u{F700}", "down": "\u{F701}", "left": "\u{F702}", "right": "\u{F703}",
    ]

    /// "cmd+shift+k" → ⇧⌘K. Nil when it isn't one.
    public static func parse(shortcut s: String) -> Shortcut? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "none" || t.isEmpty { return Shortcut.none }
        var mods: UInt = 0
        var key: String?
        for part in t.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": mods |= Commands.Mods.command
            case "shift", "⇧": mods |= Commands.Mods.shift
            case "opt", "option", "alt", "⌥": mods |= Commands.Mods.option
            case "ctrl", "control", "⌃": mods |= Commands.Mods.control
            default:
                guard key == nil else { return nil }        // two keys
                if let n = named[part] { key = n }
                else if part.count == 1 { key = part }
                else { return nil }
            }
        }
        // A bare letter would steal typing from the terminal.
        guard let k = key, mods & (Commands.Mods.command | Commands.Mods.control) != 0 else { return nil }
        return Shortcut(key: k, modifiers: mods)
    }

    public static func parse(json text: String) -> Map {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Map(shortcuts: [:], problems: ["keys.json isn't a JSON object of command names to shortcuts."])
        }
        var out: [String: Shortcut] = [:], problems: [String] = [], used: [Shortcut: String] = [:]
        for (name, v) in obj.sorted(by: { $0.key < $1.key }) {
            guard let s = v as? String, let sc = parse(shortcut: s) else {
                problems.append("\u{201C}\(name)\u{201D}: \u{201C}\(v)\u{201D} isn't a shortcut Coldfall can use. Try \u{201C}cmd+shift+k\u{201D}; it needs ⌘ or ⌃.")
                continue
            }
            if sc != .none, let other = used[sc] {
                problems.append("\(sc.label) is given to both \u{201C}\(other)\u{201D} and \u{201C}\(name)\u{201D}; kept for \u{201C}\(other)\u{201D}.")
                continue
            }
            if sc != .none { used[sc] = name }
            out[normal(name)] = sc
        }
        return Map(shortcuts: out, problems: problems)
    }

    public static func load(path: String = KeyMap.path) -> Map? {
        guard let t = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(json: t)
    }
}
