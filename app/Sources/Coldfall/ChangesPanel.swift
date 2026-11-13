import AppKit
import ColdfallCore

/// Changes: what a desk's agent changed in its folder, file by file, with
/// your comments sent back to it as one message.
///
/// Select lines in a diff, write a comment, add as many as you like across
/// files, then Send: the agent gets them together, each with its file,
/// line and the code it is about (see Changes.compose). Read-only on the
/// repository: nothing is staged, committed or reverted from here.
final class ChangesPanel: NSObject, NSTextFieldDelegate {
    private let panel: NSPanel
    private let heading = NSTextField(labelWithString: "Changes")
    private let sub = NSTextField(labelWithString: "")
    private let fileList = NSStackView()
    private let fileScroll = NSScrollView()
    private let diffView = NSTextView()
    private let diffScroll = NSScrollView()
    private let field = NSTextField()
    private let add = NSButton(title: "Add Comment", target: nil, action: nil)
    private let send = NSButton(title: "Send", target: nil, action: nil)
    private let clear = NSButton(title: "Clear", target: nil, action: nil)
    private let note = NSTextField(labelWithString: "")
    private let refreshBtn = NSButton()
    /// Last turn, or everything since the last commit.
    private let scope = NSSegmentedControl(labels: ["Last turn", "Uncommitted"], trackingMode: .selectOne, target: nil, action: nil)
    /// The folder as it was when the current turn started (see Changes.snapshot).
    private var turnBase: String?
    /// The folder now, for the same comparison.
    private var turnNow: String?
    private var lastTurn: Bool { scope.selectedSegment == 0 && turnBase != nil }
    /// The branch's pull request and its checks, when there is one.
    private let prLine = NSButton(title: "", target: nil, action: nil)
    private let fixBtn = NSButton(title: "Send Failing Checks to Agent", target: nil, action: nil)
    private var pr: PullRequest?

    private var desk = ""
    private var folder = ""
    private var files: [Changes.File] = []
    private var current: Changes.File?
    private var lines: [Changes.Line] = []
    /// Where each diff line sits in the text view, to turn a selection into lines.
    private var ranges: [NSRange] = []
    private(set) var comments: [Changes.Comment] = []
    private var generation = 0

    /// Send this message to the desk's agent. Returns what happened, to show.
    var onSend: ((String, String) -> (sent: Bool, message: String))?

    var isOpen: Bool { panel.isVisible }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 640, height: 400)

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
        refreshBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshBtn.isBordered = false
        refreshBtn.bezelStyle = .inline
        refreshBtn.contentTintColor = ui.dimText
        refreshBtn.toolTip = "Read the folder again"
        refreshBtn.target = self; refreshBtn.action = #selector(reload)

        fileList.orientation = .vertical
        fileList.alignment = .leading
        fileList.spacing = 1
        fileList.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(fileList)
        fileScroll.documentView = doc
        fileScroll.hasVerticalScroller = true
        fileScroll.drawsBackground = false

        diffView.isEditable = false
        diffView.isSelectable = true
        diffView.drawsBackground = true
        diffView.backgroundColor = Theme.current().skin.terminal.background
        diffView.textContainerInset = NSSize(width: 6, height: 8)
        diffView.isVerticallyResizable = true
        diffView.isHorizontallyResizable = true
        diffView.textContainer?.widthTracksTextView = false
        diffView.textContainer?.containerSize = NSSize(width: 1e7, height: 1e7)
        diffView.autoresizingMask = [.width]
        diffScroll.documentView = diffView
        diffScroll.hasVerticalScroller = true
        diffScroll.hasHorizontalScroller = true
        diffScroll.drawsBackground = false
        diffScroll.wantsLayer = true
        diffScroll.layer?.cornerRadius = 8

        field.placeholderString = "Select lines above, then write a comment for the agent"
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.target = self; field.action = #selector(addComment)
        add.target = self; add.action = #selector(addComment)
        add.bezelStyle = .rounded
        send.target = self; send.action = #selector(sendAll)
        send.bezelStyle = .rounded
        send.keyEquivalent = "\r"
        send.keyEquivalentModifierMask = [.command]
        clear.target = self; clear.action = #selector(clearAll)
        clear.bezelStyle = .inline
        clear.isBordered = false
        clear.contentTintColor = ui.dimText
        note.font = .systemFont(ofSize: 11.5)
        note.textColor = ui.dimText
        note.lineBreakMode = .byTruncatingTail

        scope.target = self; scope.action = #selector(scopeChanged)
        scope.controlSize = .small
        scope.selectedSegment = 1
        prLine.isBordered = false
        prLine.bezelStyle = .inline
        prLine.font = .systemFont(ofSize: 12, weight: .medium)
        prLine.target = self; prLine.action = #selector(openPR)
        prLine.toolTip = "Open the pull request in your browser"
        prLine.isHidden = true
        fixBtn.bezelStyle = .rounded
        fixBtn.controlSize = .small
        fixBtn.target = self; fixBtn.action = #selector(sendFix)
        fixBtn.isHidden = true
        let head = NSStackView(views: [heading, sub, prLine, fixBtn, NSView(), scope, refreshBtn])
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.spacing = 10
        let entry = NSStackView(views: [field, add])
        entry.orientation = .horizontal
        entry.spacing = 8
        let foot = NSStackView(views: [note, NSView(), clear, send])
        foot.orientation = .horizontal
        foot.spacing = 10
        for v in [head, fileScroll, diffScroll, entry, foot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            fileScroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 12),
            fileScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            fileScroll.widthAnchor.constraint(equalToConstant: 250),
            fileScroll.bottomAnchor.constraint(equalTo: foot.topAnchor, constant: -10),
            doc.topAnchor.constraint(equalTo: fileScroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: fileScroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: fileScroll.contentView.widthAnchor),
            fileList.topAnchor.constraint(equalTo: doc.topAnchor),
            fileList.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            fileList.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            fileList.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            diffScroll.topAnchor.constraint(equalTo: fileScroll.topAnchor),
            diffScroll.leadingAnchor.constraint(equalTo: fileScroll.trailingAnchor, constant: 8),
            diffScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            diffScroll.bottomAnchor.constraint(equalTo: entry.topAnchor, constant: -10),
            entry.leadingAnchor.constraint(equalTo: diffScroll.leadingAnchor),
            entry.trailingAnchor.constraint(equalTo: diffScroll.trailingAnchor),
            entry.bottomAnchor.constraint(equalTo: foot.topAnchor, constant: -10),
            foot.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            foot.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            foot.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        updateFoot()
    }

    func open(over window: NSWindow, desk: String, folder: String, turnBase: String? = nil) {
        // Comments belong to the desk they were written for.
        if desk != self.desk { comments = [] }
        self.desk = desk
        self.folder = folder
        self.turnBase = turnBase
        // What the agent just did is the first thing to look at, when known.
        scope.setEnabled(turnBase != nil, forSegment: 0)
        scope.selectedSegment = turnBase != nil ? 0 : 1
        scope.toolTip = turnBase != nil ? "What changed since your last prompt, or everything since the last commit."
            : "Last turn shows once you've sent this desk a prompt in this run of Coldfall."
        heading.stringValue = "Changes  ·  \(desk)"
        sub.stringValue = (folder as NSString).abbreviatingWithTildeInPath
        let f = window.frame
        let w = min(1040, f.width * 0.82), h = min(720, f.height * 0.84)
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        updateFoot()
        reload()
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// For --snapshot: this content, nothing read from disk.
    func show(desk: String, folder: String, files: [Changes.File], lines: [Changes.Line], comments: [Changes.Comment], size: NSSize,
              pr: PullRequest? = nil) {
        self.desk = desk; self.folder = folder
        showPR(pr)
        heading.stringValue = "Changes  ·  \(desk)"
        sub.stringValue = folder
        panel.setContentSize(size)
        self.files = files
        self.current = files.first
        self.comments = comments
        renderFiles()
        render(lines)
        updateFoot()
        panel.contentView?.layoutSubtreeIfNeeded()
    }
    var contentView: NSView? { panel.contentView }

    // MARK: - reading

    @objc private func scopeChanged() { current = nil; reload() }

    private func showPR(_ p: PullRequest?) {
        pr = p
        prLine.isHidden = p == nil
        fixBtn.isHidden = p?.fixChecksMessage == nil
        guard let p else { return }
        prLine.title = p.summary
        prLine.contentTintColor = !p.failed.isEmpty ? .systemRed : (!p.pending.isEmpty ? .systemOrange : (p.passed.isEmpty ? Theme.ui.dimText : .systemGreen))
        fixBtn.title = p.failed.count == 1 ? "Send Failing Check to \(desk)" : "Send Failing Checks to \(desk)"
    }
    @objc private func openPR() { if let u = pr.flatMap({ URL(string: $0.url) }) { NSWorkspace.shared.open(u) } }
    @objc private func sendFix() {
        guard let m = pr?.fixChecksMessage else { return }
        let r: (sent: Bool, message: String) = onSend?(desk, m) ?? (false, "Nothing to send to.")
        note.stringValue = r.sent ? "Sent the failing checks to \(desk)." : r.message
    }

    @objc private func reload() {
        generation += 1
        let gen = generation, folder = self.folder, keep = current?.path
        let base = lastTurn ? turnBase : nil
        note.stringValue = "Reading…"
        DispatchQueue.global(qos: .userInitiated).async {
            var now: String?
            var list: [Changes.File]?
            if let base {
                now = Changes.snapshot(in: folder)
                list = now.flatMap { Changes.files(from: base, to: $0, in: folder) }
            } else {
                list = Changes.files(in: folder)
            }
            // The branch's pull request, if GitHub has one. A network call
            // through your own gh, made only here: when you look.
            let pull = list == nil ? nil : PullRequest.fetch(folder: folder)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.showPR(pull)
                self.turnNow = now
                guard let list else {
                    self.files = []; self.current = nil
                    self.renderFiles()
                    self.render([Changes.Line(.meta, "This desk's folder isn't a git repository, so there are no changes to show.")])
                    self.updateFoot()
                    return
                }
                self.files = list
                self.renderFiles()
                if let f = list.first(where: { $0.path == keep }) ?? list.first { self.pick(f) }
                else { self.current = nil; self.render([Changes.Line(.meta, self.lastTurn ? "Nothing changed since your last prompt." : "No changes since the last commit.")]) }
                self.updateFoot()
            }
        }
    }

    private func pick(_ f: Changes.File) {
        current = f
        renderFiles()
        generation += 1
        let gen = generation, folder = self.folder
        let pair = lastTurn ? turnBase.flatMap { b in turnNow.map { (b, $0) } } : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let l = pair.map { Changes.diff(f, from: $0.0, to: $0.1, in: folder) } ?? Changes.diff(f, in: folder)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.render(l)
            }
        }
    }

    // MARK: - drawing

    private func renderFiles() {
        for v in fileList.arrangedSubviews { fileList.removeArrangedSubview(v); v.removeFromSuperview() }
        let ui = Theme.ui
        for f in files {
            let n = comments.filter { $0.file == f.path }.count
            let b = FileButton(file: f, selected: f == current, comments: n)
            b.onClick = { [weak self] in self?.pick(f) }
            fileList.addArrangedSubview(b)
            b.widthAnchor.constraint(equalTo: fileList.widthAnchor).isActive = true
        }
        if files.isEmpty {
            let t = NSTextField(labelWithString: "No changed files")
            t.font = .systemFont(ofSize: 12)
            t.textColor = ui.dimText
            fileList.addArrangedSubview(t)
        }
    }

    private func render(_ l: [Changes.Line]) {
        lines = l
        ranges = []
        let ui = Theme.ui
        let fg = Theme.current().skin.terminal.foreground
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let out = NSMutableAttributedString()
        let width = max(3, String(l.compactMap(\.number).max() ?? 0).count)
        for line in l {
            let num = line.number.map { String($0) } ?? ""
            let gutter = String(repeating: " ", count: width - num.count) + num
            let mark: String
            var attrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: fg]
            switch line.kind {
            case .added: mark = "+"; attrs[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.16)
            case .removed: mark = "-"; attrs[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.16)
            case .hunk: mark = " "; attrs[.foregroundColor] = ui.accent
            case .meta: mark = " "; attrs[.foregroundColor] = ui.dimText
            case .context: mark = " "
            }
            let text = line.kind == .meta || line.kind == .hunk ? line.text : "\(gutter)  \(mark) \(line.text)"
            let start = out.length
            out.append(NSAttributedString(string: text + "\n", attributes: attrs))
            if line.kind != .meta, line.kind != .hunk, width > 0 {
                out.addAttribute(.foregroundColor, value: ui.dimText, range: NSRange(location: start, length: width))
            }
            ranges.append(NSRange(location: start, length: text.count + 1))
        }
        diffView.textStorage?.setAttributedString(out)
        diffView.scroll(.zero)
    }

    private func updateFoot() {
        let n = comments.count
        send.title = n == 0 ? "Send to \(desk)" : "Send \(n) Comment\(n == 1 ? "" : "s") to \(desk)"
        send.isEnabled = n > 0
        clear.isHidden = n == 0
        if n > 0 { note.stringValue = "\(n) comment\(n == 1 ? "" : "s") ready. ⌘Return sends them together." }
        else if note.stringValue == "Reading…" || note.stringValue.hasSuffix("together.") { note.stringValue = "" }
    }

    // MARK: - comments

    /// The diff lines the selection touches: (first numbered line, the code).
    private func selection() -> (line: Int?, quote: String)? {
        let sel = diffView.selectedRange()
        var picked: [Changes.Line] = []
        for (i, r) in ranges.enumerated() where lines.indices.contains(i) {
            let hit = sel.length == 0 ? NSLocationInRange(sel.location, r) : NSIntersectionRange(sel, r).length > 0
            if hit, lines[i].kind == .added || lines[i].kind == .context || lines[i].kind == .removed { picked.append(lines[i]) }
        }
        guard !picked.isEmpty else { return nil }
        let first = picked.first { $0.number != nil } ?? picked[0]
        return (first.number, first.text)
    }

    @objc private func addComment() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let f = current else {
            if current == nil { note.stringValue = "Pick a file first." }
            return
        }
        // Nothing selected: a comment on the file as a whole.
        let at = selection()
        comments.append(Changes.Comment(file: f.path, line: at?.line, quote: at?.quote ?? "", text: text))
        field.stringValue = ""
        renderFiles()
        updateFoot()
    }

    @objc private func clearAll() {
        comments = []
        renderFiles()
        updateFoot()
        note.stringValue = ""
    }

    @objc private func sendAll() {
        guard !comments.isEmpty else { return }
        let r: (sent: Bool, message: String) = onSend?(desk, Changes.compose(comments)) ?? (false, "Nothing to send to.")
        if r.sent {
            comments = []
            renderFiles()
            updateFoot()
            note.stringValue = "Sent to \(desk)."
        } else {
            // Kept: a refusal (the desk is asking something, or you are
            // mid-message there) shouldn't cost you the comments.
            note.stringValue = r.message
        }
    }
}

/// One changed file in the list: its status letter, its name, its folder.
private final class FileButton: NSView {
    var onClick: (() -> Void)?
    private let selected: Bool
    private var hovering = false { didSet { needsDisplay = true } }

    init(file: Changes.File, selected: Bool, comments: Int) {
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let ui = Theme.ui
        let letter = NSTextField(labelWithString: file.status == "?" ? "U" : file.status)
        letter.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        switch file.status {
        case "A", "?": letter.textColor = .systemGreen
        case "D": letter.textColor = .systemRed
        default: letter.textColor = .systemOrange
        }
        let name = NSTextField(labelWithString: (file.path as NSString).lastPathComponent)
        name.font = .systemFont(ofSize: 12.5, weight: selected ? .medium : .regular)
        name.textColor = ui.text
        name.lineBreakMode = .byTruncatingMiddle
        let dir = NSTextField(labelWithString: (file.path as NSString).deletingLastPathComponent)
        dir.font = .systemFont(ofSize: 11)
        dir.textColor = ui.dimText
        dir.lineBreakMode = .byTruncatingHead
        dir.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let count = NSTextField(labelWithString: comments > 0 ? "\(comments)" : "")
        count.font = .systemFont(ofSize: 10.5, weight: .semibold)
        count.textColor = MarkView.pillInk
        count.toolTip = comments > 0 ? "\(comments) comment\(comments == 1 ? "" : "s") waiting to be sent" : nil
        let row = NSStackView(views: [letter, name, dir, NSView(), count])
        row.orientation = .horizontal
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        toolTip = file.path
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            letter.widthAnchor.constraint(equalToConstant: 10),
        ])
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirty: NSRect) {
        let fill: NSColor? = selected ? Theme.ui.selected : (hovering ? Theme.ui.hover : nil)
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseUp(with e: NSEvent) { onClick?() }
}
