import AppKit
import ColdfallCore

/// What a stranger sees the first time they open Coldfall: two steps.
///
/// 1. How you use AI today, from the check-up (see Checkup): what's installed
///    and what's used, what you've built, in a few plain lines, with a summary
///    to share. Nothing is set up yet.
/// 2. Your first desk: a few to choose from, made for how you work (a folder
///    you use, an agent you built, or a new job in its own folder), one ticked
///    to begin with. Someone with no agent tool picks the plan they pay for and
///    gets that one tool's install step. Never a desk per installed tool.
final class WelcomeWindow: NSWindowController, NSTextFieldDelegate {
    var onFinish: (() -> Void)?
    private var projectDir = FileManager.default.currentDirectoryPath
    private let updateSwitch = NSButton(checkboxWithTitle: UpdateCheck.switchLabel, target: nil, action: nil)
    /// Snapshot only: draw the first run of a Mac with no vendor CLI.
    static var pretendNothingInstalled = false
    /// Snapshot only: a made-up check-up instead of this Mac's, and the step to draw.
    static var demo: Checkup.Profile?
    static var startStep = 1

    private var report: Checkup.Report!
    private var options: [FirstDesk.Option] = []
    private var tools: [FirstDesk.Tool] = []
    private var plan: FirstDesk.Plan = FirstDesk.plans[0]
    private var step = 1
    private var jobOn = false
    private var jobName = ""
    private var jobRuntime = ""

    private let scroll = NSScrollView()
    private let doc = WelcomeDoc()
    private let stepLabel = NSTextField(labelWithString: "")
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let later = NSButton(title: "Not now", target: nil, action: nil)
    private let go = NSButton(title: "Continue", target: nil, action: nil)
    private var checkboxes: [NSButton] = []
    private var jobBox: NSButton?
    private var jobField: NSTextField?
    private var jobNote: NSTextField?

    convenience init(projectDir: String = FileManager.default.currentDirectoryPath) {
        let vis = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: min(640, vis.height - 80)),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.contentMinSize = NSSize(width: 560, height: 460)
        self.init(window: w)
        w.title = "Welcome to Project Coldfall"
        w.backgroundColor = Theme.ui.editor
        self.projectDir = projectDir
        look()
        frame()
        step = WelcomeWindow.startStep
        show()
        w.center()
    }

    // MARK: the check-up

    private func look() {
        if let p = WelcomeWindow.demo { report = Checkup.demo(p) }
        else if WelcomeWindow.pretendNothingInstalled { report = Checkup.demo(.newcomer) }
        else { report = Checkup.run() }
        tools = FirstDesk.tools(report)
        let demoAgents: (String) -> [DiscoveredAgent] = { folder in
            (self.report.folders.first { $0.path == folder }?.agents ?? []).map {
                DiscoveredAgent(name: $0, runtime: "claude", description: nil, model: nil, path: folder + "/.claude/agents/\($0).md", isProjectLevel: true)
            }
        }
        options = WelcomeWindow.demo != nil ? FirstDesk.options(report, agentsIn: demoAgents)
            : FirstDesk.options(report, existing: DeskConfig.load())
        // A new job is the start when there's nothing else to start from.
        jobOn = options.isEmpty && !tools.isEmpty
        jobRuntime = tools.first?.runtime ?? ""
        plan = FirstDesk.likelyPlan(report)
    }

    // MARK: building

    private func h1(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 26, weight: .semibold)
        return l
    }
    private func body(_ s: String, size: CGFloat = 13, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.preferredMaxLayoutWidth = 580
        return l
    }
    private func caps(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }
    private func gap(_ h: CGFloat) -> NSView {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }
    /// A rounded panel around some rows.
    private func card(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.borderWidth = 1
        box.effectiveAppearance.performAsCurrentDrawingAppearance {
            box.layer?.backgroundColor = Theme.ui.sidebar.cgColor
            box.layer?.borderColor = Theme.ui.border.cgColor
        }
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            box.widthAnchor.constraint(equalToConstant: 604),
        ])
        return box
    }

    /// The scrolling page above a fixed footer with the step and the buttons.
    private func frame() {
        guard let c = window?.contentView else { return }
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        doc.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox(); line.boxType = .separator; line.translatesAutoresizingMaskIntoConstraints = false
        stepLabel.font = .systemFont(ofSize: 12)
        stepLabel.textColor = .tertiaryLabelColor
        for b in [back, later, go] { b.bezelStyle = .rounded; b.target = self }
        back.action = #selector(goBack)
        later.action = #selector(notNow)
        go.action = #selector(forward)
        go.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let foot = NSStackView(views: [stepLabel, spacer, later, back, go])
        foot.orientation = .horizontal; foot.spacing = 8
        foot.edgeInsets = NSEdgeInsets(top: 12, left: 28, bottom: 14, right: 20)
        foot.translatesAutoresizingMaskIntoConstraints = false

        c.addSubview(scroll); c.addSubview(line); c.addSubview(foot)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: c.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: foot.topAnchor),
            foot.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            foot.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            foot.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    private func show() {
        doc.subviews.forEach { $0.removeFromSuperview() }
        checkboxes = []; jobBox = nil; jobField = nil; jobNote = nil
        let views = step == 1 ? stepOne() : stepTwo()
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor),
        ])
        stepLabel.stringValue = "Step \(step) of 2"
        back.isHidden = step == 1
        later.isHidden = step == 1
        refreshGo()
        scroll.contentView.scroll(to: .zero)
    }

    // MARK: step 1, how you use AI today

    private func stepOne() -> [NSView] {
        var rows: [NSView] = []
        let title = NSTextField(labelWithString: report.profile.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        rows.append(title)
        for t in report.active.filter({ $0.id != "ollama" }) {
            var l = "\(t.name): \(t.last7) conversation\(t.last7 == 1 ? "" : "s") this week, \(t.last30) this month"
            if t.foldersLast30 > 0 { l += ", in \(t.foldersLast30) folder\(t.foldersLast30 == 1 ? "" : "s")" }
            rows.append(body("•  " + l, color: .labelColor))
        }
        let b = report.built
        if b.total + b.mcp > 0 {
            let parts = [(b.agents, "agent"), (b.skills, "skill"), (b.commands, "command"), (b.mcp, "MCP server")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
            rows.append(body("•  You've built " + parts.joined(separator: ", ") + " on top", color: .labelColor))
        }
        let quiet = report.tools.filter { $0.installed && !$0.active && $0.runtime != "ollama" }.map(\.name)
        if !quiet.isEmpty { rows.append(body("•  Installed, not used lately: " + quiet.joined(separator: ", "), color: .labelColor)) }
        if report.localModels > 0 { rows.append(body("•  \(report.localModels) local model\(report.localModels == 1 ? "" : "s") in Ollama", color: .labelColor)) }
        if !report.chatApps.isEmpty { rows.append(body("•  Chat apps: " + report.chatApps.joined(separator: ", "), color: .labelColor)) }
        if report.tools.filter({ $0.installed }).isEmpty {
            rows.append(body("•  No agent tools on this Mac yet. That's fine: the next step helps you pick one.", color: .labelColor))
        }

        let share = CopyButton(text: Checkup.share(report, version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""),
                               label: "Copy a summary to share")
        let privacy = body("Counted on this Mac from file names and dates, never what's in them. Nothing has left it. "
                           + "The summary has counts only, no folder or agent names.", size: 12, color: .tertiaryLabelColor)
        return [
            h1("Welcome to Project Coldfall"),
            body("Coldfall keeps your AI agents in one window, each at its own desk: one ongoing job, with its own folder "
                 + "and conversation, ready when you come back days or weeks later. It runs the real Claude Code, Codex and "
                 + "others, on the plans you already pay for."),
            gap(6),
            caps("How you use AI today"),
            card(rows),
            privacy,
            share,
        ]
    }

    // MARK: step 2, your first desk

    private func stepTwo() -> [NSView] {
        var views: [NSView] = []
        let builder = report.profile == .agentBuilder
        if tools.isEmpty {
            views.append(h1("Get one agent tool"))
            views.append(body("Coldfall runs agent tools like Claude Code and Codex, on a plan you already pay for. "
                              + "Which do you have?"))
            for p in FirstDesk.plans {
                let r = NSButton(radioButtonWithTitle: "\(p.title)   ", target: self, action: #selector(pickPlan(_:)))
                r.attributedTitle = titled(p.title, p.detail)
                r.state = p == plan ? .on : .off
                r.identifier = NSUserInterfaceItemIdentifier(p.runtime)
                views.append(r)
            }
            if let v = VendorInstall.all.first(where: { $0.runtime == plan.runtime }) {
                views.append(gap(4))
                var rows: [NSView] = []
                let t = NSTextField(labelWithString: v.title)
                t.font = .systemFont(ofSize: 13, weight: .semibold)
                rows.append(t)
                rows.append(body(v.needs))
                let cmd = NSTextField(labelWithString: v.command)
                cmd.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
                cmd.isSelectable = true
                let docs = NSButton(title: "Docs", target: self, action: #selector(openDocs(_:)))
                docs.bezelStyle = .rounded; docs.controlSize = .small
                docs.identifier = NSUserInterfaceItemIdentifier(v.docs)
                let row = NSStackView(views: [cmd, CopyButton(text: v.command), docs])
                row.orientation = .horizontal; row.spacing = 8
                rows.append(row)
                if let alt = v.alternative {
                    let a = NSTextField(labelWithString: (alt.hasPrefix("or ") ? "" : "or  ") + alt)
                    a.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                    a.textColor = .secondaryLabelColor
                    a.isSelectable = true
                    rows.append(a)
                }
                if v.command.hasPrefix("npm ") { rows.append(body(VendorInstall.npmNote, size: 12, color: .tertiaryLabelColor)) }
                rows.append(body("Open the Terminal app, paste it and press Return. When it finishes, run it once to sign in, "
                                 + "then press Check again."))
                let again = NSButton(title: "Check again", target: self, action: #selector(checkAgain))
                again.bezelStyle = .rounded
                rows.append(again)
                views.append(card(rows))
            }
            views.append(gap(6))
            views.append(updates())
            return views
        }

        views.append(h1(builder ? "Choose your first desks" : "Your first desk"))
        if builder {
            let n = options.filter { $0.kind == .agent }.count
            views.append(body("You've built \(n) agents. Tick the ones you want at a desk; the rest can join later "
                              + "from + in the desk list. A few is plenty to start."))
        } else if !options.isEmpty {
            views.append(body("Start with one. A desk is one ongoing job; you can add more any time."))
        } else {
            views.append(body("Start with one job. Coldfall makes a folder for it, and the agent keeps its notes there."))
        }

        var heading: String?
        for (i, o) in options.enumerated() {
            // An agent's folder goes in its heading, once, not on every row.
            let h = o.kind == .agent ? "Your agents, in \((o.cwd as NSString).lastPathComponent)" : "Folders you work in"
            if h != heading {
                if heading != nil, options[i - 1].kind == .folder { views.append(conversationNote()) }
                heading = h
                views.append(gap(4))
                views.append(caps(h))
            }
            let box = NSButton(checkboxWithTitle: o.name, target: self, action: #selector(tick(_:)))
            box.attributedTitle = titled(o.name, o.kind == .agent ? "" : o.cwd)
            box.state = o.on ? .on : .off
            box.tag = i
            checkboxes.append(box)
            var item: [NSView] = [box]
            let detail = o.kind == .agent ? (o.detail.hasPrefix("an agent you built") ? "" : o.detail) : o.detail
            if !detail.isEmpty {
                let d = body(detail, size: 12, color: .tertiaryLabelColor)
                d.preferredMaxLayoutWidth = 560
                item.append(indent(d))
            }
            let pair = NSStackView(views: item)
            pair.orientation = .vertical; pair.alignment = .leading; pair.spacing = 1
            views.append(pair)
        }
        if options.last?.kind == .folder { views.append(conversationNote()) }

        views.append(gap(4))
        views.append(caps(options.isEmpty ? "Your first job" : "Or a new job"))
        let jb = NSButton(checkboxWithTitle: "A new job, in its own folder", target: self, action: #selector(tickJob(_:)))
        jb.state = jobOn ? .on : .off
        jobBox = jb
        views.append(jb)
        let field = NSTextField(string: jobName)
        field.placeholderString = "first, or a name like research"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        jobField = field
        var parts: [NSView] = [field]
        if tools.count > 1 {
            let pop = NSPopUpButton(frame: .zero, pullsDown: false)
            for t in tools { pop.addItem(withTitle: t.name); pop.lastItem?.representedObject = t.runtime }
            pop.selectItem(at: tools.firstIndex { $0.runtime == jobRuntime } ?? 0)
            pop.target = self; pop.action = #selector(pickTool(_:))
            parts.append(pop)
        } else if let t = tools.first {
            parts.append(body("on \(t.name)", size: 12))
        }
        let jobRow = NSStackView(views: parts)
        jobRow.orientation = .horizontal; jobRow.spacing = 8
        views.append(indent(jobRow))
        let note = body("", size: 12, color: .tertiaryLabelColor)
        jobNote = note
        views.append(indent(note))
        noteJob()

        views.append(gap(8))
        views.append(updates())
        return views
    }

    /// Said once under the folders: what a desk in one does with its conversations.
    private func conversationNote() -> NSView {
        let runtimes = Set(options.filter { $0.kind == .folder }.map(\.runtime))
        var said: [String] = []
        if runtimes.contains("claude") { said.append("A Claude Code desk starts a new conversation there; your earlier ones stay in its history.") }
        if runtimes.contains("codex") { said.append("A Codex desk picks up your last conversation there.") }
        return indent(body(said.joined(separator: " "), size: 12, color: .tertiaryLabelColor))
    }

    private func updates() -> NSView {
        updateSwitch.state = UpdateState.load().enabled ? .on : .off
        let v = NSStackView(views: [updateSwitch, body(UpdateCheck.noticeBody, size: 11.5, color: .tertiaryLabelColor)])
        v.orientation = .vertical; v.alignment = .leading; v.spacing = 4
        return v
    }

    /// A bold name and a quieter detail on one line, for a checkbox or radio button.
    private func titled(_ name: String, _ detail: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                                     .foregroundColor: NSColor.labelColor])
        s.append(NSAttributedString(string: "   " + detail, attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                                          .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    private func indent(_ v: NSView) -> NSView {
        let row = NSStackView(views: [v])
        row.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        return row
    }

    // MARK: choosing

    private var chosen: [FirstDesk.Option] {
        var out = options.filter(\.on)
        if jobOn, !jobRuntime.isEmpty {
            out.append(FirstDesk.job(name: jobName.isEmpty ? "first" : jobName, runtime: jobRuntime, taken: Set(options.map(\.name))))
        }
        return out
    }

    private func refreshGo() {
        if step == 1 { go.title = "Continue"; go.isEnabled = true; return }
        let n = chosen.count
        go.title = tools.isEmpty ? "Create my desk" : n > 1 ? "Create \(n) desks" : "Create my desk"
        go.isEnabled = n > 0
    }

    private func noteJob() {
        guard let jobNote else { return }
        let n = FirstDesk.cleanName(jobName.isEmpty ? "first" : jobName)
        let file = jobRuntime == "claude" ? "CLAUDE.md" : "AGENTS.md"
        jobNote.stringValue = "Coldfall makes ~/Coldfall/\(n.isEmpty ? "first" : n) with a short \(file) the agent reads."
    }

    @objc private func tick(_ b: NSButton) {
        guard options.indices.contains(b.tag) else { return }
        options[b.tag].on = b.state == .on
        refreshGo()
    }
    @objc private func tickJob(_ b: NSButton) { jobOn = b.state == .on; refreshGo() }
    @objc private func pickTool(_ p: NSPopUpButton) {
        jobRuntime = p.selectedItem?.representedObject as? String ?? jobRuntime
        noteJob()
    }
    @objc private func pickPlan(_ b: NSButton) {
        if let p = FirstDesk.plans.first(where: { $0.runtime == b.identifier?.rawValue }) { plan = p }
        show()
    }
    func controlTextDidChange(_ n: Notification) {
        jobName = jobField?.stringValue ?? ""
        if !jobName.isEmpty, !jobOn { jobOn = true; jobBox?.state = .on }
        noteJob(); refreshGo()
    }

    @objc private func openDocs(_ sender: NSButton) {
        if let s = sender.identifier?.rawValue, let u = URL(string: s), u.scheme == "https" { NSWorkspace.shared.open(u) }
    }

    /// Look for agent tools again, without a relaunch.
    @objc private func checkAgain() {
        look()
        show()
    }

    @objc private func goBack() { step = 1; show() }

    @objc private func forward() {
        if step == 1 { step = 2; show(); return }
        finish(chosen)
    }

    /// Snapshot only (`--welcome-create`): press Create with what's ticked.
    func createAsShown() { finish(chosen) }

    /// Not now: the plain shell the first launch wrote, nothing else.
    @objc private func notNow() { finish([]) }

    private func finish(_ picked: [FirstDesk.Option]) {
        let fm = FileManager.default
        let dir = (DeskConfig.path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: DeskConfig.path) {
            try? (DeskConfig.starterTheme + "\n").write(toFile: DeskConfig.path, atomically: true, encoding: .utf8)
        }
        var existing = DeskConfig.load()
        let fresh = FirstDesk.desks(picked, existing: existing)
        // The first launch's plain shell goes when real desks replace it.
        if !fresh.isEmpty, existing.count == 1, let only = existing.first, only.name == "shell",
           only.runtime == "shell" || only.command == "exec zsh -l" {
            existing = []
        }
        if existing.isEmpty && fresh.isEmpty {
            existing = [Desk(name: "shell", runtime: "shell", cwd: "~")]
        }
        for (o, d) in zip(picked.filter(\.on), fresh) where o.kind == .job {
            var o = o; o.name = d.name
            FirstDesk.makeFolder(o)
        }
        DeskConfig.write(existing + fresh)
        UIState.markSeenWelcome()
        var upd = UpdateState.load()
        upd.enabled = updateSwitch.state == .on
        upd.noticeShown = true
        upd.save()
        close()
        onFinish?()
    }
}

/// Top-down layout for the Welcome screen's scrolling content.
private final class WelcomeDoc: NSView {
    override var isFlipped: Bool { true }
}

/// A Copy button that says Copied for a moment.
final class CopyButton: NSButton {
    private let text: String
    private let label: String
    init(text: String, label: String = "Copy") {
        self.text = text
        self.label = label
        super.init(frame: .zero)
        title = label
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(copyText)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.title = self?.label ?? "Copy" }
    }
}
