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
        /// What to say then (PromptCheck.unread).
        var unread: String = PromptCheck.unread(nil, read: [:])
        /// The desk's own notice (coldfall-cli notify), not a question on its screen.
        var notice: Bool = false
        /// A pull request with a failing check or a review asking for changes (PRWatch).
        var pr: PRWatch.Alert? = nil
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
    /// Take a desk's notice down.
    var onDismiss: ((String) -> Void)?
    /// Hide a pull request's card until its state changes.
    var onDismissPR: ((PRWatch.Alert) -> Void)?
    /// Send this to the desk (the failing checks). Returns a line to show.
    var onSend: ((String, String) -> String)?
    /// What's waiting in the Family Connector, if it runs and let Coldfall in.
    var family: (() -> [Connector.Item])?
    /// Pick a desk to draft a reply to this question; the button is where to show the menu.
    var onDraft: ((Connector.Item, NSView) -> Void)?
    /// Ask Connector to open its Send window for this draft.
    var onRelease: ((Connector.Item, @escaping (String?) -> Void) -> Void)?
    var onSeen: ((Connector.Item) -> Void)?
    private var shownFamily: [Connector.Item] = []

    var isOpen: Bool { panel.isVisible }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false     // it opens again after the close button
        // The close button closes the panel itself, not through close() here,
        // which left the 0.7s timer reading desks for the rest of the day.
        NotificationCenter.default.addObserver(self, selector: #selector(panelClosing),
                                               name: NSWindow.willCloseNotification, object: panel)

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

    @objc private func panelClosing() { timer?.invalidate(); timer = nil }

    @objc func close() {
        timer?.invalidate(); timer = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// For --snapshot: these items, no timer.
    func show(_ fixed: [Item], family: [Connector.Item] = [], size: NSSize) {
        panel.setContentSize(size)
        render(fixed, family: family)
        panel.contentView?.layoutSubtreeIfNeeded()
    }
    var contentView: NSView? { panel.contentView }

    private func refresh(force: Bool) {
        let now = items?() ?? []
        let fam = family?() ?? []
        if force || now != shown || fam != shownFamily { render(now, family: fam) }
    }

    private func render(_ list: [Item], family fam: [Connector.Item] = []) {
        shown = list
        shownFamily = fam
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        let total = list.count + Connector.count(fam)
        empty.isHidden = total > 0 || !fam.isEmpty
        heading.stringValue = total == 0 ? "Needs You" : "Needs You  ·  \(total)"
        for it in list {
            let card = FeedCard(it)
            // Weak: the card holds this closure, so a strong card here kept
            // every card ever drawn alive.
            card.onAnswer = { [weak self, weak card] opt in
                if let note = self?.onAnswer?(it.desk, opt) { card?.say(note) }
                // The desk moves on at once; the list catches up on the next tick.
            }
            card.onGo = { [weak self] in self?.close(); self?.onGo?(it.desk) }
            card.onDismiss = { [weak self] in
                if let a = it.pr { self?.onDismissPR?(a) } else { self?.onDismiss?(it.desk) }
                self?.refresh(force: true)
            }
            card.onSend = { [weak self, weak card] text in
                if let note = self?.onSend?(it.desk, text) { card?.say(note) }
            }
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        guard !fam.isEmpty else { return }
        let title = NSTextField(labelWithString: "Family Connector")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = Theme.ui.dimText
        let sub = NSTextField(wrappingLabelWithString: "Their words are shown as written and never handed to a desk. "
                              + "Sending is always a press in the Connector app.")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = Theme.ui.dimText
        let head = NSStackView(views: [title, sub])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 2
        if !list.isEmpty { stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!) }
        stack.addArrangedSubview(head)
        head.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        sub.widthAnchor.constraint(equalTo: head.widthAnchor).isActive = true
        for it in fam {
            let card = FamilyCard(it)
            card.onDraft = { [weak self] b in self?.onDraft?(it, b) }
            card.onRelease = { [weak self, weak card] in
                card?.say("Asking Connector…")
                self?.onRelease?(it) { [weak card] note in card?.say(note ?? "Connector's Send window is open. Read it there and press Send.") }
            }
            card.onSeen = { [weak self] in self?.onSeen?(it) }
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

/// One thing waiting in the Family Connector: who, where, their words, and
/// what Coldfall can do about it (none of which sends).
private final class FamilyCard: NSView {
    var onDraft: ((NSView) -> Void)?
    var onRelease: (() -> Void)?
    var onSeen: (() -> Void)?
    private let note = NSTextField(labelWithString: "")
    private let item: Connector.Item

    init(_ it: Connector.Item) {
        item = it
        super.init(frame: .zero)
        let ui = Theme.ui
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = ui.border.cgColor
        layer?.backgroundColor = ui.sidebar.cgColor

        let symbol = it.box == .answers ? "bubble.left.and.text.bubble.right" : (it.box == .outbox ? "paperplane" : "person.2")
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = it.box == .outbox ? ui.dimText : MarkView.pillInk
        let name = NSTextField(labelWithString: Connector.heading(it))
        name.font = .systemFont(ofSize: 13.5, weight: .semibold)
        name.textColor = ui.text
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let where_ = NSTextField(labelWithString: Connector.detail(it))
        where_.font = .systemFont(ofSize: 11.5)
        where_.textColor = it.quick ? MarkView.pillInk : ui.dimText
        where_.lineBreakMode = .byTruncatingTail
        where_.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let head = NSStackView(views: [icon, name, NSView(), where_])
        head.orientation = .horizontal
        head.spacing = 8
        head.alignment = .centerY

        let col = NSStackView(views: [head])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 8
        func words(_ label: String?, _ s: String?) {
            guard let s, !s.isEmpty else { return }
            let t = NSTextField(wrappingLabelWithString: (label.map { $0 + "  " } ?? "") + s)
            t.font = .systemFont(ofSize: 12.5)
            t.textColor = ui.text.withAlphaComponent(0.9)
            t.maximumNumberOfLines = 8
            t.isSelectable = true
            // Plain text only: no links, no formatting from their words.
            t.allowsEditingTextAttributes = false
            col.addArrangedSubview(t)
        }
        if it.question != nil { words("They asked:", it.question); words("Draft:", it.text) } else { words(nil, it.text) }

        var buttons: [NSButton] = []
        func button(_ title: String, _ action: Selector, primary: Bool = false) {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            if primary { b.bezelColor = .controlAccentColor }
            buttons.append(b)
        }
        switch it.box {
        case .waiting:
            if Connector.canDraft(it) { button("Draft with Desk…", #selector(draft(_:)), primary: true) }
            button("Answer in Connector", #selector(openIt))
        case .outbox:
            if it.state == "awaiting_press" { button("Open Send Window", #selector(openIt), primary: true) }
            else { button("Review and Send…", #selector(askToSend), primary: true) }
        case .answers:
            button("Seen", #selector(seen), primary: true)
            button("Open in Connector", #selector(openIt))
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        col.addArrangedSubview(row)
        if it.box == .waiting && !it.aiHelp {
            let off = NSTextField(labelWithString: "AI help is off in this circle, so no desk can draft here.")
            off.font = .systemFont(ofSize: 11.5); off.textColor = ui.dimText
            col.addArrangedSubview(off)
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
        for v in col.arrangedSubviews where v is NSTextField {
            v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { nil }

    func say(_ s: String) { note.stringValue = s; note.isHidden = false }

    @objc private func draft(_ b: NSButton) { onDraft?(b) }
    // Not "release": that name is NSObject's own, and overriding it crashes.
    @objc private func askToSend() { onRelease?() }
    @objc private func seen() { onSeen?() }
    @objc private func openIt() { ConnectorWatch.open(item) }
}


/// One waiting desk: who, why, what about, and the choices.
private final class FeedCard: NSView {
    var onAnswer: ((Prompt.Option) -> Void)?
    var onGo: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onSend: ((String) -> Void)?
    private let note = NSTextField(labelWithString: "")
    private var options: [Prompt.Option] = []
    private var pr: PRWatch.Alert?

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
        var tail: [NSView] = [go]
        if it.notice || it.pr != nil {
            let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissIt))
            dismiss.bezelStyle = .inline
            dismiss.isBordered = false
            dismiss.font = .systemFont(ofSize: 11.5)
            dismiss.contentTintColor = ui.dimText
            tail.insert(dismiss, at: 0)
        }
        let head = NSStackView(views: [icon, name, why, NSView()] + tail)
        head.orientation = .horizontal
        head.spacing = 8
        head.alignment = .centerY

        // What it is about: the command or file under the question, or,
        // where no choice could be read, the last of the screen as it is.
        let about = it.prompt.map { $0.context.joined(separator: "\n") } ?? it.tail
        let body = NSTextField(wrappingLabelWithString: about)
        // A notice is the agent's sentence to you, not a screen: ordinary type.
        body.font = it.notice || it.pr != nil ? .systemFont(ofSize: 13) : .monospacedSystemFont(ofSize: 11.5, weight: .regular)
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
        } else if let a = it.pr {
            pr = a
            var buttons: [NSButton] = []
            if a.pr.fixChecksMessage != nil {
                let fix = NSButton(title: a.pr.failed.count == 1 ? "Send Failing Check to \(it.desk)" : "Send Failing Checks to \(it.desk)",
                                   target: self, action: #selector(sendFix))
                fix.bezelStyle = .rounded
                fix.bezelColor = .controlAccentColor
                buttons.append(fix)
            }
            let open = NSButton(title: "Open Pull Request", target: self, action: #selector(openPR))
            open.bezelStyle = .rounded
            buttons.append(open)
            let row = NSStackView(views: buttons)
            row.orientation = .horizontal
            row.spacing = 8
            col.addArrangedSubview(row)
        } else {
            let hint = NSTextField(wrappingLabelWithString: it.unread)
            hint.font = .systemFont(ofSize: 11.5)
            hint.textColor = ui.dimText
            hint.isSelectable = false
            col.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
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
    @objc private func dismissIt() { onDismiss?() }
    @objc private func sendFix() { if let m = pr?.pr.fixChecksMessage { onSend?(m) } }
    @objc private func openPR() { if let u = pr.flatMap({ URL(string: $0.pr.url) }), u.scheme == "https" { NSWorkspace.shared.open(u) } }
}
