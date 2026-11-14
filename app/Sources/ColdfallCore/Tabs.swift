import Foundation

/// The tab row over the terminal: the running desks in the current desk's
/// group, the way Herdr shows the agents of the space you are in.
///
/// Switching to a desk in another group switches the whole set. The desk on
/// screen always has a tab, running or not, so you can see where you are.
/// Hidden desks get no tab unless they are the one on screen. Order is the
/// rail's own, so tabs never shuffle as desks change state.
///
/// Every desk on screen has a tab, whatever group it is in: with several
/// side by side, all the desks you are looking at are in the row. Ones from
/// another group sit right after the desk that has the keys, where a full
/// group does not push them off the end.
public enum DeskTabs {
    public static func list(_ desks: [Desk], current: String?, running: Set<String>, onScreen: [String] = []) -> [String] {
        guard let cur = current, let here = desks.first(where: { $0.name == cur }) else { return [] }
        var out = desks.filter { d in
            d.group == here.group && (d.name == cur || onScreen.contains(d.name) || (running.contains(d.name) && !d.hidden))
        }.map(\.name)
        var at = (out.firstIndex(of: cur) ?? out.count - 1) + 1
        for n in onScreen where n != cur && !out.contains(n) && desks.contains(where: { $0.name == n }) {
            out.insert(n, at: at); at += 1
        }
        return out
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
