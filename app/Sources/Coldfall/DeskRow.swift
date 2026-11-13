// One desk in the rail, as Herdr lays out an agent:
//
//     [logo]  hub                      2m   ●
//
// The vendor's icon, the name, how long ago it last did anything, and one
// mark at the right for what it needs (Needs you, working, done, idle). The
// details the old second line carried are in the tooltip.
//
// A row holds its state as data and draws from it. (An earlier row packed
// everything into one attributed button title and parsed it back out, which
// is how an activity badge once shipped that never appeared at all.)

import AppKit
import ColdfallCore

/// What the rail needs to know about a desk, separate from its config.
struct DeskStatus: Equatable {
    var activity: DeskActivity = .quiet
    /// When it last wrote anything, for the "2m" on the right.
    var lastOutput: Date?
    /// Whether its process has been started this session.
    var running = false
    /// Resident memory of the desk's whole process tree, e.g. "940 MB".
    var memory: String?
    /// Servers, hooks, skills or plugins new or changed since last looked at.
    var news: Int = 0
    /// The dim text beside the name: why it is waiting, or what it says
    /// it is doing (see DeskDetail).
    var detail: String?
    /// Put to sleep by Coldfall: not running, and it resumes when opened.
    var asleep = false
}

final class DeskRow: NSView {

    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?
    var onReveal: (() -> Void)?
    var onMakeDefault: (() -> Void)?
    var onRename: (() -> Void)?
    var onStop: (() -> Void)?
    var onMcp: (() -> Void)?
    var onInventory: (() -> Void)?
    var onHide: (() -> Void)?
    var onUnhide: (() -> Void)?
    /// Pin to the top of the rail, or take it back off. Whichever applies
    /// is set; a hidden desk gets neither.
    var onPin: (() -> Void)?
    var onUnpin: (() -> Void)?
    /// A small pin after the name, for a pinned desk.
    var showsPin = false { didSet { pinIcon.isHidden = !showsPin } }
    private let pinIcon = NSImageView()
    /// Toggle whether opening this desk asks about starting fresh. Nil where
    /// it can't be started fresh, so the item isn't offered.
    var onToggleAskResume: (() -> Void)?
    /// Show this desk's screen over the current one (see PeekPanel).
    var onPeek: (() -> Void)?
    var onMarkUnread: (() -> Void)?
    var onBeside: (() -> Void)?
    /// Give the desk a colour (a palette name), or nil to take it away.
    var onColor: ((String?) -> Void)?
    private var colorName: String?
    private let info = NSTextField(labelWithString: "")
    var asksResume = true
    /// Drag to reorder. Points are in the row's superview (the rail).
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?

    let deskName: String
    private let runtime: String
    /// "claude-second" for a desk on another Claude account.
    private let label: String
    private let isDefault: Bool

    /// Which agent runs it: the vendor's logo when there's one in
    /// ~/.config/coldfall/icons, else a letter on its colour (VendorIcon).
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    /// What it's doing: Needs you, working, done, idle (Mark).
    private let mark = MarkView()
    /// What the old second line said (vendor, state, budget, memory, news),
    /// now the tooltip.
    private var detail = ""

    var selected = false { didSet { if selected != oldValue { restyle() } } }
    /// Restyles only on a real change. The rail sets this for every row on
    /// every tick, and a full restyle each time was the rail repainting all
    /// of its rows about three times a second while nothing moved.
    var status = DeskStatus() { didSet { if status != oldValue { restyle() } } }
    /// This desk's week against its budget, if it has one.
    var budget: DeskBudget.Status = .unset { didSet { if budget != oldValue { restyle() } } }
    /// Advanced by the rail's timer, to age the "now" / "2m" label.
    var tick = 0 {
        didSet {
            guard case .working = status.activity else { return }
            // The "now" / "2m" label ages without the status changing.
            let t = status.lastOutput.map(Self.ago) ?? ""
            if time.stringValue != t { time.stringValue = t }
        }
    }

    private var hovering = false { didSet { needsDisplay = true } }

    static let height: CGFloat = 30

    init(desk: Desk) {
        deskName = desk.name
        colorName = desk.color
        runtime = desk.runtime
        label = desk.vendorLabel
        isDefault = desk.isDefault
        super.init(frame: .zero)
        wantsLayer = true

        icon.image = VendorIcon.image(runtime: desk.runtime, icon: desk.icon, size: 16)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.toolTip = desk.runtime == "shell" ? "shell" : desk.vendorLabel
        info.lineBreakMode = .byTruncatingTail
        info.isSelectable = false
        info.font = .systemFont(ofSize: 11.5)
        info.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        info.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.required, for: .horizontal)
        for v in [icon, name, time, mark, pinIcon, info] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for f in [name, time] { f.lineBreakMode = .byTruncatingTail; f.isSelectable = false }
        time.alignment = .right
        for v in [time, mark] as [NSView] {
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
            v.setContentHuggingPriority(.required, for: .horizontal)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pinIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8.5, weight: .regular))
        pinIcon.contentTintColor = Theme.ui.dimText
        pinIcon.isHidden = true

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),

            pinIcon.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 5),
            pinIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinIcon.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -6),
            info.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            info.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            info.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -6),

            time.trailingAnchor.constraint(equalTo: mark.leadingAnchor, constant: -8),
            time.centerYAnchor.constraint(equalTo: centerYAnchor),

            mark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.heightAnchor.constraint(equalToConstant: 16),
        ])

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    // MARK: - drawing

    override func draw(_ dirty: NSRect) {
        // A soft rounded fill for the selected and hovered rows, VS Code's
        // treatment, rather than a hard full-width band.
        let fill: NSColor? = selected ? Theme.ui.selected : (hovering ? Theme.ui.hover : nil)
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 9, yRadius: 9).fill()
        }
        // The desk's own colour, as a bar down the row's leading edge.
        if let t = DeskTint.color(colorName) {
            t.setFill()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 6, width: 3, height: bounds.height - 12), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    func restyle() {
        let ui = Theme.ui

        name.stringValue = deskName
        name.font = .systemFont(ofSize: 14, weight: selected ? .medium : .regular)

        // The mark carries the state; the name stays the name. Herdr's
        // rule, and the one that reads: colour in one small place, not the
        // whole row.
        mark.mark = Mark(status)
        name.textColor = status.running || selected ? ui.text : ui.text.withAlphaComponent(0.62)

        // Why it waits, in amber; or what it's on, dim. A pinned desk's pin
        // sits where this goes, and the pin says more there.
        info.stringValue = showsPin ? "" : (status.detail ?? "")
        mark.compact = !info.stringValue.isEmpty
        info.textColor = Mark(status) == .needsYou ? MarkView.pillInk : ui.dimText
        time.stringValue = status.lastOutput.map(Self.ago) ?? ""
        time.font = .systemFont(ofSize: 11)
        switch budget {
        case .over: time.textColor = .systemRed
        case .near: time.textColor = .systemOrange
        default: time.textColor = status.news > 0 ? ui.accent : ui.dimText
        }

        // What it is and what it's doing, for the tooltip.
        let state: String
        switch Mark(status) {
        case .needsYou: state = "needs you"
        case .working: state = "working"
        case .done: state = "done"
        case .idle: state = "idle"
        case .asleep: state = "asleep, opens where it left off"
        case .none: state = "not started"
        }
        var parts: [String] = [runtime == "shell" ? "shell" : label + (isDefault ? " home" : ""), state]
        if let b = DeskBudget.short(budget) { parts.append(b) }
        if let m = status.memory { parts.append(m) }
        if status.news > 0 { parts.append("\(status.news) new") }
        if let d = status.detail { parts.append(d) }
        detail = parts.joined(separator: " \u{00B7} ")
        var tips: [String] = [deskName + ": " + detail + (showsPin ? " · pinned" : "")]
        if let b = DeskBudget.label(budget) { tips.append("\(deskName): \(b)") }
        if status.news > 0 {
            tips.append("\(status.news) new on this desk: servers, hooks, skills or plugins added since you last looked. "
                        + "Right-click, See What's New, to see them and clear this.")
        }
        toolTip = tips.isEmpty ? nil : tips.joined(separator: "\n")

        needsDisplay = true
    }

    /// "now", "4m", "2h", "3d" — Cursor's compact form.
    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 45 { return "now" }
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    // MARK: - input

    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    // A click selects; a drag of more than a few points reorders instead.
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
        else if downAt != nil {
            // Option-click: a look at a running desk without switching to it.
            if e.modifierFlags.contains(.option), status.running, !selected, let p = onPeek { p() } else { onClick?() }
        }
    }

    /// Refresh the "2m" label without a full restyle. Called by the rail.
    func refreshAge() {
        let t = status.lastOutput.map(Self.ago) ?? ""
        if time.stringValue != t { time.stringValue = t }
    }

    override func rightMouseDown(with e: NSEvent) {
        NSMenu.popUpContextMenu(actionMenu(), with: e, for: self)
    }

    /// This desk's right-click menu. The command palette offers it too, for
    /// the desk on screen.
    func actionMenu() -> NSMenu {
        let m = NSMenu()
        let entries = DeskMenu.items(runtime: runtime, running: status.running, hidden: onUnhide != nil,
                                     canReveal: onReveal != nil, canMakeDefault: onMakeDefault != nil,
                                     hasInventory: onInventory != nil, hasMcp: onMcp != nil,
                                     askResume: onToggleAskResume != nil ? asksResume : nil,
                                     pinned: onUnpin != nil ? true : (onPin != nil ? false : nil),
                                     news: status.news, canPeek: onPeek != nil && !selected,
                                     canMarkUnread: onMarkUnread != nil && Mark(status) != .done && Mark(status) != .needsYou,
                                     canBeside: onBeside != nil && !selected)
        for e in entries {
            guard e.action != .separator else { m.addItem(NSMenuItem.separator()); continue }
            if e.action == .color {
                guard onColor != nil else { continue }
                let item = NSMenuItem(title: e.title, action: nil, keyEquivalent: "")
                item.image = e.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                let sub = NSMenu()
                let none = NSMenuItem(title: "None", action: #selector(pickColor(_:)), keyEquivalent: "")
                none.target = self
                none.image = DeskTint.swatch(nil)
                none.state = colorName == nil ? .on : .off
                sub.addItem(none)
                sub.addItem(.separator())
                for c in DeskColor.palette {
                    let it = NSMenuItem(title: c.name.capitalized, action: #selector(pickColor(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = c.name
                    it.image = DeskTint.swatch(DeskTint.color(c.name))
                    it.state = colorName == c.name ? .on : .off
                    sub.addItem(it)
                }
                item.submenu = sub
                m.addItem(item)
                continue
            }
            let sel: Selector
            switch e.action {
            case .peek:        sel = #selector(peek)
            case .markUnread:  sel = #selector(markUnread)
            case .beside:      sel = #selector(openBeside)
            case .color:       continue
            case .reveal:      sel = #selector(reveal)
            case .makeDefault: sel = #selector(makeDefault)
            case .rename:      sel = #selector(rename)
            case .inventory:   sel = #selector(inventory)
            case .mcp:         sel = #selector(mcp)
            case .stop:        sel = #selector(stop)
            case .pin:         sel = #selector(pin)
            case .unpin:       sel = #selector(unpin)
            case .hide:        sel = #selector(hide)
            case .unhide:      sel = #selector(unhide)
            case .askResume:   sel = #selector(toggleAskResume)
            case .remove:      sel = #selector(remove)
            case .separator:   continue
            }
            let it = NSMenuItem(title: e.title, action: sel, keyEquivalent: "")
            it.target = self
            it.toolTip = e.subtitle
            if let c = e.checked { it.state = c ? .on : .off }
            // The line underneath says what the item does, which is the
            // difference between stopping a desk and removing it.
            if #available(macOS 14.4, *), let sub = e.subtitle { it.subtitle = sub }
            let tint: NSColor? = e.tone == .danger ? .systemRed : (e.tone == .caution ? .systemOrange : nil)
            if let name = e.symbol,
               let img = NSImage(systemSymbolName: name, accessibilityDescription: e.title) {
                it.image = tint.map {
                    img.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [$0])) ?? img
                } ?? img
            }
            // Red for the one that changes the desk list. Everything else
            // keeps the system's own colour, so red still means something.
            if e.tone == .danger {
                it.attributedTitle = NSAttributedString(
                    string: e.title,
                    attributes: [.foregroundColor: NSColor.systemRed,
                                 .font: NSFont.menuFont(ofSize: 0)])
            }
            m.addItem(it)
        }
        return m
    }
    @objc private func remove() { onRemove?() }
    @objc private func peek() { onPeek?() }
    @objc private func markUnread() { onMarkUnread?() }
    @objc private func openBeside() { onBeside?() }
    @objc private func pickColor(_ item: NSMenuItem) { onColor?(item.representedObject as? String) }
    @objc private func rename() { onRename?() }
    @objc private func stop() { onStop?() }
    @objc private func mcp() { onMcp?() }
    @objc private func inventory() { onInventory?() }
    @objc private func hide() { onHide?() }
    @objc private func pin() { onPin?() }
    @objc private func unpin() { onUnpin?() }
    @objc private func unhide() { onUnhide?() }
    @objc private func toggleAskResume() { onToggleAskResume?() }
    @objc private func reveal() { onReveal?() }
    @objc private func makeDefault() { onMakeDefault?() }
}

/// A small uppercase section title — VS Code's "EXPLORER", Cursor's
/// "READY FOR REVIEW". Tells you what a region is without reading its rows.
final class SectionTitle: NSTextField {
    convenience init(_ text: String) {
        self.init(labelWithString: "")
        let a = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: Theme.ui.dimText,
        ])
        attributedStringValue = a
        translatesAutoresizingMaskIntoConstraints = false
    }
}
