// Editing the desk list from the rail: renaming a desk, dragging it to a new
// place, and measuring what each one costs in memory.
//
// All three live here rather than in the app because each has a way to go
// quietly wrong. A name with a dot in it writes `[desk.a.b]`, which TOML reads
// as a nested table and the loader never finds again. A drag that drops into a
// group has to change the desk's group as well as its place, or it snaps back
// to where it came from on the next rebuild. And memory has to count the
// agent's whole process tree, not the shell at the top of it, or a desk using
// a gigabyte reads as two megabytes.

import Foundation

public enum DeskName {

    public static let maxLength = 40

    /// Why a proposed name cannot be used, or nil when it can.
    ///
    /// The name becomes a bare TOML key in `[desk.<name>]`, so it is held to
    /// what a bare key allows: letters, digits, `-` and `_`. Anything else
    /// would need quoting the hand-rolled reader does not do.
    public static func problem(_ name: String, existing: [String], current: String? = nil) -> String? {
        if name.isEmpty { return "A desk needs a name." }
        if name.count > maxLength { return "Keep it to \(maxLength) characters or fewer." }
        let ok = name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "-" || $0 == "_"
        }
        if !ok { return "Use letters, numbers, - and _ only. No spaces or dots." }
        let taken = existing.contains { $0.lowercased() == name.lowercased() && $0 != current }
        if taken { return "There is already a desk called \(name)." }
        return nil
    }
}

/// Where a dragged desk lands.
public enum DeskDrop: Equatable {
    case before(Int)
    case after(Int)
    /// Dropped on a group's header: goes to the end of that group.
    case endOfGroup(String?)
}

public enum DeskOrder {

    /// The desk list after moving desk `from` to `drop`. Indices in `drop`
    /// refer to the list as it was before the move.
    ///
    /// Landing next to a desk puts the moved desk in that desk's group, so
    /// dragging a desk into another group's rows moves it into that group.
    /// Returns the list unchanged for a drop onto itself.
    public static func move(_ desks: [Desk], from: Int, to drop: DeskDrop) -> [Desk] {
        guard desks.indices.contains(from) else { return desks }
        var moving = desks[from]
        var rest = desks
        rest.remove(at: from)
        // Shift a target index to account for the removal.
        func adj(_ i: Int) -> Int { i > from ? i - 1 : i }

        let at: Int
        switch drop {
        case .before(let i):
            guard desks.indices.contains(i), i != from else { return desks }
            moving.group = desks[i].group
            at = adj(i)
        case .after(let i):
            guard desks.indices.contains(i), i != from else { return desks }
            moving.group = desks[i].group
            at = adj(i) + 1
        case .endOfGroup(let g):
            moving.group = g
            at = (rest.lastIndex { $0.group == g }).map { $0 + 1 } ?? rest.count
        }
        rest.insert(moving, at: min(max(0, at), rest.count))
        return rest
    }

    /// The desks cmd-1..9 go to, as indices into `desks`: the first nine the
    /// rail shows, so a hidden desk never takes a number. Pinned desks come
    /// first, as they do on screen, so cmd-1 is the top row.
    public static func shortcuts(_ desks: [Desk]) -> [Int] {
        let shown = desks.indices.filter { !desks[$0].hidden }
        return Array((shown.filter { desks[$0].pinned } + shown.filter { !desks[$0].pinned }).prefix(9))
    }

    /// The top of the rail, as indices into `desks`. Pinned desks first, in
    /// your order; then the desks that have floated up because they are
    /// ready for you, in the order given (the "needs you" line's: longest
    /// wait first). A desk in either zone is not shown again in its group.
    public struct Zones: Equatable {
        public let pinned: [Int]
        public let floated: [Int]
        public init(pinned: [Int], floated: [Int]) { self.pinned = pinned; self.floated = floated }
        public func contains(_ i: Int) -> Bool { pinned.contains(i) || floated.contains(i) }
    }

    public static func zones(_ desks: [Desk], floated names: [String]) -> Zones {
        let pinned = desks.indices.filter { desks[$0].pinned && !desks[$0].hidden }
        var up: [Int] = []
        for n in names {
            guard let i = desks.firstIndex(where: { $0.name == n }),
                  !desks[i].hidden, !desks[i].pinned, !up.contains(i) else { continue }
            up.append(i)
        }
        return Zones(pinned: pinned, floated: up)
    }

    /// Which desks should be floated to the top right now: the ones waiting
    /// on you, unless they are pinned (already on top) or hidden. Empty when
    /// the setting is off. The rail takes this up only at a calm moment, so
    /// a row never moves out from under the pointer.
    public static func floating(_ desks: [Desk], waiting: [String], enabled: Bool) -> [String] {
        guard enabled else { return [] }
        return zones(desks, floated: waiting).floated.map { desks[$0].name }
    }

    /// Groups in the order the rail shows them: ungrouped desks first, then
    /// each group where its first desk appears in the list.
    public static func groups(_ desks: [Desk]) -> [String?] {
        var order: [String?] = [nil]
        for d in desks where d.group != nil && !order.contains(where: { $0 == d.group }) {
            order.append(d.group)
        }
        return order
    }

    /// Groups in "Keep Active Groups on Top" order. Ungrouped desks stay on
    /// top as always. Then groups with a desk that needs you, oldest wait
    /// first (the order of the "needs you" line); then groups by their most
    /// recently used desk; then the rest in your own order. Desks inside a
    /// group keep your order, and hidden desks count for nothing.
    ///
    /// `waiting` is when each waiting desk went quiet; `used` is the latest
    /// of its last output and the last time you opened it.
    public static func liveGroups(_ desks: [Desk], waiting: [String: Date], used: [String: Date]) -> [String?] {
        let saved = groups(desks).compactMap { $0 }
        func members(_ g: String) -> [Desk] { desks.filter { $0.group == g && !$0.hidden } }
        func oldestWait(_ g: String) -> Date? { members(g).compactMap { waiting[$0.name] }.min() }
        func lastUse(_ g: String) -> Date? { members(g).compactMap { used[$0.name] }.max() }
        let ranked = saved.enumerated().sorted { a, b in
            switch (oldestWait(a.element), oldestWait(b.element)) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            switch (lastUse(a.element), lastUse(b.element)) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset      // your order breaks ties
            }
        }
        return [nil] + ranked.map { Optional($0.element) }
    }

    /// The list in the order the rail shows it, each group's desks together.
    ///
    /// The rail gathers a group's desks under one header wherever they sit in
    /// the file, but cmd-1..9 follow the file. Saving this order keeps the two
    /// the same, and gives a group one contiguous run that can move as a block.
    public static func grouped(_ desks: [Desk]) -> [Desk] {
        groups(desks).flatMap { g in desks.filter { $0.group == g } }
    }

    /// Groups A to Z, and the desks in each group A to Z. Ungrouped desks stay
    /// on top, sorted among themselves. Case and digits compare the way Finder
    /// does, so "desk2" comes before "desk10".
    public static func sortedAZ(_ desks: [Desk]) -> [Desk] {
        func less(_ a: String, _ b: String) -> Bool {
            a.localizedStandardCompare(b) == .orderedAscending
        }
        let named = groups(desks).compactMap { $0 }.sorted(by: less)
        return ([nil] + named).flatMap { g in
            desks.filter { $0.group == g }.sorted { less($0.name, $1.name) }
        }
    }

    /// The list after moving every desk in `group` so the group sits just
    /// before `before`, or last when `before` is nil. Ungrouped desks always
    /// stay on top, so they are neither moved nor a target.
    public static func moveGroup(_ desks: [Desk], _ group: String, before: String?) -> [Desk] {
        guard group != before else { return grouped(desks) }
        var order = groups(desks).compactMap { $0 }
        guard let from = order.firstIndex(of: group) else { return grouped(desks) }
        order.remove(at: from)
        let at = before.flatMap { order.firstIndex(of: $0) } ?? order.count
        order.insert(group, at: at)
        return ([nil] + order.map(Optional.some)).flatMap { g in desks.filter { $0.group == g } }
    }
}

/// Memory per desk, from one `ps` table.
///
/// A desk's terminal owns a login shell, which owns the agent, which owns its
/// MCP servers. Only the sum of that tree is the honest number.
public enum ProcessTree {

    public struct Row: Equatable {
        public let pid: Int32, ppid: Int32, rssKB: Int
        public init(pid: Int32, ppid: Int32, rssKB: Int) { self.pid = pid; self.ppid = ppid; self.rssKB = rssKB }
    }

    /// Parse `ps -axo pid=,ppid=,rss=`. Lines that do not parse are skipped.
    public static func parse(_ text: String) -> [Row] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 3, let p = Int32(f[0]), let pp = Int32(f[1]), let r = Int(f[2]) else { return nil }
            return Row(pid: p, ppid: pp, rssKB: r)
        }
    }

    /// Resident memory of `root` and every descendant, in kilobytes.
    public static func totalKB(root: Int32, in rows: [Row]) -> Int {
        guard root > 0 else { return 0 }
        var kids: [Int32: [Int32]] = [:]
        var rss: [Int32: Int] = [:]
        for r in rows { kids[r.ppid, default: []].append(r.pid); rss[r.pid] = r.rssKB }
        guard rss[root] != nil else { return 0 }
        var total = 0, stack = [root], seen: Set<Int32> = []
        while let p = stack.popLast() {
            guard seen.insert(p).inserted else { continue }
            total += rss[p] ?? 0
            stack += kids[p] ?? []
        }
        return total
    }

    /// `root` and everything under it, deepest first, so ending them in this
    /// order never leaves a child without the parent that would reap it
    /// looking on. The root comes last.
    public static func descendants(of root: Int32, in rows: [Row]) -> [Int32] {
        guard root > 0, rows.contains(where: { $0.pid == root }) else { return [] }
        var kids: [Int32: [Int32]] = [:]
        for r in rows { kids[r.ppid, default: []].append(r.pid) }
        var out: [Int32] = [], seen: Set<Int32> = []
        func walk(_ p: Int32) {
            guard seen.insert(p).inserted else { return }
            for c in kids[p] ?? [] { walk(c) }
            out.append(p)
        }
        walk(root)
        return out
    }

    /// When process `pid` started, in microseconds, or nil when there is no
    /// such process. With the pid, it names one process for good.
    public static func startTime(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }

    /// The live `ps` table.
    public static func read() -> [Row] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,rss="]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// End a desk's whole process tree.
    ///
    /// SIGTERM to the login shell alone does nothing: an interactive zsh
    /// ignores it, and the agent it is running carries on with no window,
    /// holding a gigabyte and the same conversation a restarted desk then
    /// opens a second time. So every process in the tree is asked to stop,
    /// and whatever is still there a few seconds later is
    /// killed. `pids` should come from `descendants`, taken before any of it.
    public static func end(_ pids: [Int32], grace: TimeInterval = 3) {
        guard !pids.isEmpty else { return }
        // Who each pid is now, so the kill below never lands on a stranger:
        // a process that exits during the grace period can have its number
        // reused, and a bare number would then name somebody else's process.
        let started = Dictionary(uniqueKeysWithValues: pids.map { ($0, startTime($0)) })
        for p in pids.dropLast() { kill(p, SIGTERM) }
        if let shell = pids.last { kill(shell, SIGHUP) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            for p in pids {
                guard let then = started[p] ?? nil, let now = startTime(p), now == then else { continue }
                kill(p, SIGKILL)
            }
            // The shell is our own child. Once the terminal has let go of it,
            // nothing else collects its exit, and it lingers as <defunct>
            // until the app quits. Collect it here.
            if let shell = pids.last {
                var st: Int32 = 0
                for _ in 0..<10 where waitpid(shell, &st, WNOHANG) == 0 { usleep(200_000) }
            }
        }
    }

    /// "940 MB", "1.2 GB". Nil under 1 MB, which is a process that has not
    /// really started and is not worth a label.
    public static func label(kb: Int) -> String? {
        let mb = Double(kb) / 1024
        if mb < 1 { return nil }
        if mb < 1000 { return "\(Int(mb.rounded())) MB" }
        return String(format: "%.1f GB", mb / 1024)
    }
}
