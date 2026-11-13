import AppKit
import ColdfallCore

/// Needs You: every desk stopped on a question, in one window, each with
/// its question and its choices as buttons. Answer five permission prompts
/// without opening five desks.
///
/// The choices are read off the desk's own screen (see Prompt). A button
/// presses that option's key only if the option is still on the screen at
/// that moment; a prompt that has changed is never answered blind. A desk
/// whose question can't be read gets Go to Desk and nothing else, rather
/// than a guess.
final class FeedPanel: NSObject {
    struct Item: Equatable {
        let desk: String
        let runtime: String
        let icon: String?
        let reason: String?
        let prompt: Prompt?
        /// The last lines of the screen, shown when no prompt could be read.
        let tail: String
    }

    private let panel: NSPanel
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "Nothing is waiting on you.")
    private let heading = NSTextField(labelWithString: "Needs You")
    private var timer: Timer?
    private var shown: [Item] = []
    /// The waiting desks, most urgent first. Asked for on a timer while open.
    var items: (() -> [Item])?
    /// Press this option in this desk. Returns a line to show if it couldn't.
    var onAnswer: ((String, Prompt.Option) -> String?)?
    var onGo: ((String) -> Void)?

    var isOpen: Bool { panel.isVisible }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let ui = Theme.ui
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = ui.editor.cgColor
        panel.contentView = root

        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = ui.text
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = ui.dimText

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for v in [heading, scroll, empty] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
    }

    func toggle(over window: NSWindow) { if isOpen { close() } else { open(over: window) } }

    func open(over window: NSWindow) {
        let f = window.frame
        let w = min(640, f.width * 0.6), h = min(620, f.height * 0.78)
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
        refresh(force: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.inEveryMode(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.refresh(force: false) }
    }

    @objc func close() {
        timer?.invalidate(); timer = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// For --snapshot: these items, no timer.
    func show(_ fixed: [Item], size: NSSize) {
        panel.setContentSize(size)
        render(fixed)
        panel.contentView?.layoutSubtreeIfNeeded()
    }
    var contentView: NSView? { panel.contentView }

    private func refresh(force: Bool) {
        let now = items?() ?? []
        if force || now != shown { render(now) }
    }

    private func render(_ list: [Item]) {
        shown = list
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        empty.isHidden = !list.isEmpty
        heading.stringValue = list.isEmpty ? "Needs You" : "Needs You  ·  \(list.count)"
        for it in list {
            let card = FeedCard(it)
            card.onAnswer = { [weak self] opt in
                if let note = self?.onAnswer?(it.desk, opt) { card.say(note) }
                // The desk moves on at once; the list catches up on the next tick.
            }
            card.onGo = { [weak self] in self?.close(); self?.onGo?(it.desk) }
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}


/// One waiting desk: who, why, what about, and the choices.
private final class FeedCard: NSView {
    var onAnswer: ((Prompt.Option) -> Void)?
    var onGo: (() -> Void)?
    private let note = NSTextField(labelWithString: "")
    private var options: [Prompt.Option] = []

    init(_ it: FeedPanel.Item) {
        super.init(frame: .zero)
        let ui = Theme.ui
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = ui.border.cgColor
        layer?.backgroundColor = ui.sidebar.cgColor

        let icon = NSImageView(image: VendorIcon.image(runtime: it.runtime, icon: it.icon, size: 16))
        let name = NSTextField(labelWithString: it.desk)
        name.font = .systemFont(ofSize: 13.5, weight: .semibold)
        name.textColor = ui.text
        let why = NSTextField(labelWithString: it.prompt?.question.isEmpty == false ? it.prompt!.question : (it.reason ?? "is waiting for your answer"))
        why.font = .systemFont(ofSize: 12.5)
        why.textColor = MarkView.pillInk
        why.lineBreakMode = .byTruncatingTail
        why.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let go = NSButton(title: "Go to Desk", target: self, action: #selector(goTo))
        go.bezelStyle = .inline
        go.isBordered = false
        go.font = .systemFont(ofSize: 11.5)
        go.contentTintColor = ui.dimText
        let head = NSStackView(views: [icon, name, why, NSView(), go])
        head.orientation = .horizontal
        head.spacing = 8
        head.alignment = .centerY

        // What it is about: the command or file under the question, or,
        // where no choice could be read, the last of the screen as it is.
        let about = it.prompt.map { $0.context.joined(separator: "\n") } ?? it.tail
        let body = NSTextField(wrappingLabelWithString: about)
        body.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        body.textColor = ui.text.withAlphaComponent(0.85)
        body.maximumNumberOfLines = it.prompt == nil ? 10 : Prompt.maxContext
        body.isSelectable = true
        body.isHidden = about.isEmpty

        let col = NSStackView(views: [head, body])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 8
        if let p = it.prompt {
            options = p.options
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 6
            for (n, o) in p.options.enumerated() {
                let b = NSButton(title: "\(o.key)   \(Prompt.short(o.label, max: 64))", target: self, action: #selector(pick(_:)))
                b.bezelStyle = .rounded
                b.tag = n
                b.toolTip = o.label
                row.addArrangedSubview(b)
            }
            col.addArrangedSubview(row)
        } else {
            let hint = NSTextField(labelWithString: "Its choices couldn't be read from here. Open the desk to answer.")
            hint.font = .systemFont(ofSize: 11.5)
            hint.textColor = ui.dimText
            col.addArrangedSubview(hint)
        }
        note.font = .systemFont(ofSize: 11.5)
        note.textColor = ui.dimText
        note.isHidden = true
        col.addArrangedSubview(note)

        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            head.widthAnchor.constraint(equalTo: col.widthAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func say(_ s: String) { note.stringValue = s; note.isHidden = false }

    @objc private func pick(_ b: NSButton) {
        guard options.indices.contains(b.tag) else { return }
        onAnswer?(options[b.tag])
    }
    @objc private func goTo() { onGo?() }
}
