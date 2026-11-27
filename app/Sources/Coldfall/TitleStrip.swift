// The strip across the top of the main window, laid out the way VS Code's is:
//
//   ● ● ●            [ ⌕  hub                    ⌘P ]            ▯ ▭ ▯
//   traffic lights    search / quick open, centred     layout toggles
//
// It also claims the titlebar's space. The window uses a full-size content
// view with a transparent titlebar, and the content used to be pinned to the
// very top — so the file tree ran up UNDER the traffic lights, the window's own
// title was drawn over "EXPLORER", and a double-click at the top landed on the
// tree instead of the titlebar and never zoomed.
//
// Double-clicking empty strip toggles zoom: the window fills the screen's
// visible frame, dock and menu bar still showing, and a second double-click
// restores it. Deliberately not the green button's full screen, which hides
// the dock and moves the window to its own space.

import AppKit
import ColdfallCore

final class TitleStrip: NSView {

    var onSearch: (() -> Void)?
    var onToggleRail: (() -> Void)?
    var onToggleReader: (() -> Void)?
    var onToggleMeter: (() -> Void)?
    var onUpdate: (() -> Void)?

    private let pill = SearchPill()
    private let railBtn = TitleStrip.toggle("sidebar.left", tip: "Show or hide the rail  ⌘B")
    private let readerBtn = TitleStrip.toggle("sidebar.right", tip: "Show or hide the reader  ⌥⌘B")
    private let meterBtn = TitleStrip.toggle("rectangle.bottomthird.inset.filled",
                                             tip: "Show or hide the usage meter  ⌘J")

    /// "v0.4.0 is out", left of the toggles. Hidden until there is one.
    private let updateBtn = NSButton(title: "", target: nil, action: nil)

    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        pill.onClick = { [weak self] in self?.onSearch?() }
        railBtn.target = self;   railBtn.action = #selector(rail)
        readerBtn.target = self; readerBtn.action = #selector(reader)
        meterBtn.target = self;  meterBtn.action = #selector(meter)

        updateBtn.isBordered = false
        updateBtn.isHidden = true
        updateBtn.target = self; updateBtn.action = #selector(update)
        updateBtn.toolTip = "Open the release page"

        let toggles = NSStackView(views: [updateBtn, railBtn, meterBtn, readerBtn])
        toggles.orientation = .horizontal
        toggles.spacing = 2
        toggles.translatesAutoresizingMaskIntoConstraints = false

        addSubview(pill); addSubview(toggles)
        let pillWidth = pill.widthAnchor.constraint(equalToConstant: 380)
        pillWidth.priority = .defaultHigh      // the pill gives way before the toggles do
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 20),
            pillWidth,
            // Never slide under the traffic lights or the toggles on a narrow window.
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 84),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: toggles.leadingAnchor, constant: -12),

            toggles.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            toggles.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    /// The layout buttons go in the simple window; the update notice stays.
    func setSimple(_ on: Bool) {
        for b in [railBtn, meterBtn, readerBtn] { b.isHidden = on }
    }

    /// Show "<version> is out", or nothing.
    func setUpdate(_ version: String?) {
        guard let version else { updateBtn.isHidden = true; return }
        updateBtn.attributedTitle = NSAttributedString(string: "\(version) is out", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.ui.accent,
        ])
        updateBtn.isHidden = false
    }
    @objc private func update() { onUpdate?() }

    /// What the pill shows: the desk you are on.
    func setContext(_ text: String) { pill.setText(text) }

    /// Tint each toggle by whether its region is showing, VS Code style.
    func setShowing(rail: Bool, reader: Bool, meter: Bool) {
        let on = Theme.ui.text, off = Theme.ui.dimText.withAlphaComponent(0.55)
        railBtn.contentTintColor = rail ? on : off
        readerBtn.contentTintColor = reader ? on : off
        meterBtn.contentTintColor = meter ? on : off
    }

    func restyle() {
        layer?.backgroundColor = Theme.ui.sidebar.cgColor
        pill.restyle()
    }

    @objc private func rail() { onToggleRail?() }
    @objc private func reader() { onToggleReader?() }
    @objc private func meter() { onToggleMeter?() }

    /// The frame to go back to after filling the screen.
    private var beforeFill: Frame?

    override func mouseDown(with e: NSEvent) {
        guard e.clickCount == 2 else { window?.performDrag(with: e); return }
        guard let w = window, let visible = w.screen?.visibleFrame else { return }
        func f(_ r: NSRect) -> Frame { Frame(x: r.minX, y: r.minY, w: r.width, h: r.height) }
        let (next, saved) = WindowFill.toggle(frame: f(w.frame), visible: f(visible), saved: beforeFill)
        beforeFill = saved
        w.setFrame(NSRect(x: next.x, y: next.y, width: next.w, height: next.h), display: true, animate: true)
    }

    private static func toggle(_ symbol: String, tip: String) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.bezelStyle = .inline
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }
}

/// The search box in the middle of the strip. A clickable pill rather than a
/// real text field: typing happens in the palette it opens, so this is only
/// ever a target and a reminder of the shortcut.
final class SearchPill: NSView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let key = NSTextField(labelWithString: "\u{2318}P")     // ⌘P
    private var hovering = false { didSet { restyle() } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        for v in [icon, label, key] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        label.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -6),
            key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            key.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    func setText(_ s: String) { label.stringValue = s }

    func restyle() {
        let ui = Theme.ui
        layer?.backgroundColor = (hovering ? ui.selected : ui.hover).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ui.border.cgColor
        icon.contentTintColor = ui.dimText
        label.font = .systemFont(ofSize: 12)
        label.textColor = ui.dimText
        key.font = .systemFont(ofSize: 11)
        key.textColor = ui.dimText.withAlphaComponent(0.7)
    }

    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseDown(with e: NSEvent) { onClick?() }
    // Not draggable: a click on the pill should open search, not move the window.
    override var mouseDownCanMoveWindow: Bool { false }
}
