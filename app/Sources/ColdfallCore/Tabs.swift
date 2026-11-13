import Foundation

/// The tab row over the terminal: the running desks in the current desk's
/// group, the way Herdr shows the agents of the space you are in.
///
/// Switching to a desk in another group switches the whole set. The desk on
/// screen always has a tab, running or not, so you can see where you are.
/// Hidden desks get no tab unless they are the one on screen. Order is the
/// rail's own, so tabs never shuffle as desks change state.
public enum DeskTabs {
    public static func list(_ desks: [Desk], current: String?, running: Set<String>) -> [String] {
        guard let cur = current, let here = desks.first(where: { $0.name == cur }) else { return [] }
        return desks.filter { d in
            d.group == here.group && (d.name == cur || (running.contains(d.name) && !d.hidden))
        }.map(\.name)
    }

    /// The desks in this group that are not running, for the "+" menu.
    public static func startable(_ desks: [Desk], current: String?, running: Set<String>) -> [String] {
        guard let cur = current, let here = desks.first(where: { $0.name == cur }) else { return [] }
        return desks.filter { $0.group == here.group && !running.contains($0.name) && !$0.hidden && $0.name != cur }
            .map(\.name)
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
