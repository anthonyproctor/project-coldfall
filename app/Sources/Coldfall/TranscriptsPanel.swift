import AppKit
import ColdfallCore

/// Conversations: every conversation an agent has had in a desk's folder,
/// to search and to pick one back up.
///
/// Type to search the full text. Open in a Split types the vendor's own
/// resume command into a shell beside the desk; Copy Command puts it on
/// the clipboard. Reads what the vendors already keep on this Mac.
final class TranscriptsPanel: NSObject, NSSearchFieldDelegate {
    private let panel: NSPanel
    private let heading = NSTextField(labelWithString: "Conversations")
    private let sub = NSTextField(labelWithString: "")
    private let search = NSSearchField()
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private let note = NSTextField(labelWithString: "")
    private var all: [Transcripts.Conversation] = []
    private var folder = ""
    private var generation = 0
    /// Run this resume command in a shell split beside the desk.
    var onOpen: ((String) -> Void)?

    var isOpen: Bool { panel.isVisible }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 480, height: 320)
        let ui = Theme.ui
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = ui.editor.cgColor
        panel.contentView = root

        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = ui.text
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = ui.dimText
        sub.lineBreakMode = .byTruncatingMiddle
        search.placeholderString = "Search everything said in them"
        search.delegate = self
        search.target = self; search.action = #selector(runSearch)
        search.sendsSearchStringImmediately = false
        note.font = .systemFont(ofSize: 11.5)
        note.textColor = ui.dimText

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let head = NSStackView(views: [heading, sub])
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.spacing = 10
        for v in [head, search, scroll, note] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            head.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            search.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -8),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor, constant: 2),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -8),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -6),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            note.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
    }

    func open(over window: NSWindow, desk: String, folder: String) {
        self.folder = folder
        heading.stringValue = "Conversations  ·  \(desk)"
        sub.stringValue = (folder as NSString).abbreviatingWithTildeInPath
        search.stringValue = ""
        let f = window.frame
        let w = min(760, f.width * 0.66), h = min(640, f.height * 0.8)
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        load()
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// For --snapshot.
    func show(desk: String, folder: String, _ fixed: [Transcripts.Conversation], size: NSSize) {
        heading.stringValue = "Conversations  ·  \(desk)"
        sub.stringValue = folder
        panel.setContentSize(size)
        all = fixed
        render(fixed)
        panel.contentView?.layoutSubtreeIfNeeded()
    }
    var contentView: NSView? { panel.contentView }

    private func load() {
        generation += 1
        let gen = generation, folder = self.folder
        note.stringValue = "Reading…"
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Transcripts.all(folder: folder)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.all = found
                self.render(found)
            }
        }
    }

    func controlTextDidChange(_ n: Notification) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(runSearch), object: nil)
        perform(#selector(runSearch), with: nil, afterDelay: 0.35)
    }

    @objc private func runSearch() {
        generation += 1
        let gen = generation, q = search.stringValue, list = all
        if q.trimmingCharacters(in: .whitespaces).isEmpty { render(list); return }
        note.stringValue = "Searching…"
        DispatchQueue.global(qos: .userInitiated).async {
            let hits = Transcripts.search(list, query: q)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.render(hits, searching: true)
            }
        }
    }

    private func render(_ items: [Transcripts.Conversation], searching: Bool = false) {
        for v in list.arrangedSubviews { list.removeArrangedSubview(v); v.removeFromSuperview() }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        for c in items.prefix(200) {
            let row = ConversationRow(c, when: df.string(from: c.modified))
            row.onOpen = { [weak self] in
                guard let cmd = Transcripts.resumeCommand(c) else { return }
                self?.close()
                self?.onOpen?(cmd)
            }
            row.onCopy = { [weak self] in
                guard let cmd = Transcripts.resumeCommand(c) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
                self?.note.stringValue = "Copied: \(cmd)"
            }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        if items.isEmpty {
            note.stringValue = searching ? "Nothing said in this folder's conversations matches."
                : "No Claude Code or Codex conversations found for this folder."
        } else {
            note.stringValue = "\(items.count) conversation\(items.count == 1 ? "" : "s")" + (searching ? " match" + (items.count == 1 ? "es" : "") : "")
                + ". Read from where Claude Code and Codex keep them on this Mac."
        }
    }
}

private final class ConversationRow: NSView {
    var onOpen: (() -> Void)?
    var onCopy: (() -> Void)?

    init(_ c: Transcripts.Conversation, when: String) {
        super.init(frame: .zero)
        let ui = Theme.ui
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = ui.border.cgColor
        layer?.backgroundColor = ui.sidebar.cgColor

        let icon = NSImageView(image: VendorIcon.image(runtime: c.vendor, icon: nil, size: 16))
        let title = NSTextField(labelWithString: c.heading)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = ui.text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var bits = [when, Transcripts.size(c.bytes)]
        if c.title != nil, let p = c.firstPrompt { bits.append("began: " + p) }
        let meta = NSTextField(labelWithString: bits.joined(separator: "  ·  "))
        meta.font = .systemFont(ofSize: 11.5)
        meta.textColor = ui.dimText
        meta.lineBreakMode = .byTruncatingTail
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let open = NSButton(title: "Open in a Split", target: self, action: #selector(openIt))
        open.bezelStyle = .rounded
        open.controlSize = .small
        open.toolTip = Transcripts.resumeCommand(c).map { "Types \($0) into a shell beside this desk" }
        let copy = NSButton(title: "Copy Command", target: self, action: #selector(copyIt))
        copy.bezelStyle = .inline
        copy.isBordered = false
        copy.font = .systemFont(ofSize: 11.5)
        copy.contentTintColor = ui.dimText
        for b in [open, copy] { b.setContentCompressionResistancePriority(.required, for: .horizontal) }
        let text = NSStackView(views: [title, meta])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let row = NSStackView(views: [icon, text, NSView(), copy, open])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { nil }
    @objc private func openIt() { onOpen?() }
    @objc private func copyIt() { onCopy?() }
}
