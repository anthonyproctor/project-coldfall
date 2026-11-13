// The tab row over the terminal, after Herdr's:
//
//   [✳ work  Needs you] [✳ client-a ○] [◎ client-b ◌]   +      Write a prompt…
//
// One tab per running desk in the current desk's group (DeskTabs in the
// core decides which), each with the vendor's logo, the name and the same
// state mark as the desk list. Click to switch; the × that shows on hover
// stops the desk, through the same question Stop Desk asks. "+" starts
// another desk from this group, or makes a new one.

import AppKit
import ColdfallCore

final class TabBar: NSView {
    struct Tab: Equatable {
        let name: String
        let runtime: String
        let icon: String?
        let status: DeskStatus
        var color: String? = nil
    }

    var onSelect: ((String) -> Void)?
    var onStop: ((String) -> Void)?
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
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    /// Show these tabs, `current` selected. Views are reused when the set of
    /// names is unchanged, so a state tick only repaints marks.
    func set(_ wanted: [Tab], current: String?) {
        all = wanted
        // What fits between the edge and the buttons on the right.
        let space = bounds.width - 8 - (prompt.intrinsicContentSize.width + 10) - (changesBtn.intrinsicContentSize.width + 10) - 28 - 40 - 12
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
        if tabs.map(\.name) != shown.map(\.name) {
            for v in views { row.removeArrangedSubview(v); v.removeFromSuperview() }
            views = tabs.map { t in
                let v = TabView(name: t.name)
                v.onClick = { [weak self] in self?.onSelect?(t.name) }
                v.onClose = { [weak self] in self?.onStop?(t.name) }
                row.addArrangedSubview(v)
                return v
            }
        }
        for (v, t) in zip(views, tabs) {
            v.configure(t, selected: t.name == current)
        }
        shown = tabs
        self.current = current
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
        if n.width != was, !all.isEmpty { set(all, current: current) }
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

/// One tab: logo, name, mark; an × in place of the mark under the pointer.
private final class TabView: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?

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

        for v in [iconView, label, mark, close, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1
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
    override func mouseDown(with e: NSEvent) { onClick?() }
    @objc private func closeIt() { onClose?() }
}
