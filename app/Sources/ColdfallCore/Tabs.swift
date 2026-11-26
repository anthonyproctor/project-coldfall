import Foundation

/// The tab row over the terminal: every running desk, whatever group it is
/// in. A tab is how you get back to an agent you started, and "which group
/// was it in" should not stand between you and it.
///
/// (It used to hold only the running desks of the current desk's group,
/// the way Herdr shows the agents of the space you are in. A desk running
/// in another group then had no tab, which read as the desk being gone.)
///
/// A desk on screen always has a tab, running or not, so you can see where
/// you are. Hidden desks get none unless they are on screen. Order is the
/// rail's own, groups together, so tabs never shuffle as desks change
/// state or as you move between them. Nothing on screen yet, no tabs.
public enum DeskTabs {
    public static func list(_ desks: [Desk], current: String?, running: Set<String>, onScreen: [String] = []) -> [String] {
        guard let cur = current, desks.contains(where: { $0.name == cur }) else { return [] }
        return desks.filter { d in
            d.name == cur || onScreen.contains(d.name) || (running.contains(d.name) && !d.hidden)
        }.map(\.name)
    }

    /// The tabs that fit, and the ones that don't (shown in a "more" menu).
    /// The first `room` in order, except that the desk on screen always
    /// has a tab: if it falls past the edge it takes the last place.
    public static func fit(_ names: [String], current: String?, room: Int) -> (shown: [String], more: [String]) {
        guard room > 0 else { return ([], names) }
        guard names.count > room else { return (names, []) }
        var shown = Array(names.prefix(room))
        if let c = current, names.contains(c), !shown.contains(c) { shown[room - 1] = c }
        return (shown, names.filter { !shown.contains($0) })
    }

    /// The desks in this group that are not running, for the "+" menu.
    public static func startable(_ desks: [Desk], current: String?, running: Set<String>) -> [String] {
        guard let cur = current, let here = desks.first(where: { $0.name == cur }) else { return [] }
        return desks.filter { $0.group == here.group && !running.contains($0.name) && !$0.hidden && $0.name != cur }
            .map(\.name)
    }
}

/// How the Desks section is ordered. The button beside "Desks" steps
/// through them.
public enum DeskListMode: String, CaseIterable {
    /// The desks of one group, in your order.
    case group
    /// Every running desk, by what it needs from you.
    case priority
    /// Every desk there is, by name: for finding one.
    case all

    /// The "All desks" list as drawn: the running ones, then the rest.
    public struct AllSections: Equatable {
        public var running: [String], rest: [String]
    }

    /// Every desk in the "All desks" list, the ones in use first.
    ///
    /// Running desks lead, by name. Then the rest: the ones used most
    /// recently first (`lastUsed`, where Coldfall knows it), then the ones
    /// it has no time for, by name. So the desk you had open yesterday is
    /// near the top and one you last touched in March is at the bottom,
    /// without a running desk changing places every time it prints. Hidden
    /// desks stay under Hidden, and pinned ones are already at the top.
    public static func all(_ desks: [Desk], running: Set<String>, lastUsed: [String: Date]) -> AllSections {
        let names = byName(desks)
        let rest = names.filter { !running.contains($0) }
        let dated = rest.filter { lastUsed[$0] != nil }
            .sorted { (lastUsed[$0] ?? .distantPast) > (lastUsed[$1] ?? .distantPast) }   // stable: ties keep name order
        return AllSections(running: names.filter { running.contains($0) },
                           rest: dated + rest.filter { lastUsed[$0] == nil })
    }

    public var next: DeskListMode {
        switch self { case .group: return .priority; case .priority: return .all; case .all: return .group }
    }
    public var title: String {
        switch self { case .group: return "By group"; case .priority: return "By priority"; case .all: return "All desks" }
    }
    public var tip: String {
        switch self {
        case .group: return "One group's desks. Click to list every running desk, most urgent first."
        case .priority: return "Every running desk, most urgent first. Click to list every desk by name."
        case .all: return "Every desk: running ones first, then the ones you used last. Click to list one group instead."
        }
    }

    /// As saved: two switches, so a build from before "All desks" reads
    /// the file as it always did.
    public init(byPriority: Bool, all: Bool) { self = all ? .all : (byPriority ? .priority : .group) }

    /// Every desk in the "All desks" list: by name, ignoring case, numbers
    /// in order ("desk2" before "desk10"). Hidden desks stay under Hidden,
    /// and pinned ones are already at the top of the section.
    public static func byName(_ desks: [Desk]) -> [String] {
        desks.filter { !$0.hidden && !$0.pinned }.map(\.name)
            .sorted { $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending }
    }
}

/// Which group the desk list shows.
///
/// It follows the desk you are in, until you click another group: that is a
/// look at what is there, and changes nothing on screen. The list goes back
/// to following when you go to a different desk. (Clicking a group used to
/// take you to a desk in it, which took the desk you were in off the screen
/// when all you wanted was to find another one.)
public enum GroupOnShow {
    /// `browsing` is the group clicked (nil when none was), `selected` the
    /// group of the desk you are in (nil when there is no such desk), and
    /// `first` the first group with a desk in it. The inner optional is the
    /// group's own name: nil there is the General group.
    public static func group(browsing: String??, selected: String??, first: String??) -> String?? {
        browsing ?? selected ?? first
    }

    /// The look lasts until you go to a different desk. Selecting the same
    /// desk again (a reload, a re-sort) is not that.
    public static func browsing(_ browsing: String??, afterSelecting desk: String?, was: String?) -> String?? {
        desk == was ? browsing : nil
    }
}

/// The desks on screen side by side: one to twelve, in a grid. One of them
/// has the keys; the desk list and the tabs act on that one.
public enum DeskGrid {
    /// Twelve terminals is already more than a screen reads; past it they
    /// are too small to type in.
    public static let most = 12

    public enum Placement: Equatable {
        /// Already on screen, in this place: go to it.
        case focus(Int)
        /// Not on screen: it takes the place of the desk that has the keys.
        case replace(Int)
    }

    /// After choosing `name` in the desk list or the tabs. A desk is on
    /// screen once at most, so choosing one that is there moves the keys to
    /// it; any other takes the place of the one you are in.
    public static func place(_ name: String, onScreen: [String], key: Int) -> Placement {
        if let i = onScreen.firstIndex(of: name) { return .focus(i) }
        return .replace(min(max(key, 0), max(onScreen.count - 1, 0)))
    }

    /// Whether one more desk fits, and is not on screen already.
    public static func canAdd(_ name: String, onScreen: [String]) -> Bool {
        !onScreen.isEmpty && onScreen.count < most && !onScreen.contains(name)
    }

    /// Which place has the keys once the desk at `index` is taken off: the
    /// same desk as before, or, when it was that one, its left neighbour.
    public static func keyAfterRemoving(_ index: Int, key: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        if index < key { return key - 1 }
        if index == key { return max(0, min(key - 1, count - 2)) }
        return key
    }

    /// How many rows and columns `count` desks take: one row up to three,
    /// two rows up to eight, three after that.
    public static func shape(_ count: Int) -> (rows: Int, cols: Int) {
        guard count > 0 else { return (0, 0) }
        let rows = count <= 3 ? 1 : (count <= 8 ? 2 : 3)
        return (rows, Int((Double(count) / Double(rows)).rounded(.up)))
    }

    /// Where each desk goes, top row first, y measured from the top. A last
    /// row that is short shares the whole width. Two desks split at `split`
    /// (the first one's share), kept at least `minWidth` each where there is
    /// room for that.
    public static func frames(count: Int, width: Double, height: Double,
                              split: Double = 0.5, minWidth: Double = 260) -> [CGRect] {
        guard count > 0 else { return [] }
        if count == 1 { return [rect(0, 0, width, height)] }
        if count == 2 {
            let lo = min(minWidth, width / 2), hi = max(width - minWidth, width / 2)
            let x = min(max((width * split).rounded(), lo), hi)
            return [rect(0, 0, x, height), rect(x, 0, width - x, height)]
        }
        let (rows, cols) = shape(count)
        var out: [CGRect] = []
        for r in 0..<rows {
            let inRow = r == rows - 1 ? count - cols * (rows - 1) : cols
            let y0 = (height * Double(r) / Double(rows)).rounded(), y1 = (height * Double(r + 1) / Double(rows)).rounded()
            for c in 0..<inRow {
                let x0 = (width * Double(c) / Double(inRow)).rounded(), x1 = (width * Double(c + 1) / Double(inRow)).rounded()
                out.append(rect(x0, y0, x1 - x0, y1 - y0))
            }
        }
        return out
    }

    private static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(origin: CGPoint(x: CGFloat(x), y: CGFloat(y)), size: CGSize(width: CGFloat(w), height: CGFloat(h)))
    }

    /// One line of the Desks menu's Open Beside list.
    public struct Choice: Equatable {
        public var name: String, group: String?, running: Bool
        public init(name: String, group: String?, running: Bool) {
            self.name = name; self.group = group; self.running = running
        }
        public var title: String { group.map { "\(name)  ·  \($0)" } ?? name }
    }

    /// Every desk that can go beside the ones on screen, whatever group the
    /// list is showing: running ones first, then the rest, each in the order
    /// given. Not one already on screen, not hidden ones. Empty when nothing
    /// is on screen to be beside, or the screen is full.
    public static func choices(_ desks: [(name: String, group: String?, running: Bool, hidden: Bool)],
                               onScreen: [String]) -> [Choice] {
        guard !onScreen.isEmpty, onScreen.count < most else { return [] }
        let ok = desks.filter { !$0.hidden && !onScreen.contains($0.name) }
            .map { Choice(name: $0.name, group: $0.group, running: $0.running) }
        return ok.filter(\.running) + ok.filter { !$0.running }
    }
}

/// The counts along the status bar: "1 needs you · 2 working · 3 done".
public struct DeskCounts: Equatable {
    public var needsYou = 0, working = 0, done = 0
    public init(needsYou: Int = 0, working: Int = 0, done: Int = 0) {
        self.needsYou = needsYou; self.working = working; self.done = done
    }

    public static func of(_ activity: [DeskActivity]) -> DeskCounts {
        var c = DeskCounts()
        for a in activity {
            switch a {
            case .blocked: c.needsYou += 1
            case .working: c.working += 1
            case .ready: c.done += 1
            case .quiet: break
            }
        }
        return c
    }

    /// The chips to show, in order; a zero count shows nothing.
    public var chips: [String] {
        var out: [String] = []
        if needsYou > 0 { out.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
        if working > 0 { out.append("\(working) working") }
        if done > 0 { out.append("\(done) done") }
        return out
    }
}

/// A set of tabs kept together under a coloured label, the way a browser
/// groups tabs. It is about the tab row only: a desk's group in the desk
/// list (desks.toml) is something else, and stays as it is.
public struct TabGroup: Codable, Equatable {
    public var name: String
    /// A name from DeskColor.palette.
    public var color: String
    public var desks: [String]
    /// Folded to its label: its tabs are put away until you click it.
    public var collapsed: Bool
    public init(name: String, color: String, desks: [String], collapsed: Bool = false) {
        self.name = name; self.color = color; self.desks = desks; self.collapsed = collapsed
    }
}

/// Your own arrangement of the tab row: the order you dragged tabs into, and
/// the groups you made. Empty, the row is in the desk list's order, as it
/// was before tabs could be moved.
public struct TabLayout: Codable, Equatable {
    public var order: [String] = []
    public var groups: [TabGroup] = []
    public init(order: [String] = [], groups: [TabGroup] = []) { self.order = order; self.groups = groups }

    /// One thing in the row.
    public enum Item: Equatable {
        /// A tab, and the group it is in (an index into `groups`).
        case tab(String, group: Int?)
        /// A group's label, with how many of its tabs are put away.
        case label(group: Int, hidden: Int)
    }

    public func group(of desk: String) -> Int? { groups.firstIndex { $0.desks.contains(desk) } }

    /// `names` (the tabs there are, in the desk list's order) in your order.
    /// A tab you never placed sits after the one before it in the desk
    /// list, so a desk just started turns up where it always would have.
    public func ordered(_ names: [String]) -> [String] {
        var out = order.filter(names.contains)
        for (i, n) in names.enumerated() where !out.contains(n) {
            if let before = names[..<i].last(where: out.contains), let at = out.firstIndex(of: before) {
                out.insert(n, at: at + 1)
            } else {
                out.insert(n, at: 0)
            }
        }
        return out
    }

    /// The row as drawn: tabs in your order, each group's tabs together
    /// behind its label, where the first of them stands. A collapsed group
    /// shows only its label, plus any tab that can't be put away: the desk
    /// on screen, and one that needs you.
    public func arrange(_ names: [String], current: String?, asking: Set<String> = []) -> [Item] {
        let sorted = ordered(names)
        var out: [Item] = []
        var done = Set<Int>()
        for n in sorted {
            guard let g = group(of: n) else { out.append(.tab(n, group: nil)); continue }
            guard !done.contains(g) else { continue }
            done.insert(g)
            let members = sorted.filter { groups[g].desks.contains($0) }
            let shown = groups[g].collapsed ? members.filter { $0 == current || asking.contains($0) } : members
            out.append(.label(group: g, hidden: members.count - shown.count))
            out += shown.map { .tab($0, group: g) }
        }
        return out
    }

    /// The tabs of an arrangement, in order.
    public static func tabs(_ items: [Item]) -> [String] {
        items.compactMap { if case .tab(let n, _) = $0 { return n } else { return nil } }
    }

    /// Drop `name` in front of `before` (nil: at the end). `shown` is the
    /// row's tabs as drawn, and `into` the group the pointer was over when
    /// it let go (its label and its tabs), if any. Between two tabs of one
    /// group the tab joins that group, wherever the pointer was. At a
    /// group's edge it joins when it was let go over the group, and
    /// otherwise lands outside: that is how a tab is dragged out.
    public mutating func move(_ name: String, before: String?, shown: [String], into: Int? = nil) {
        guard shown.contains(name), before != name else { return }
        var row = shown.filter { $0 != name }
        let at = before.flatMap(row.firstIndex(of:)) ?? row.count
        row.insert(name, at: at)
        let left = at > 0 ? group(of: row[at - 1]) : nil
        let right = at + 1 < row.count ? group(of: row[at + 1]) : nil
        let own = group(of: name)
        let target: Int?
        if let l = left, l == right { target = l }
        else if let g = into, g == left || g == right { target = g }
        else { target = nil }
        if target != own {
            if let o = own { groups[o].desks.removeAll { $0 == name } }
            if let t = target { groups[t].desks.append(name) }
        }
        remember(row)
        dropEmpty()
    }

    /// Keep `row` as the order, with the tabs that aren't showing now left
    /// where they stood: each after whatever came before it.
    mutating func remember(_ row: [String]) {
        var out = row
        for (i, n) in order.enumerated() where !out.contains(n) {
            if i > 0, let at = out.firstIndex(of: order[i - 1]) { out.insert(n, at: at + 1) }
            else { out.insert(n, at: 0) }
        }
        order = out
    }

    mutating func dropEmpty() { groups.removeAll { $0.desks.isEmpty } }

    /// The first palette colour no group is using, or the first of all.
    public var nextColor: String {
        let used = Set(groups.map(\.color))
        return DeskColor.palette.map(\.name).first { !used.contains($0) } ?? DeskColor.palette[0].name
    }

    /// A new group holding `desk`, taken out of any group it was in. The
    /// tab stays where it is; it gains a label.
    public mutating func newGroup(named name: String, with desk: String) {
        let color = nextColor
        for i in groups.indices { groups[i].desks.removeAll { $0 == desk } }
        groups.append(TabGroup(name: TabLayout.clean(name), color: color, desks: [desk]))
        dropEmpty()
    }

    /// Put `desk` in the group at `index`, after its other tabs.
    public mutating func add(_ desk: String, to index: Int, shown: [String]) {
        guard groups.indices.contains(index), !groups[index].desks.contains(desk) else { return }
        for i in groups.indices { groups[i].desks.removeAll { $0 == desk } }
        // Stand it after the group's last tab in the row.
        var row = ordered(shown).filter { $0 != desk }
        if let last = row.last(where: { groups[index].desks.contains($0) }), let at = row.firstIndex(of: last) {
            row.insert(desk, at: at + 1)
            remember(row)
        }
        groups[index].desks.append(desk)
        dropEmpty()
    }

    /// Take `desk` out of its group. Its tab stays where it is in the order,
    /// which puts it just outside the group's tabs.
    public mutating func ungroup(_ desk: String) {
        for i in groups.indices { groups[i].desks.removeAll { $0 == desk } }
        dropEmpty()
    }

    /// Dissolve the group at `index`: its tabs stay, the label goes.
    public mutating func dissolve(_ index: Int) {
        guard groups.indices.contains(index) else { return }
        groups.remove(at: index)
    }

    public mutating func rename(_ index: Int, to name: String) {
        guard groups.indices.contains(index) else { return }
        groups[index].name = TabLayout.clean(name)
    }

    public mutating func recolor(_ index: Int, to color: String) {
        guard groups.indices.contains(index), DeskColor.palette.contains(where: { $0.name == color }) else { return }
        groups[index].color = color
    }

    public mutating func toggle(_ index: Int) {
        guard groups.indices.contains(index) else { return }
        groups[index].collapsed.toggle()
    }

    /// A desk was renamed: its place and its group follow it.
    public mutating func renamed(from old: String, to new: String) {
        order = order.map { $0 == old ? new : $0 }
        for i in groups.indices { groups[i].desks = groups[i].desks.map { $0 == old ? new : $0 } }
    }

    /// Forget desks that no longer exist.
    public mutating func prune(keeping names: Set<String>) {
        order.removeAll { !names.contains($0) }
        for i in groups.indices { groups[i].desks.removeAll { !names.contains($0) } }
        dropEmpty()
    }

    /// A label's text: one line, not long, never empty.
    public static func clean(_ name: String) -> String {
        let one = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return one.isEmpty ? "Group" : String(one.prefix(24))
    }
}
