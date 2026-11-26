// The tab row over the terminal, after Herdr's:
//
//   [✳ work  Needs you] [✳ client-a ○] [◎ client-b ◌]   +      Write a prompt…
//
// One tab per running desk in the current desk's group (DeskTabs in the
// core decides which), each with the vendor's logo, the name and the same
// state mark as the desk list. Click to switch; the × that shows on hover
// stops the desk, through the same question Stop Desk asks. "+" starts
// another desk from this group, or makes a new one.
//
// Tabs can be dragged into another order, and kept together in groups under
// a coloured label that folds them away, the way a browser's tabs can
// (TabLayout in the core holds the arrangement and the rules).

import AppKit
import ColdfallCore

final class TabBar: NSView {
    struct Tab: Equatable {
        let name: String
        let runtime: String
        let icon: String?
        let status: DeskStatus
        var color: String? = nil
        /// The tab group it is in (an index), and its colour, if any.
        var group: Int? = nil
        var groupColor: String? = nil
    }
    /// A tab group's label.
    struct Label: Equatable {
        let group: Int
        let name: String
        let color: String
        let collapsed: Bool
        /// How many of its tabs are folded away.
        let hidden: Int
    }
    enum Entry: Equatable {
        case tab(Tab)
        case label(Label)
    }

    var onSelect: ((String) -> Void)?
    /// A tab was dropped in front of another (nil: after the last one),
    /// with the pointer over that group's label or tabs (nil: over none).
    var onMove: ((String, String?, Int?) -> Void)?
    /// A group's label was clicked: fold or unfold it.
    var onToggleGroup: ((Int) -> Void)?
    var onGroupMenu: ((Int) -> NSMenu?)?
    var onStop: ((String) -> Void)?
    /// A tab's right-click menu: the same one its desk has in the list.
    var onMenu: ((String) -> NSMenu?)?
    /// "+": the menu is built by the controller, which knows the desks.
    var plusMenu: (() -> NSMenu?)?
    var onPromptHelper: (() -> Void)?
    var onChanges: (() -> Void)?
    private let changesBtn = NSButton(title: "Changes", target: nil, action: nil)

    static let height: CGFloat = 36

    private let row = NSStackView()
    private let plus = NSButton()
    private let prompt = NSButton(title: "Write a prompt…", target: nil, action: nil)
    private var views: [TabView] = []
    private var shown: [Tab] = []
    private var current: String?
    /// The row as asked for, labels and all, and as last built.
    private var entries: [Entry] = []
    private var built: [Entry] = []
    private var labels: [NSView] = []
    /// Where a dragged tab would land.
    private let dropLine = NSView()
    private var dragging: String?
    private var dropBefore: String??
    /// Every tab asked for, and the ones that didn't fit (the "more" menu).
    private var all: [Tab] = []
    private var overflow: [Tab] = []
    private let more = NSButton()
    /// Takes no room while there is nothing behind it.
    private lazy var moreGone = more.widthAnchor.constraint(equalToConstant: 0)
    /// Narrower than this and a tab's name is unreadable.
    private static let tabRoom: CGFloat = 104

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        addSubview(row)

        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Start a desk")
        plus.imagePosition = .imageOnly
        plus.isBordered = false
        plus.bezelStyle = .inline
        plus.toolTip = "Start another desk in this group"
        plus.target = self; plus.action = #selector(showPlus)
        plus.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plus)

        more.bezelStyle = .inline
        more.isBordered = false
        more.font = .systemFont(ofSize: 11.5, weight: .medium)
        more.toolTip = "More running desks in this group"
        more.target = self; more.action = #selector(showMore)
        more.translatesAutoresizingMaskIntoConstraints = false
        more.setContentCompressionResistancePriority(.required, for: .horizontal)
        more.isHidden = true
        addSubview(more)
        moreGone.isActive = true

        prompt.target = self; prompt.action = #selector(writePrompt)
        prompt.bezelStyle = .inline
        prompt.isBordered = false
        prompt.font = .systemFont(ofSize: 12)
        prompt.toolTip = "Build and copy a prompt. Nothing is sent."
        prompt.translatesAutoresizingMaskIntoConstraints = false
        prompt.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(prompt)

        changesBtn.target = self; changesBtn.action = #selector(showChanges)
        changesBtn.bezelStyle = .inline
        changesBtn.isBordered = false
        changesBtn.font = .systemFont(ofSize: 12)
        changesBtn.toolTip = "What this desk changed in its folder, to read and comment on  ⇧⌘G"
        changesBtn.translatesAutoresizingMaskIntoConstraints = false
        changesBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(changesBtn)

        NSLayoutConstraint.activate([
            changesBtn.trailingAnchor.constraint(equalTo: prompt.leadingAnchor, constant: -10),
            changesBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            more.leadingAnchor.constraint(equalTo: row.trailingAnchor, constant: 4),
            more.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            plus.leadingAnchor.constraint(equalTo: more.trailingAnchor, constant: 2),
            plus.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 24),
            plus.heightAnchor.constraint(equalToConstant: 24),
            plus.trailingAnchor.constraint(lessThanOrEqualTo: changesBtn.leadingAnchor, constant: -8),
            prompt.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            prompt.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        dropLine.wantsLayer = true
        dropLine.layer?.cornerRadius = 1
        dropLine.isHidden = true
        addSubview(dropLine)
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    /// Show these tabs, `current` selected. Views are reused when the set of
    /// names is unchanged, so a state tick only repaints marks.
    func set(_ wanted: [Tab], current: String?) { set(wanted.map { .tab($0) }, current: current) }

    func set(_ wantedEntries: [Entry], current: String?) {
        entries = wantedEntries
        let wanted: [Tab] = wantedEntries.compactMap { if case .tab(let t) = $0 { return t } else { return nil } }
        let wantedLabels: [Label] = wantedEntries.compactMap { if case .label(let l) = $0 { return l } else { return nil } }
        all = wanted
        // What fits between the edge and the buttons on the right. A label
        // takes about two thirds of a tab's least room.
        let space = bounds.width - 8 - (prompt.intrinsicContentSize.width + 10) - (changesBtn.intrinsicContentSize.width + 10) - 28 - 40 - 12
            - CGFloat(wantedLabels.count) * Self.tabRoom * 0.66
        let room = bounds.width > 0 ? max(1, Int(space / Self.tabRoom)) : wanted.count
        if ProcessInfo.processInfo.environment["COLDFALL_SNAPSHOT_DEBUG"] != nil { print("tabs: width \(bounds.width) room \(room) of \(wanted.count)") }
        let fit = DeskTabs.fit(wanted.map(\.name), current: current, room: room)
        let tabs = fit.shown.compactMap { n in wanted.first { $0.name == n } }
        overflow = fit.more.compactMap { n in wanted.first { $0.name == n } }
        more.isHidden = overflow.isEmpty
        moreGone.isActive = overflow.isEmpty
        if !overflow.isEmpty {
            // The count turns amber when a desk behind it needs you.
            let asking = overflow.contains { Mark($0.status) == .needsYou }
            more.title = "+\(overflow.count)"
            more.contentTintColor = asking ? MarkView.amber : Theme.ui.dimText
        }
        // The row to build: the tabs that fit, and the label of any group
        // with a tab showing or tabs folded away.
        let fits = Set(tabs.map(\.name))
        var row2: [Entry] = []
        for (i, e) in wantedEntries.enumerated() {
            switch e {
            case .tab(let t): if fits.contains(t.name) { row2.append(e) }
            case .label(let l):
                // Its tabs are the ones that follow it, up to the next label
                // or a tab outside the group.
                var has = l.hidden > 0
                for next in wantedEntries[(i + 1)...] {
                    guard case .tab(let t) = next, t.groupColor != nil else { break }
                    if fits.contains(t.name) { has = true; break }
                }
                if has { row2.append(e) }
            }
        }
        func shape(_ e: Entry) -> String {
            switch e {
            case .tab(let t): return "t:" + t.name
            case .label(let l): return "l:\(l.group):\(l.name):\(l.color):\(l.collapsed):\(l.hidden)"
            }
        }
        if row2.map(shape) != built.map(shape) {
            for v in row.arrangedSubviews { row.removeArrangedSubview(v); v.removeFromSuperview() }
            views = []
            labels = []
            for e in row2 {
                switch e {
                case .tab(let t):
                    let v = TabView(name: t.name)
                    v.onClick = { [weak self] in self?.onSelect?(t.name) }
                    v.onClose = { [weak self] in self?.onStop?(t.name) }
                    v.onMenu = { [weak self] in self?.onMenu?(t.name) }
                    v.onDrag = { [weak self] p, done in self?.drag(t.name, to: p, done: done) }
                    row.addArrangedSubview(v)
                    views.append(v)
                case .label(let l):
                    let v = GroupLabelView(l)
                    v.onClick = { [weak self] in self?.onToggleGroup?(l.group) }
                    v.onMenu = { [weak self] in self?.onGroupMenu?(l.group) }
                    row.addArrangedSubview(v)
                    labels.append(v)
                }
            }
            built = row2
        }
        for (v, t) in zip(views, tabs) {
            v.configure(t, selected: t.name == current)
        }
        shown = tabs
        self.current = current
    }

    /// A tab is being dragged: show where it would land, and on release
    /// say so. `point` is in the window. Dropping a tab where it already
    /// stands is nothing.
    private func drag(_ name: String, to point: NSPoint, done: Bool) {
        let x = convert(point, from: nil).x
        let names = shown.map(\.name)
        guard let me = names.firstIndex(of: name), views.count == names.count else { endDrag(); return }
        // The gap the pointer is nearest: in front of the first tab whose
        // middle is to its right, else after the last.
        let at = views.firstIndex { $0.convert($0.bounds, to: self).midX > x } ?? views.count
        let stays = at == me || at == me + 1
        // The group the pointer is over: from the middle of its label to the
        // end of its last tab.
        var into: Int?
        for case .label(let l) in built {
            let mine = zip(views, shown).filter { $0.1.group == l.group }.map { $0.0.convert($0.0.bounds, to: self) }
            guard let end = mine.map(\.maxX).max(),
                  let lv = zip(labels, built.compactMap { e -> Label? in if case .label(let x) = e { return x } else { return nil } })
                    .first(where: { $0.1.group == l.group })?.0 else { continue }
            if x >= lv.convert(lv.bounds, to: self).midX, x <= end { into = l.group }
        }
        let own = shown[me].group
        if done {
            endDrag()
            // Let go where it stands, in or out of its group as before: nothing.
            guard !(stays && into == own) else { return }
            // In front of the tab after the gap; past the last tab that fits
            // means in front of the first one that didn't.
            let others = names.filter { $0 != name }
            let gap = at > me ? at - 1 : at
            let allNames = all.map(\.name).filter { $0 != name }
            let before: String? = gap < others.count ? others[gap]
                : (others.last.flatMap { allNames.firstIndex(of: $0) }.flatMap { $0 + 1 < allNames.count ? allNames[$0 + 1] : nil })
            onMove?(name, before, into)
            return
        }
        dragging = name
        views[me].alphaValue = 0.45
        dropLine.isHidden = stays
        guard !stays else { return }
        let edge: CGFloat = at < views.count ? views[at].convert(views[at].bounds, to: self).minX - 3
            : views[views.count - 1].convert(views[views.count - 1].bounds, to: self).maxX + 1
        dropLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropLine.frame = NSRect(x: edge, y: (bounds.height - 22) / 2, width: 2, height: 22)
    }

    /// What is drawn, in order, labels in brackets: for the self-test.
    var drawnRow: [String] {
        built.map { e in
            switch e {
            case .tab(let t): return t.name
            case .label(let l): return "[\(l.name)]"
            }
        }
    }

    /// The self-test's hand: press on a tab, travel to just left of
    /// `before` (or past the last tab), and let go, through the same code a
    /// real drag runs.
    func dragForTest(_ name: String, before: String?) {
        layoutSubtreeIfNeeded()
        let names = shown.map(\.name)
        guard views.count == names.count, !views.isEmpty else { return }
        let x: CGFloat
        if let b = before, let i = names.firstIndex(of: b) { x = views[i].convert(views[i].bounds, to: self).minX + 2 }
        else { x = views[views.count - 1].convert(views[views.count - 1].bounds, to: self).maxX + 30 }
        let p = convert(NSPoint(x: x, y: bounds.midY), to: nil)
        drag(name, to: p, done: false)
        drag(name, to: p, done: true)
    }

    private func endDrag() {
        dragging = nil
        dropLine.isHidden = true
        for v in views { v.alphaValue = 1 }
    }

    func restyle() {
        let ui = Theme.ui
        layer?.backgroundColor = ui.sidebar.cgColor
        plus.contentTintColor = ui.dimText
        prompt.contentTintColor = ui.dimText
        changesBtn.contentTintColor = ui.dimText
        for (v, t) in zip(views, shown) { v.configure(t, selected: t.name == current, force: true) }
    }

    override func setFrameSize(_ n: NSSize) {
        let was = frame.width
        super.setFrameSize(n)
        if n.width != was, !all.isEmpty { set(entries, current: current) }
    }

    @objc private func showMore() {
        let m = NSMenu()
        for t in overflow {
            let item = NSMenuItem(title: t.name, action: #selector(pickMore(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = t.name
            item.image = VendorIcon.image(runtime: t.runtime, icon: t.icon, size: 14)
            if Mark(t.status) == .needsYou { item.title = t.name + "  ·  needs you" }
            m.addItem(item)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }
    @objc private func pickMore(_ item: NSMenuItem) {
        if let n = item.representedObject as? String { onSelect?(n) }
    }

    @objc private func showPlus() {
        guard let m = plusMenu?() else { return }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: plus.bounds.height + 4), in: plus)
    }
    @objc private func writePrompt() { onPromptHelper?() }
    @objc private func showChanges() { onChanges?() }
}

/// A tab group's label: its name on its colour. Click to fold the group's
/// tabs away or bring them back; right-click to rename, recolour or ungroup.
private final class GroupLabelView: NSView {
    var onClick: (() -> Void)?
    var onMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() ?? super.menu(for: event) }

    init(_ l: TabBar.Label) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        let tint = DeskTint.color(l.color) ?? .systemGray
        layer?.backgroundColor = tint.withAlphaComponent(l.collapsed ? 0.9 : 0.78).cgColor
        let text = NSTextField(labelWithString: l.collapsed && l.hidden > 0 ? "\(l.name)  \(l.hidden)" : l.name)
        text.font = .systemFont(ofSize: 11.5, weight: .semibold)
        // Dark ink on the palette's mid-tones reads in both themes.
        text.textColor = NSColor(white: 0.08, alpha: 0.92)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        toolTip = l.collapsed
            ? "\(l.name): \(l.hidden) tab\(l.hidden == 1 ? "" : "s") folded away. Click to show."
            : "\(l.name). Click to fold its tabs away."
        setAccessibilityLabel("Tab group \(l.name)")
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            widthAnchor.constraint(lessThanOrEqualToConstant: 150),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control), let m = onMenu?() { NSMenu.popUpContextMenu(m, with: e, for: self); return }
        onClick?()
    }
}

/// One tab: logo, name, mark; an × in place of the mark under the pointer.
private final class TabView: NSView {
    var onClick: (() -> Void)?
    /// Dragged to a point in the window; `true` when let go.
    var onDrag: ((NSPoint, Bool) -> Void)?
    private var downAt: NSPoint?
    private var dragged = false
    private let groupBar = NSView()
    var onClose: (() -> Void)?
    var onMenu: (() -> NSMenu?)?
    // Right-click and control-click both come here.
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() ?? super.menu(for: event) }

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let mark = MarkView()
    private let close = NSButton()
    private let bar = NSView()
    private var tab: TabBar.Tab?
    private var selected = false
    private var hovering = false { didSet { if hovering != oldValue { refresh() } } }

    init(name: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7

        label.stringValue = name
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stop desk")
        close.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        close.imagePosition = .imageOnly
        close.isBordered = false
        close.bezelStyle = .inline
        close.toolTip = "Stop this desk"
        close.target = self; close.action = #selector(closeIt)

        for v in [iconView, label, mark, close, bar, groupBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1
        // The tab group's colour, as a line along the top: the desk's own
        // colour already has the bottom.
        groupBar.wantsLayer = true
        groupBar.layer?.cornerRadius = 1
        NSLayoutConstraint.activate([
            groupBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            groupBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            groupBar.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            groupBar.heightAnchor.constraint(equalToConstant: 2),
        ])
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            bar.heightAnchor.constraint(equalToConstant: 2),
        ])
        let tail = NSLayoutGuide()
        addLayoutGuide(tail)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.centerXAnchor.constraint(equalTo: mark.trailingAnchor, constant: -5),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func configure(_ t: TabBar.Tab, selected: Bool, force: Bool = false) {
        guard force || t != tab || selected != self.selected else { return }
        let iconChanged = force || t.runtime != tab?.runtime || t.icon != tab?.icon
        tab = t
        self.selected = selected
        if iconChanged { iconView.image = VendorIcon.image(runtime: t.runtime, icon: t.icon, size: 15) }
        mark.mark = Mark(t.status)
        var tip = t.name
        if !t.status.running { tip += " · not running" }
        toolTip = tip
        refresh()
    }

    private func refresh() {
        let ui = Theme.ui
        let running = tab?.status.running ?? false
        layer?.backgroundColor = selected ? ui.selected.cgColor : (hovering ? ui.hover.cgColor : NSColor.clear.cgColor)
        // The desk's own colour, as a line under its tab.
        bar.isHidden = tab?.color == nil
        bar.layer?.backgroundColor = DeskTint.color(tab?.color)?.cgColor
        groupBar.isHidden = tab?.groupColor == nil
        groupBar.layer?.backgroundColor = DeskTint.color(tab?.groupColor)?.cgColor
        label.font = .systemFont(ofSize: 12.5, weight: selected ? .semibold : .regular)
        label.textColor = selected ? ui.text : (running ? ui.text.withAlphaComponent(0.82) : ui.dimText)
        // The × takes the mark's place under the pointer, so the tab keeps
        // its width; a stopped desk has nothing to stop.
        let showClose = hovering && running
        close.isHidden = !showClose
        mark.isHidden = showClose
        close.contentTintColor = ui.dimText
        iconView.alphaValue = running ? 1 : 0.55
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control), let m = onMenu?() { NSMenu.popUpContextMenu(m, with: e, for: self); return }
        downAt = e.locationInWindow
        dragged = false
        onClick?()
    }
    // A press that travels is a drag: the tab goes where it is let go.
    override func mouseDragged(with e: NSEvent) {
        guard let d = downAt else { return }
        if !dragged, abs(e.locationInWindow.x - d.x) < 6 { return }
        dragged = true
        onDrag?(e.locationInWindow, false)
    }
    override func mouseUp(with e: NSEvent) {
        if dragged { onDrag?(e.locationInWindow, true) }
        downAt = nil
        dragged = false
    }
    @objc private func closeIt() { onClose?() }
}
