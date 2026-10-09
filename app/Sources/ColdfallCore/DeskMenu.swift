// What the right-click menu on a desk offers.
//
// The shape of this menu is a safety question, not a layout one. "Stop Desk"
// and "Remove Desk" sat next to each other as two plain lines of text, one
// above the other, and the dangerous one was the easiest to hit: last in the
// list, where the pointer ends up. Stopping a desk ends its processes and it
// comes back; removing it takes it out of desks.toml. Those deserve to look
// different, so each entry carries a tone, an icon and a line saying what it
// does, and the destructive one is kept apart from everything else.
//
// The model lives here so it can be tested. The app turns it into an NSMenu.

import Foundation

public enum DeskMenu {

    public enum Tone: Equatable {
        case normal
        /// Reversible, but it interrupts something: ends processes.
        case caution
        /// Changes the desk list itself.
        case danger
    }

    public enum Action: String, Equatable {
        case reveal, makeDefault, rename, inventory, mcp, askResume, stop, pin, unpin, hide, unhide, remove, separator
    }

    public struct Entry: Equatable {
        public let action: Action
        public let title: String
        /// The line underneath, on the systems that show one.
        public let subtitle: String?
        /// SF Symbol name, or nil for no icon.
        public let symbol: String?
        public let tone: Tone
        /// A checkmark, for an entry that is a setting.
        public let checked: Bool?
        public init(_ action: Action, _ title: String, subtitle: String? = nil,
                    symbol: String? = nil, tone: Tone = .normal, checked: Bool? = nil) {
            self.action = action; self.title = title
            self.subtitle = subtitle; self.symbol = symbol; self.tone = tone; self.checked = checked
        }
        public static let separator = Entry(.separator, "")
    }

    /// The menu for one desk.
    /// `askResume`: whether opening this desk asks about starting fresh, or
    /// nil where that doesn't apply (it can't be started fresh).
    /// `pinned`: whether the desk is pinned to the top of the rail, or nil
    /// where pinning isn't offered.
    public static func items(runtime: String, running: Bool, hidden: Bool,
                             canReveal: Bool, canMakeDefault: Bool,
                             hasInventory: Bool, hasMcp: Bool, askResume: Bool? = nil,
                             pinned: Bool? = nil, news: Int = 0) -> [Entry] {
        var out: [Entry] = []
        // Something new on the desk: the entry that shows it, and clears the
        // "new" on the row, goes first, saying so. It used to sit mid-menu
        // under a plain name, and the row's "2 new" was orange, the colour of
        // Stop Desk, so nothing said where to go.
        if hasInventory, news > 0 {
            out.append(Entry(.inventory, "See What's New on This Desk (\(news))…",
                             subtitle: "Opens What This Desk Has. Looking clears the \u{201C}\(news) new\u{201D} on the desk.",
                             symbol: "sparkles"))
            out.append(.separator)
        }
        if canReveal {
            out.append(Entry(.reveal, "Reveal Agent Definition", symbol: "doc.text.magnifyingglass"))
            out.append(.separator)
        }
        if canMakeDefault {
            out.append(Entry(.makeDefault, "Make this the \(runtime) home", symbol: "house"))
            out.append(.separator)
        }
        out.append(Entry(.rename, "Rename Desk…", symbol: "pencil"))
        if hasInventory, news == 0 {
            out.append(Entry(.inventory, "What This Desk Has…", symbol: "list.bullet.rectangle"))
        }
        if hasMcp {
            out.append(Entry(.mcp, "MCP Servers…", symbol: "switch.2"))
        }
        if let ask = askResume {
            out.append(Entry(.askResume, "Ask Before Reopening a Big Conversation",
                             subtitle: "Offers a clean start when a big conversation has sat for an hour. "
                                     + "Off means it always picks up where you left off.",
                             checked: ask))
        }
        if running {
            out.append(.separator)
            out.append(Entry(.stop, "Stop Desk…",
                             subtitle: "Ends its processes and frees their memory. Click the desk to start it again.",
                             symbol: "stop.circle.fill", tone: .caution))
        }
        out.append(.separator)
        // Pinning a hidden desk would show nothing, so it isn't offered there.
        if !hidden, let pinned {
            out.append(pinned
                ? Entry(.unpin, "Unpin from Top", symbol: "pin.slash")
                : Entry(.pin, "Pin to Top",
                        subtitle: "Keeps it at the top of the rail, above everything else.",
                        symbol: "pin"))
        }
        if !hidden {
            out.append(Entry(.hide, "Hide Desk",
                             subtitle: "Out of the rail, but kept. Unhide it from the bottom of the rail.",
                             symbol: "eye.slash"))
        } else {
            out.append(Entry(.unhide, "Unhide Desk", symbol: "eye"))
        }
        // On its own, at the end, after a separator of its own: this is the
        // one that changes the desk list.
        out.append(.separator)
        out.append(Entry(.remove, "Remove Desk…",
                         subtitle: "Takes it out of desks.toml. Its conversation and files stay.",
                         symbol: "trash", tone: .danger))
        return out
    }

    /// No two lines next to each other that both end a desk, and nothing
    /// destructive without a separator above it. Checked by the tests rather
    /// than by eye, because this is the part that gets edited by accident.
    public static func destructiveIsIsolated(_ items: [Entry]) -> Bool {
        for (i, e) in items.enumerated() where e.tone == .danger {
            guard i > 0, items[i - 1].action == .separator else { return false }
            if i + 1 < items.count, items[i + 1].tone != .normal { return false }
        }
        return true
    }
}
