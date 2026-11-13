import AppKit
import ColdfallCore

/// A look at another desk without leaving this one.
///
/// Option-click a running desk in the rail, or right-click it and choose
/// Peek: its screen opens over the current desk as text, kept up to date
/// while it's open. Read only on purpose: typing into a desk you're only
/// glancing at is how a message goes to the wrong agent. Return goes to the
/// desk; Escape, or a click outside, closes the look.
///
/// Text rather than the live terminal: a terminal view lives in one place,
/// and moving the real one would take it away from its own desk.
final class PeekPanel: NSObject {
    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let text = NSTextView()
    private let scroll = NSScrollView()
    private var timer: Timer?
    private weak var session: DeskSession?
    private var desk = ""
    /// Go to the desk being peeked at.
    var onGo: ((String) -> Void)?

    var isOpen: Bool { panel.isVisible }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true

        let ui = Theme.ui
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = ui.editor.cgColor
        panel.contentView = root

        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = ui.text
        state.font = .systemFont(ofSize: 12)
        state.textColor = ui.dimText

        let go = NSButton(title: "Go to Desk", target: self, action: #selector(goToDesk))
        go.bezelStyle = .rounded
        go.keyEquivalent = "\r"
        let close = NSButton(title: "Close", target: self, action: #selector(closeIt))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = true
        text.backgroundColor = Theme.current().skin.terminal.background
        text.textColor = Theme.current().skin.terminal.foreground
        text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.textContainerInset = NSSize(width: 10, height: 8)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8

        let head = NSStackView(views: [title, state, NSView(), close, go])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 10
        for v in [head, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
    }

    func open(over window: NSWindow, desk: String, session: DeskSession) {
        self.desk = desk
        self.session = session
        title.stringValue = desk
        let f = window.frame
        let w = min(860, f.width * 0.72), h = min(560, f.height * 0.7)
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
        refresh(force: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh(force: false) }
    }

    /// New text in, kept at the bottom unless you've scrolled up to read.
    private func refresh(force: Bool) {
        guard let s = session else { closeIt(); return }
        let body = s.screenText(lines: 400)
        let atBottom = force || scroll.verticalScroller.map { $0.floatValue > 0.98 } ?? true
        if text.string != body { text.string = body }
        state.stringValue = PeekPanel.describe(s.activity, running: s.started)
        if atBottom { text.scrollToEndOfDocument(nil) }
    }

    static func describe(_ a: DeskActivity, running: Bool) -> String {
        guard running else { return "not running" }
        switch a {
        case .working: return "working"
        case .ready: return "answered"
        case .blocked: return "needs you"
        case .quiet: return "idle"
        }
    }

    @objc private func goToDesk() {
        let d = desk
        closeIt()
        onGo?(d)
    }

    @objc func closeIt() {
        timer?.invalidate(); timer = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// For --snapshot.
    var contentView: NSView? { panel.contentView }
}
