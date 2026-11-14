import AppKit
import ColdfallCore

/// The desk rail. Groups are collapsible and renameable; ungrouped desks sit on
/// top. Reports its own content height so the scroll view never clips the last
/// desk — a fixed estimate got that wrong as soon as group headers appeared.
final class SidebarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onToggleGroup: ((String) -> Void)?
    var onRenameGroup: ((String) -> Void)?
    var onRemoveDesk: ((Int) -> Void)?
    var onRevealAgent: ((Int) -> Void)?
    var onMakeDefault: ((Int) -> Void)?
    var onRenameDesk: ((Int) -> Void)?
    var onStopDesk: ((Int) -> Void)?
    var onPeekDesk: ((Int) -> Void)?
    var onMarkUnreadDesk: ((Int) -> Void)?
    var onColorDesk: ((Int, String?) -> Void)?
    var onBesideDesk: ((Int) -> Void)?
    /// Desks put off in the waiting queue, and when (see NeedsYou.queue).
    var deferred: [String: Date] = [:]
    /// The Desks section by priority: every running desk, across groups,
    /// under Needs you, Done, Working, Idle. Off, it lists the selected group.
    var byPriority = false { didSet { if byPriority != oldValue, let d = lastDesks { build(desks: d) } } }
    var onTogglePriority: (() -> Void)?
    /// The sections as last drawn, to know when the list should change.
    private var drawnPriority: [DeskOrder.PrioritySection] = []
    /// The desks in the order the list shows them, for Next and Previous Desk.
    private(set) var shownOrder: [String] = []

    private func wantedPriority(_ d: [Desk]) -> [DeskOrder.PrioritySection] {
        var live: [String: DeskOrder.Live] = [:]
        for (name, st) in status where st.running {
            let rank: Int
            switch st.activity { case .blocked: rank = 0; case .ready: rank = 1; case .working: rank = 2; case .quiet: rank = 3 }
            // Working and idle keep the list's own order: a desk that
            // prints a line shouldn't jump the queue every second.
            live[name] = DeskOrder.Live(rank: rank, lastOutput: rank <= 1 ? st.lastOutput : nil)
        }
        return DeskOrder.priority(d, live: live)
    }

    /// Bring the priority list in line with the desks' states, but only at
    /// a calm moment: never while the pointer is over the list or a drag
    /// is under way, so a row doesn't move out from under a click.
    private func syncPriority() {
        guard byPriority, let d = lastDesks, !pointerInside, !isDragging else { return }
        if wantedPriority(d) != drawnPriority { build(desks: d) }
    }
    var onMcpDesk: ((Int) -> Void)?
    var onInventoryDesk: ((Int) -> Void)?
    var onHideDesk: ((Int) -> Void)?
    var onUnhideDesk: ((Int) -> Void)?
    /// Pin or unpin: the desk, and whether it should now be pinned.
    var onPinDesk: ((Int, Bool) -> Void)?
    var onToggleAskResume: ((Int) -> Void)?
    /// Each desk's week against its budget, for desks that have one.
    var budgets: [String: DeskBudget.Status] = [:] {
        didSet { for r in rows.values { r.budget = budgets[r.deskName] ?? .unset } }
    }
    /// Hidden desks listed at the bottom of the rail. Not saved: hidden is
    /// the point, so the list folds away again on the next launch.
    var showHidden = false

    /// "Keep Active Groups on Top": the order groups are shown in, set by the
    /// controller at calm moments. Nil shows your own order.
    var groupOrder: [String?]?
    var liveOn = false
    var onToggleLive: (() -> Void)?
    /// The pointer is over the rail. Nothing reorders while it is, so a row
    /// never moves out from under a click.
    private(set) var pointerInside = false
    var isDragging: Bool { dropLine.superview != nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { pointerInside = true }
    override func mouseExited(with e: NSEvent) { pointerInside = false; syncPriority() }

    /// A group in the Groups section was clicked: go to its desk.
    var onSelectGroup: ((String?) -> Void)?
    /// Rows in the pinned and floated zones. They don't drag, and a drop is
    /// never measured against them: their place on screen is not their
    /// place in the list.
    private var zoneRows: Set<Int> = []

    var onMoveDesk: ((Int, DeskDrop) -> Void)?
    /// A group dragged by its header: the group, and the group it now sits
    /// before (nil for last).
    var onMoveGroup: ((String, String?) -> Void)?
    var onSortDesks: (() -> Void)?
    /// The "needs you" line was clicked: go to this desk.
    var onJumpToWaiting: ((String) -> Void)?
    /// The needs-you line's ×, or Clear from its right-click menu.
    var onClearWaiting: (() -> Void)?
    /// Installed agents with no desk yet, offered at the top of the rail.
    var offers: [String] = [] { didSet { if offers != oldValue, let d = lastDesks { build(desks: d) } } }
    /// Agents that updated since Coldfall last looked.
    var agentNews: [AgentVersions.Change] = [] {
        didSet { if agentNews != oldValue, let d = lastDesks { build(desks: d) } }
    }
    var onOpenNews: ((AgentVersions.Change) -> Void)?
    var onDismissNews: ((AgentVersions.Change) -> Void)?
    var onAddOffer: ((String) -> Void)?
    var onDismissOffer: ((String) -> Void)?

    /// Group headers by the group they head, for drops onto a header.
    private var headers: [(group: String, view: GroupHeader)] = []
    /// Each named group's extent, header to last row, top to bottom.
    private var spans: [(group: String, minY: CGFloat, maxY: CGFloat)] = []
    /// The line showing where a dragged desk will land.
    private let dropLine = NSView()

    private var rows: [Int: DeskRow] = [:]
    /// The Groups section's rows, with the desks each one counts.
    private var groupRows: [(group: String?, name: String, members: [String], row: GroupRow)] = []
    private var selected = -1
    private(set) var contentHeight: CGFloat = 0
    var collapsed: Set<String> = []

    override var isFlipped: Bool { true }   // lay out top-down inside the scroll view

    /// Per-desk status, keyed by name. Set by the controller each tick.
    var status: [String: DeskStatus] = [:] {
        didSet {
            for r in rows.values { r.status = status[r.deskName] ?? DeskStatus() }
            var q = NeedsYou.queue(status.map {
                NeedsYou.Entry(name: $0.key, activity: $0.value.activity, lastOutput: $0.value.lastOutput)
            }, deferred: deferred)
            let kept = NeedsYou.prune(deferred, queue: q)
            if kept.count != deferred.count {
                deferred = kept
                q = NeedsYou.queue(status.map {
                    NeedsYou.Entry(name: $0.key, activity: $0.value.activity, lastOutput: $0.value.lastOutput)
                }, deferred: deferred)
            }
            // The line and the header counts change the layout, so a change
            // in who is waiting rebuilds. Not mid-drag: that would pull the
            // row out from under the pointer. The next tick catches up.
            waiting = q
            // A desk starting, stopping, going to work or waiting on you
            // changes its group's count and mark. Nothing moves, so there
            // is no rebuild and no row shifts under the pointer.
            for g in groupRows { g.row.configure(name: g.name, desks: g.members.map { status[$0] ?? DeskStatus() }, selected: g.row.selected) }
            syncPriority()
        }
    }
    /// A desk's right-click menu, for the command palette and the tabs.
    /// A desk the list isn't showing (it is in another group, and on screen
    /// beside this one) has no row, so one is made for the menu alone.
    func actionMenu(for i: Int) -> NSMenu? {
        if let r = rows[i] { return r.actionMenu() }
        guard let d = lastDesks, d.indices.contains(i) else { return nil }
        let r = DeskRow(desk: d[i])
        wire(r, i, d[i])
        r.selected = i == selected
        // The menu's items call back into the row, and hold it weakly.
        menuRow = r
        return r.actionMenu()
    }
    private var menuRow: DeskRow?

    /// Desks waiting on you, oldest first, as last drawn.
    private(set) var waiting: [String] = []
    /// Advanced by the controller so a working desk's spinner turns.
    var tick = 0 {
        didSet {
            for r in rows.values { r.tick = tick }
            // "2m" ages on its own; a few seconds' resolution is plenty.
            if tick % 8 == 0 { for r in rows.values { r.refreshAge() } }
        }
    }

    private(set) var lastDesks: [Desk]?
    private(set) var lastSelected: Int?

    /// Groups in the order shown: the live order when on, else yours.
    private func order0(_ desks: [Desk]) -> [String?] {
        let saved = DeskOrder.groups(desks)
        return groupOrder.map { live in live.filter { saved.contains($0) } + saved.filter { !live.contains($0) } } ?? saved
    }

    func build(desks: [Desk]) {
        lastDesks = desks
        subviews.forEach { $0.removeFromSuperview() }
        rows = [:]
        headers = []
        spans = []
        zoneRows = []
        groupRows = []
        let zones = DeskOrder.zones(desks, floated: [])

        // Size from the scroll view's VISIBLE width, not our own. The first
        // build runs before the window has finished sizing, so our own width
        // was a stale, narrower number — rows stopped a hundred points short of
        // the rail and the "2m" floated mid-row instead of sitting flush right.
        let visible = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let w = max(visible, 190)
        var y: CGFloat = 10

        for rt in offers {
            let o = OfferStrip(frame: NSRect(x: 10, y: y, width: w - 20, height: 50))
            o.autoresizingMask = [.width]
            o.configure(title: AgentOffer.shortName(rt))
            o.onAdd = { [weak self] in self?.onAddOffer?(rt) }
            o.onDismiss = { [weak self] in self?.onDismissOffer?(rt) }
            addSubview(o)
            y += 58
        }

        for change in agentNews {
            let n = OfferStrip(frame: NSRect(x: 10, y: y, width: w - 20, height: 50))
            n.autoresizingMask = [.width]
            n.configure(text: change.line, primary: "What's New", secondary: "Dismiss",
                        tip: change.detail + " What's New opens its own release notes.")
            n.onAdd = { [weak self] in self?.onOpenNews?(change) }
            n.onDismiss = { [weak self] in self?.onDismissNews?(change) }
            addSubview(n)
            y += 58
        }

        // Groups, Herdr's spaces: one line each, carrying the most urgent
        // thing among its desks. Clicking one goes to its desk you used last,
        // and the tabs follow.
        let groupTitle = SectionTitle("Groups")
        groupTitle.frame = NSRect(x: 14, y: y, width: w - 28, height: 16)
        groupTitle.translatesAutoresizingMaskIntoConstraints = true
        groupTitle.autoresizingMask = [.width]
        addSubview(groupTitle)
        y += 22
        // The group on show: the selected desk's, else the first with a
        // desk in it. The Desks section lists that group only.
        let order = order0(desks)
        let withDesks = order.filter { g in desks.contains { $0.group == g && !$0.hidden } }
        let selectedGroup: String?? = selected >= 0 && selected < desks.count && !desks[selected].hidden
            ? .some(desks[selected].group) : withDesks.first
        for g in order {
            let members = desks.filter { $0.group == g && !$0.hidden }
            guard !members.isEmpty else { continue }
            let gr = GroupRow(frame: NSRect(x: 4, y: y, width: w - 8, height: 30))
            gr.autoresizingMask = [.width]
            gr.configure(name: g ?? "General", desks: members.map { status[$0.name] ?? DeskStatus() },
                         selected: selectedGroup == .some(g))
            gr.onClick = { [weak self] in self?.onSelectGroup?(g) }
            if let g {
                gr.onRename = { [weak self] in self?.onRenameGroup?(g) }
                gr.onSort = { [weak self] in self?.onSortDesks?() }
                // While groups sort themselves, dragging one would edit an
                // order you can't see, so groups don't drag then.
                if !liveOn {
                    gr.onDragMoved = { [weak self] p in self?.groupDragMoved(g, to: p) }
                    gr.onDragEnded = { [weak self] p in self?.groupDragEnded(g, at: p) }
                }
                spans.append((g, gr.frame.minY, gr.frame.maxY))
            }
            addSubview(gr)
            groupRows.append((g, g ?? "General", members.map(\.name), gr))
            y += 32
        }
        y += 10

        let title = SectionTitle("Desks")
        title.frame = NSRect(x: 14, y: y, width: w - 28, height: 16)
        title.translatesAutoresizingMaskIntoConstraints = true
        title.autoresizingMask = [.width]
        addSubview(title)
        // How the section is ordered, and the way to change it.
        let mode = NSButton(title: byPriority ? "By priority" : "By group", target: self, action: #selector(togglePriority))
        mode.isBordered = false
        mode.bezelStyle = .inline
        mode.font = .systemFont(ofSize: 11)
        mode.contentTintColor = Theme.ui.dimText
        mode.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .medium))
        mode.imagePosition = .imageTrailing
        mode.imageHugsTitle = true
        mode.toolTip = byPriority
            ? "Every running desk, most urgent first. Click to list the selected group instead."
            : "The selected group's desks. Click to list every running desk, most urgent first."
        mode.sizeToFit()
        // Beside the title rather than flush right: the first build runs
        // before the rail has its width, and a right edge would be a guess.
        mode.frame = NSRect(x: 14 + title.intrinsicContentSize.width + 10, y: y - 2, width: mode.fittingSize.width + 2, height: 18)
        addSubview(mode)
        y += 22
        shownOrder = []
        drawnPriority = []

        // Pinned desks: always here, in your order, whatever group they are in.
        for i in zones.pinned {
            let r = row(i, desks[i], indent: 4, y: y, width: w)
            r.showsPin = true
            r.onHide = { [weak self] in self?.onHideDesk?(i) }
            zoneRows.insert(i)
            shownOrder.append(desks[i].name)
            y += DeskRow.height + 2
        }
        if !zones.pinned.isEmpty { y += 8 }

        if byPriority {
            // Who next, not where: running desks from every group, by what
            // they need from you. Rows don't drag here; the order isn't yours.
            drawnPriority = wantedPriority(desks)
            let index = Dictionary(desks.enumerated().map { ($0.element.name, $0.offset) }, uniquingKeysWith: { a, _ in a })
            for sec in drawnPriority {
                let t = SectionTitle("\(sec.urgency.title)  \(sec.names.count)")
                t.frame = NSRect(x: 16, y: y, width: w - 32, height: 15)
                t.translatesAutoresizingMaskIntoConstraints = true
                t.autoresizingMask = [.width]
                t.font = .systemFont(ofSize: 11, weight: .medium)
                addSubview(t)
                y += 19
                for n in sec.names {
                    guard let i = index[n] else { continue }
                    let r = row(i, desks[i], indent: 4, y: y, width: w)
                    r.onHide = { [weak self] in self?.onHideDesk?(i) }
                    zoneRows.insert(i)
                    shownOrder.append(n)
                    y += DeskRow.height + 2
                }
                y += 6
            }
            let stopped = desks.filter { !$0.hidden && !$0.pinned && status[$0.name]?.running != true }.count
            if stopped > 0 || drawnPriority.isEmpty {
                let t = SectionTitle(drawnPriority.isEmpty && stopped == 0 ? "No desks" : "\(stopped) not running, under By group")
                t.frame = NSRect(x: 16, y: y, width: w - 32, height: 15)
                t.translatesAutoresizingMaskIntoConstraints = true
                t.autoresizingMask = [.width]
                t.font = .systemFont(ofSize: 11)
                addSubview(t)
                y += 22
            }
        }

        // Only the group on show. Its name is the lit row above, so there
        // is no header here; a desk moves to another group by dragging it
        // onto that group's row.
        for g in order where !byPriority && selectedGroup == .some(g) {
            let members = desks.enumerated().filter { $0.element.group == g && !$0.element.hidden && !zones.contains($0.offset) }
            for (i, d) in members {
                shownOrder.append(d.name)
                let r = row(i, d, indent: 4, y: y, width: w)
                r.onHide = { [weak self] in self?.onHideDesk?(i) }
                r.onDragMoved = { [weak self] p in self?.dragMoved(from: i, to: p) }
                r.onDragEnded = { [weak self] p in self?.dragEnded(from: i, at: p) }
                y += DeskRow.height + 2
            }
            y += 8
        }

        // Hidden desks: one line saying how many, and the desks themselves
        // only when asked for. They don't drag; unhide one to move it.
        let hiddenOnes = desks.enumerated().filter { $0.element.hidden }
        if !hiddenOnes.isEmpty {
            let h = HiddenHeader(frame: NSRect(x: 10, y: y, width: w - 20, height: 20))
            h.autoresizingMask = [.width]
            h.configure(count: hiddenOnes.count, expanded: showHidden)
            h.onClick = { [weak self] in
                guard let self, let d = self.lastDesks else { return }
                self.showHidden.toggle()
                self.build(desks: d)
                if self.showHidden { self.revealHidden() }
            }
            addSubview(h)
            y += 22
            if showHidden {
                for (i, d) in hiddenOnes {
                    let r = row(i, d, indent: 12, y: y, width: w)
                    r.alphaValue = 0.6
                    r.onUnhide = { [weak self] in self?.onUnhideDesk?(i) }
                    y += DeskRow.height + 2
                }
            }
            y += 8
        }

        contentHeight = y + 10
        frame = NSRect(x: 0, y: 0, width: w, height: contentHeight)
        if selected >= 0 { select(selected) }
    }

    /// Scroll so the hidden desks just listed are in view. The rail is often
    /// shorter than its desks, and a click that seems to do nothing reads
    /// as broken.
    func revealHidden() {
        scrollToVisible(NSRect(x: 0, y: max(0, contentHeight - 1), width: 1, height: 1))
    }

    /// One desk's row, wired to everything a row does whether or not the
    /// desk is hidden. Added to the rail and remembered by index.
    private func row(_ i: Int, _ d: Desk, indent: CGFloat, y: CGFloat, width w: CGFloat) -> DeskRow {
                let r = DeskRow(desk: d)
                r.frame = NSRect(x: indent, y: y, width: w - indent - 4, height: DeskRow.height)
                r.autoresizingMask = [.width]   // stretches with the rail; time stays flush right
                wire(r, i, d)
                addSubview(r)
                rows[i] = r
                return r
    }

    /// Everything a desk's row can do, and what it knows about the desk.
    private func wire(_ r: DeskRow, _ i: Int, _ d: Desk) {
                r.onClick = { [weak self] in self?.select(i); self?.onSelect?(i) }
                r.onRemove = { [weak self] in self?.onRemoveDesk?(i) }
                r.onReveal = d.agent == nil ? nil : { [weak self] in self?.onRevealAgent?(i) }
                r.onMakeDefault = d.isDefault || d.runtime == "shell"
                    ? nil : { [weak self] in self?.onMakeDefault?(i) }
                r.onRename = { [weak self] in self?.onRenameDesk?(i) }
                r.onStop = { [weak self] in self?.onStopDesk?(i) }
                r.onPeek = { [weak self] in self?.onPeekDesk?(i) }
                r.onMarkUnread = { [weak self] in self?.onMarkUnreadDesk?(i) }
                if !d.hidden {
                    r.onColor = { [weak self] c in self?.onColorDesk?(i, c) }
                    r.onBeside = { [weak self] in self?.onBesideDesk?(i) }
                }
                if !d.hidden {
                    if d.pinned { r.onUnpin = { [weak self] in self?.onPinDesk?(i, false) } }
                    else { r.onPin = { [weak self] in self?.onPinDesk?(i, true) } }
                }
                // The vendors whose way of switching one server off has been
                // checked (see McpTrim).
                r.onMcp = ["claude", "codex"].contains(d.runtime) ? { [weak self] in self?.onMcpDesk?(i) } : nil
                r.onInventory = d.runtime == "shell" ? nil : { [weak self] in self?.onInventoryDesk?(i) }
                // Only where the desk can be started fresh at all.
                if d.runtime == "claude", d.freshCommand() != nil {
                    r.asksResume = !d.alwaysResume
                    r.onToggleAskResume = { [weak self] in self?.onToggleAskResume?(i) }
                }
                r.status = status[d.name] ?? DeskStatus()
                r.budget = budgets[d.name] ?? .unset
                r.tick = tick
    }

    /// The rail's real width is only known after the window lays out. Rebuild
    /// once it is, so the very first paint is not the narrow one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let d = lastDesks { DispatchQueue.main.async { self.build(desks: d) } }
    }

    /// Track the visible width of the scroll view we sit in.
    ///
    /// A scroll view does NOT resize its document view when it resizes, so an
    /// autoresizing mask on this view does nothing. That was the second bug:
    /// the first build caught a stale narrow width and the time floated
    /// mid-row; stretching by mask then left the rows WIDER than the rail, and
    /// the time was laid out off-screen entirely. Following the clip view's
    /// frame keeps this view exactly as wide as what is visible, and the rows'
    /// own masks carry that down to them.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    /// Lay every child out to the current width, explicitly.
    ///
    /// Measured in a snapshot: the rail was correctly 240 wide while its rows
    /// were still 422 — built while the window was wider, and never shrunk.
    /// Rather than depend on autoresizing masks that evidently did not apply
    /// here, every width change re-lays the children out by hand. Rows keep a
    /// small right gutter; titles and group headers keep a margin matching
    /// their left inset.
    override func resizeSubviews(withOldSize old: NSSize) {
        for v in subviews {
            let w = v is DeskRow ? bounds.width - v.frame.minX - 4
                                 : bounds.width - 2 * v.frame.minX
            v.setFrameSize(NSSize(width: max(0, w), height: v.frame.height))
        }
    }

    @objc private func clipResized() {
        guard let clip = superview as? NSClipView else { return }
        let w = max(clip.bounds.width, 190)
        if abs(frame.width - w) > 0.5 { setFrameSize(NSSize(width: w, height: frame.height)) }
    }

    // MARK: - drag to reorder

    /// What a drop at `p` means: onto a header is the end of that group;
    /// onto a row is before or after it, by which half the pointer is in.
    private func drop(at p: NSPoint, from: Int) -> (DeskDrop, CGFloat)? {
        // Onto a group's row: into that group, at its end.
        for g in groupRows where g.row.frame.contains(p) {
            if lastDesks?.indices.contains(from) == true, lastDesks?[from].group == g.group { return nil }
            return (.endOfGroup(g.group), g.row.frame.maxY)
        }
        let ordered = rows.filter { !zoneRows.contains($0.key) }.sorted { $0.value.frame.minY < $1.value.frame.minY }
        guard let first = ordered.first else { return nil }
        if p.y < first.value.frame.minY { return (.before(first.key), first.value.frame.minY) }
        for (i, r) in ordered where p.y < r.frame.maxY + 2 {
            if i == from { return nil }
            return p.y < r.frame.midY ? (.before(i), r.frame.minY) : (.after(i), r.frame.maxY)
        }
        let last = ordered.last!
        return last.key == from ? nil : (.after(last.key), last.value.frame.maxY)
    }

    private func dragMoved(from: Int, to p: NSPoint) {
        guard let (_, y) = drop(at: p, from: from) else { dropLine.removeFromSuperview(); return }
        dropLine.wantsLayer = true
        dropLine.layer?.backgroundColor = Theme.ui.accent.cgColor
        dropLine.frame = NSRect(x: 10, y: y - 1, width: bounds.width - 20, height: 2)
        if dropLine.superview == nil { addSubview(dropLine) }
        if let e = NSApp.currentEvent { autoscroll(with: e) }
    }

    private func dragEnded(from: Int, at p: NSPoint) {
        dropLine.removeFromSuperview()
        guard let (d, _) = drop(at: p, from: from) else { return }
        onMoveDesk?(from, d)
    }

    // MARK: - drag a group by its header

    /// Where a dragged group lands: before the first group whose middle is
    /// below the pointer, or last. Nil when that is where it already is.
    private func groupDrop(at p: NSPoint, moving g: String) -> (before: String?, y: CGFloat)? {
        guard let from = spans.firstIndex(where: { $0.group == g }) else { return nil }
        var target = spans.count
        for (k, s) in spans.enumerated() where p.y < (s.minY + s.maxY) / 2 { target = k; break }
        // Dropping just above itself or just below itself is no move.
        if target == from || target == from + 1 { return nil }
        if target == spans.count { return (nil, spans[spans.count - 1].maxY + 3) }
        return (spans[target].group, spans[target].minY - 4)
    }

    private func groupDragMoved(_ g: String, to p: NSPoint) {
        guard let (_, y) = groupDrop(at: p, moving: g) else { dropLine.removeFromSuperview(); return }
        dropLine.wantsLayer = true
        dropLine.layer?.backgroundColor = Theme.ui.accent.cgColor
        dropLine.frame = NSRect(x: 10, y: y - 1, width: bounds.width - 20, height: 2)
        if dropLine.superview == nil { addSubview(dropLine) }
        if let e = NSApp.currentEvent { autoscroll(with: e) }
    }

    private func groupDragEnded(_ g: String, at p: NSPoint) {
        dropLine.removeFromSuperview()
        guard let (before, _) = groupDrop(at: p, moving: g) else { return }
        onMoveGroup?(g, before)
    }

    /// Right-click on empty rail: the one action that is about the whole list.
    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        let live = NSMenuItem(title: "Keep Active Groups on Top", action: #selector(toggleLive), keyEquivalent: "")
        live.target = self
        live.state = liveOn ? .on : .off
        live.toolTip = "Groups with a desk that needs you, then the most recently used, rise to the top. "
            + "Your own order is kept underneath: turn this off to get it back."
        m.addItem(live)
        let it = NSMenuItem(title: "Sort Desks A to Z", action: #selector(sortAll), keyEquivalent: "")
        it.target = self
        m.addItem(it)
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
    @objc private func sortAll() { onSortDesks?() }
    @objc private func toggleLive() { onToggleLive?() }
    @objc private func togglePriority() { onTogglePriority?() }

    func select(_ i: Int) {
        lastSelected = i
        let before = selected
        selected = i
        for (j, r) in rows { r.selected = (j == i) }
        // A desk in another group: the Groups section shows which one now.
        if let d = lastDesks, d.indices.contains(i), !d.indices.contains(before) || d[before].group != d[i].group {
            build(desks: d)
            for (j, r) in rows { r.selected = (j == i) }
        }
    }

    /// Repaint after a light/dark flip.
    func restyle() {
        guard let d = lastDesks else { return }
        build(desks: d)
        if let i = lastSelected { select(i) }
    }
}

final class GroupHeader: NSView {
    var onClick: (() -> Void)?
    var onRename: (() -> Void)?
    var onSort: (() -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Theme.ui.dimText
        label.frame = bounds
        label.autoresizingMask = [.width]
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    /// Folded, the header carries what its desks would show: orange if one
    /// is asking you something, green if one has finished.
    func configure(title: String, expanded: Bool, waiting: Int = 0, asking: Bool = false, running: Int = 0) {
        let s = NSMutableAttributedString(string: (expanded ? "▾ " : "▸ ") + title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Theme.ui.dimText,
        ])
        // Its running desks are up in Active; say so, so none seem missing.
        if running > 0 {
            s.append(NSAttributedString(string: "  · \(running) in Active", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.ui.dimText.withAlphaComponent(0.8),
            ]))
        }
        if waiting > 0 {
            s.append(NSAttributedString(string: (asking ? "  ◉ " : "  ● ") + "\(waiting)", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: asking ? NSColor.systemOrange : NSColor.systemGreen,
            ]))
        }
        label.attributedStringValue = s
    }

    // A click folds the group; a drag of more than a few points moves it.
    private var downAt: NSPoint?
    private var dragging = false

    override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow; dragging = false }

    override func mouseDragged(with e: NSEvent) {
        guard let start = downAt, onDragMoved != nil else { return }
        let p = e.locationInWindow
        if !dragging, hypot(p.x - start.x, p.y - start.y) > 4 { dragging = true; alphaValue = 0.45 }
        if dragging, let sv = superview { onDragMoved?(sv.convert(p, from: nil)) }
    }

    override func mouseUp(with e: NSEvent) {
        defer { downAt = nil; dragging = false; alphaValue = 1 }
        if dragging, let sv = superview { onDragEnded?(sv.convert(e.locationInWindow, from: nil)) }
        else if downAt != nil { onClick?() }
    }

    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        let it = NSMenuItem(title: "Rename Group…", action: #selector(rename), keyEquivalent: "")
        it.target = self
        m.addItem(it)
        let s = NSMenuItem(title: "Sort Desks A to Z", action: #selector(sort), keyEquivalent: "")
        s.target = self
        m.addItem(s)
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
    @objc private func rename() { onRename?() }
    @objc private func sort() { onSort?() }
}


/// Right-click a desk to remove it. The natural gesture, and it keeps the
/// distinction visible: removing a desk removes the shortcut, not the agent.

/// "2 need you: career, hub" at the top of the rail. Click to go to the one
/// that has waited longest.
final class NeedsYouStrip: NSView {
    var onClick: (() -> Void)?
    var onClear: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let clear = NSButton(title: "×", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.14).cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .systemGreen
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 10, y: 5, width: frame.width - 38, height: 16)
        label.autoresizingMask = [.width]
        addSubview(label)
        clear.isBordered = false
        clear.font = .systemFont(ofSize: 14, weight: .medium)
        clear.contentTintColor = .systemGreen
        clear.frame = NSRect(x: frame.width - 26, y: 2, width: 22, height: 22)
        clear.autoresizingMask = [.minXMargin]
        clear.target = self
        clear.action = #selector(clearAll)
        clear.toolTip = "Clear: mark these desks as seen"
        addSubview(clear)
        toolTip = "Go to the desk that has waited longest (⌘0). Right-click to clear."
        let m = NSMenu()
        m.addItem(withTitle: "Clear", action: #selector(clearAll), keyEquivalent: "").target = self
        menu = m
    }
    @objc private func clearAll() { onClear?() }
    required init?(coder: NSCoder) { fatalError() }

    /// Orange when the first in line is stopped on a question, green when
    /// it has only finished.
    func configure(_ text: String, urgent: Bool = false) {
        label.stringValue = (urgent ? "◉ " : "● ") + text
        let c: NSColor = urgent ? .systemOrange : .systemGreen
        label.textColor = c
        clear.contentTintColor = c
        layer?.backgroundColor = c.withAlphaComponent(0.14).cgColor
    }

    override func mouseUp(with e: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// "▸ 3 HIDDEN" at the bottom of the rail. Click to list them.
final class HiddenHeader: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Theme.ui.dimText
        label.frame = bounds
        label.autoresizingMask = [.width]
        addSubview(label)
        toolTip = "Desks you've hidden. Right-click one to unhide it."
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int, expanded: Bool) {
        label.stringValue = (expanded ? "▾ " : "▸ ") + "\(count) hidden"
    }
    override func mouseDown(with e: NSEvent) { onClick?() }
}

/// "Copilot is installed, with no desk. Add desk · Not now"
final class OfferStrip: NSView {
    var onAdd: (() -> Void)?
    var onDismiss: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let add = NSButton(title: "Add desk", target: nil, action: nil)
    private let later = NSButton(title: "Not now", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Theme.ui.accent.withAlphaComponent(0.13).cgColor
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = Theme.ui.text
        label.lineBreakMode = .byTruncatingTail
        for b in [add, later] { b.bezelStyle = .rounded; b.controlSize = .small; b.target = self }
        add.bezelColor = Theme.ui.accent
        add.keyEquivalent = ""
        add.action = #selector(addTapped); later.action = #selector(laterTapped)
        let buttons = NSStackView(views: [add, later]); buttons.spacing = 6
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.frame = bounds.insetBy(dx: 10, dy: 6)
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String) {
        label.stringValue = "\(title) is installed. Give it a desk?"
        toolTip = "Add a desk that runs \(title), or hide this with Not now."
    }

    /// The same strip saying something else, e.g. an agent that updated.
    func configure(text: String, primary: String, secondary: String, tip: String) {
        label.stringValue = text
        add.title = primary
        later.title = secondary
        toolTip = tip
    }
    @objc private func addTapped() { onAdd?() }
    @objc private func laterTapped() { onDismiss?() }
}


/// A group in the Groups section, after Herdr's spaces: a coloured initial,
/// the name, and the one mark that matters most among its desks.
final class GroupRow: NSView {
    var onClick: (() -> Void)?
    private let avatar = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let mark = MarkView()
    private(set) var selected = false
    private var hovering = false { didSet { needsDisplay = true } }

    /// A steady colour per group name, from a small palette that reads on
    /// both themes.
    static func colour(_ name: String) -> NSColor {
        let palette: [UInt32] = [0x3F7F6E, 0xC96442, 0x5B6FD6, 0x8A6BBF, 0xB5893A, 0x4F8FB3, 0xB0526B, 0x6E8B3D]
        var h: UInt32 = 2166136261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        let x = palette[Int(h % UInt32(palette.count))]
        return NSColor(srgbRed: CGFloat((x >> 16) & 0xff) / 255, green: CGFloat((x >> 8) & 0xff) / 255,
                       blue: CGFloat(x & 0xff) / 255, alpha: 1)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        avatar.alignment = .center
        avatar.font = .systemFont(ofSize: 10.5, weight: .bold)
        avatar.textColor = .white
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 5
        name.font = .systemFont(ofSize: 13.5)
        name.lineBreakMode = .byTruncatingTail
        count.font = .systemFont(ofSize: 11)
        for v in [avatar, name, count, mark] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        mark.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 18), avatar.heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 9),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -6),
            count.trailingAnchor.constraint(equalTo: mark.leadingAnchor, constant: -8),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.heightAnchor.constraint(equalToConstant: 16),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { nil }

    func configure(name n: String, desks: [DeskStatus], selected sel: Bool) {
        selected = sel
        name.stringValue = n
        name.textColor = Theme.ui.text
        avatar.stringValue = String(n.prefix(1)).uppercased()
        avatar.layer?.backgroundColor = GroupRow.colour(n).cgColor
        let marks = desks.map(Mark.init)
        let asking = marks.filter { $0 == .needsYou }.count
        let running = marks.filter { $0 != .none && $0 != .asleep }.count
        if asking > 0 {
            mark.mark = .needsYou
            mark.pillText = asking == 1 ? "1 needs you" : "\(asking) need you"
        } else if marks.contains(.done) { mark.mark = .done }
        else if marks.contains(.working) { mark.mark = .working }
        else { mark.mark = .none }
        // How many are running, of how many, when nothing more urgent shows.
        count.stringValue = running > 0 ? "\(running)/\(desks.count)" : "\(desks.count)"
        count.textColor = Theme.ui.dimText
        toolTip = "\(n): \(running) of \(desks.count) desks running" + (asking > 0 ? ", \(asking) waiting on you" : "")
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        let fill: NSColor? = selected ? Theme.ui.selected : (hovering ? Theme.ui.hover : nil)
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    // A click goes to the group; a drag of more than a few points moves it.
    var onRename: (() -> Void)?
    var onSort: (() -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    private var downAt: NSPoint?
    private var dragging = false
    override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow; dragging = false }
    override func mouseDragged(with e: NSEvent) {
        guard let start = downAt, onDragMoved != nil else { return }
        let p = e.locationInWindow
        if !dragging, hypot(p.x - start.x, p.y - start.y) > 4 { dragging = true; alphaValue = 0.45 }
        if dragging, let sv = superview { onDragMoved?(sv.convert(p, from: nil)) }
    }
    override func mouseUp(with e: NSEvent) {
        defer { downAt = nil; dragging = false; alphaValue = 1 }
        if dragging, let sv = superview { onDragEnded?(sv.convert(e.locationInWindow, from: nil)) }
        else if downAt != nil { onClick?() }
    }
    override func rightMouseDown(with e: NSEvent) {
        guard onRename != nil else { return }
        let m = NSMenu()
        let it = NSMenuItem(title: "Rename Group…", action: #selector(renameIt), keyEquivalent: "")
        it.target = self
        m.addItem(it)
        let s = NSMenuItem(title: "Sort Desks A to Z", action: #selector(sortIt), keyEquivalent: "")
        s.target = self
        m.addItem(s)
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
    @objc private func renameIt() { onRename?() }
    @objc private func sortIt() { onSort?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
