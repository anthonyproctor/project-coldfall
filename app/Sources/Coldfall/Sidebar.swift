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
    override func mouseExited(with e: NSEvent) { pointerInside = false; syncFloat() }

    /// "Move Ready Desks to Top": a desk waiting on you is shown at the top
    /// of the rail, under any pinned desks, until you have looked at it.
    var floatReady = true { didSet { if floatReady != oldValue { syncFloat(force: true) } } }
    var onToggleFloat: (() -> Void)?
    /// The desks floated to the top, as last drawn. This follows `waiting`,
    /// but only at a calm moment: never while the pointer is over the rail or
    /// a drag is under way, so a row doesn't move out from under a click.
    /// That includes the click that opens a ready desk: it stays where it
    /// was clicked until the pointer leaves the rail.
    private(set) var floated: [String] = []
    /// Rows in the pinned and floated zones. They don't drag, and a drop is
    /// never measured against them: their place on screen is not their
    /// place in the list.
    private var zoneRows: Set<Int> = []

    /// Bring `floated` in line with who is waiting, if now is a calm moment.
    func syncFloat(force: Bool = false) {
        guard let d = lastDesks else { return }
        let want = DeskOrder.floating(d, waiting: waiting, enabled: floatReady)
        guard want != floated, force || (!pointerInside && !isDragging) else { return }
        floated = want
        build(desks: d)
    }
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
    private var selected = -1
    private(set) var contentHeight: CGFloat = 0
    var collapsed: Set<String> = []

    override var isFlipped: Bool { true }   // lay out top-down inside the scroll view

    /// Per-desk status, keyed by name. Set by the controller each tick.
    var status: [String: DeskStatus] = [:] {
        didSet {
            for r in rows.values { r.status = status[r.deskName] ?? DeskStatus() }
            let q = NeedsYou.queue(status.map {
                NeedsYou.Entry(name: $0.key, activity: $0.value.activity, lastOutput: $0.value.lastOutput)
            })
            // The line and the header counts change the layout, so a change
            // in who is waiting rebuilds. Not mid-drag: that would pull the
            // row out from under the pointer. The next tick catches up.
            if q != waiting, dropLine.superview == nil, let d = lastDesks {
                waiting = q
                if !pointerInside { floated = DeskOrder.floating(d, waiting: q, enabled: floatReady) }
                build(desks: d)
            } else {
                syncFloat()
            }
        }
    }
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

    func build(desks: [Desk]) {
        lastDesks = desks
        subviews.forEach { $0.removeFromSuperview() }
        rows = [:]
        headers = []
        spans = []
        zoneRows = []
        let zones = DeskOrder.zones(desks, floated: floated)

        // Size from the scroll view's VISIBLE width, not our own. The first
        // build runs before the window has finished sizing, so our own width
        // was a stale, narrower number — rows stopped a hundred points short of
        // the rail and the "2m" floated mid-row instead of sitting flush right.
        let visible = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let w = max(visible, 190)
        var y: CGFloat = 10

        // What this region is, before any of its rows.
        let title = SectionTitle("Desks")
        title.frame = NSRect(x: 14, y: y, width: w - 28, height: 16)
        title.translatesAutoresizingMaskIntoConstraints = true
        title.autoresizingMask = [.width]
        addSubview(title)
        y += 24

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

        // Pinned desks: always here, in your order, whatever group they are in.
        for i in zones.pinned {
            let r = row(i, desks[i], indent: 4, y: y, width: w)
            r.showsPin = true
            r.onHide = { [weak self] in self?.onHideDesk?(i) }
            zoneRows.insert(i)
            y += DeskRow.height + 2
        }
        if !zones.pinned.isEmpty { y += 8 }

        if let text = NeedsYou.summary(waiting), let first = waiting.first {
            let strip = NeedsYouStrip(frame: NSRect(x: 10, y: y, width: w - 20, height: 26))
            strip.autoresizingMask = [.width]
            strip.configure(text)
            strip.onClick = { [weak self] in self?.onJumpToWaiting?(first) }
            strip.onClear = { [weak self] in self?.onClearWaiting?() }
            addSubview(strip)
            y += 34
        }

        // Desks that are ready for you, floated up under the line that
        // names them. Each goes back to its place once you've looked at it.
        for i in zones.floated {
            let r = row(i, desks[i], indent: 4, y: y, width: w)
            r.onHide = { [weak self] in self?.onHideDesk?(i) }
            zoneRows.insert(i)
            y += DeskRow.height + 2
        }
        if !zones.floated.isEmpty { y += 8 }

        // The live order, if on, with any group it doesn't know yet (just
        // created) after it in your order.
        let saved = DeskOrder.groups(desks)
        let order = groupOrder.map { live in live.filter { saved.contains($0) } + saved.filter { !live.contains($0) } } ?? saved
        for g in order {
            let all = desks.enumerated().filter { $0.element.group == g && !$0.element.hidden }
            // A desk shown in a zone above is not shown again here. A group
            // whose desks are all up there still shows its header, so the
            // group doesn't seem to vanish.
            let members = all.filter { !zones.contains($0.offset) }
            if all.isEmpty || (g == nil && members.isEmpty) { continue }

            if let g {
                let isDown = !collapsed.contains(g)
                let h = GroupHeader(frame: NSRect(x: 10, y: y, width: w - 20, height: 20))
                h.autoresizingMask = [.width]
                // Folded, a group would hide a waiting desk entirely.
                let inside = isDown ? 0 : members.filter { waiting.contains($0.element.name) }.count
                h.configure(title: g, expanded: isDown, waiting: inside)
                h.onClick = { [weak self] in self?.onToggleGroup?(g) }
                h.onRename = { [weak self] in self?.onRenameGroup?(g) }
                h.onSort = { [weak self] in self?.onSortDesks?() }
                // While groups sort themselves, dragging one would edit an
                // order you can't see, so headers don't drag then.
                if !liveOn {
                    h.onDragMoved = { [weak self] p in self?.groupDragMoved(g, to: p) }
                    h.onDragEnded = { [weak self] p in self?.groupDragEnded(g, at: p) }
                }
                addSubview(h)
                headers.append((g, h))
                y += 22
                if !isDown { spans.append((g, h.frame.minY, y)); y += 4; continue }
            }
            let top = y - 22

            for (i, d) in members {
                let r = row(i, d, indent: g == nil ? 4 : 12, y: y, width: w)
                r.onHide = { [weak self] in self?.onHideDesk?(i) }
                r.onDragMoved = { [weak self] p in self?.dragMoved(from: i, to: p) }
                r.onDragEnded = { [weak self] p in self?.dragEnded(from: i, at: p) }
                y += DeskRow.height + 2
            }
            if let g { spans.append((g, top, y)) }
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
                r.onClick = { [weak self] in self?.select(i); self?.onSelect?(i) }
                r.onRemove = { [weak self] in self?.onRemoveDesk?(i) }
                r.onReveal = d.agent == nil ? nil : { [weak self] in self?.onRevealAgent?(i) }
                r.onMakeDefault = d.isDefault || d.runtime == "shell"
                    ? nil : { [weak self] in self?.onMakeDefault?(i) }
                r.onRename = { [weak self] in self?.onRenameDesk?(i) }
                r.onStop = { [weak self] in self?.onStopDesk?(i) }
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
                addSubview(r)
                rows[i] = r
                return r
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
        for h in headers where h.view.frame.insetBy(dx: -10, dy: -2).contains(p) {
            return (.endOfGroup(h.group), h.view.frame.maxY)
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
        let up = NSMenuItem(title: "Move Ready Desks to Top", action: #selector(toggleFloat), keyEquivalent: "")
        up.target = self
        up.state = floatReady ? .on : .off
        up.toolTip = "A desk that is waiting on you rises to the top of the rail, under any pinned desks, "
            + "and goes back to its place once you've looked at it."
        m.addItem(up)
        let it = NSMenuItem(title: "Sort Desks A to Z", action: #selector(sortAll), keyEquivalent: "")
        it.target = self
        m.addItem(it)
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
    @objc private func sortAll() { onSortDesks?() }
    @objc private func toggleLive() { onToggleLive?() }
    @objc private func toggleFloat() { onToggleFloat?() }

    func select(_ i: Int) {
        lastSelected = i
        selected = i
        for (j, r) in rows { r.selected = (j == i) }
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
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = Theme.ui.dimText
        label.frame = bounds
        label.autoresizingMask = [.width]
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    func configure(title: String, expanded: Bool, waiting: Int = 0) {
        let s = NSMutableAttributedString(string: (expanded ? "▾ " : "▸ ") + title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: Theme.ui.dimText,
        ])
        if waiting > 0 {
            s.append(NSAttributedString(string: "  ● \(waiting)", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.systemGreen,
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

    func configure(_ text: String) { label.stringValue = "● " + text }

    override func mouseUp(with e: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// "▸ 3 HIDDEN" at the bottom of the rail. Click to list them.
final class HiddenHeader: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = Theme.ui.dimText
        label.frame = bounds
        label.autoresizingMask = [.width]
        addSubview(label)
        toolTip = "Desks you've hidden. Right-click one to unhide it."
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int, expanded: Bool) {
        label.stringValue = (expanded ? "▾ " : "▸ ") + "\(count) HIDDEN"
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
