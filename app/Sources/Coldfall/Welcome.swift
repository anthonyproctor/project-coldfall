import AppKit
import ColdfallCore

/// What a stranger sees the first time they open Coldfall.
///
/// The job is to answer three questions before they touch anything: what is a
/// desk, what did you find on my machine, and what happens if I press the
/// button. It writes a working config from whatever CLIs are actually
/// installed, so nobody starts at an empty window or a blank TOML file.
final class WelcomeWindow: NSWindowController {
    var onFinish: (() -> Void)?
    private var checks: [(Bridge.Runtime, Bool)] = []
    private var projectDir = FileManager.default.currentDirectoryPath
    private var found: [DiscoveredAgent] = []
    private let updateSwitch = NSButton(checkboxWithTitle: UpdateCheck.switchLabel, target: nil, action: nil)
    /// Snapshot only: draw the first run of a Mac with no vendor CLI.
    static var pretendNothingInstalled = false

    convenience init(projectDir: String = FileManager.default.currentDirectoryPath) {
        let vis = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: min(700, vis.height - 80)),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.contentMinSize = NSSize(width: 560, height: 420)
        self.init(window: w)
        w.title = "Welcome to Project Coldfall"
        w.backgroundColor = Theme.ui.editor
        self.projectDir = projectDir
        self.found = Discovery.agents(in: projectDir)
        build()
        w.center()
    }

    private func h1(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 26, weight: .semibold)
        return l
    }
    private func body(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 580
        return l
    }
    private func caps(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: TextStyle.sentence(s))
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func build() {
        guard let c = window?.contentView else { return }
        checks = Bridge.known.map { ($0, !WelcomeWindow.pretendNothingInstalled && DeskConfig.which($0.bin) != nil) }
        let found = checks.filter { $0.1 }

        var views: [NSView] = [
            h1("Welcome to Project Coldfall"),
            body("Coldfall keeps your AI agents side by side in one window. Each one gets a desk: "
               + "its own folder, its own instructions and its own conversation, ready when you "
               + "come back, days or weeks later.\n\n"
               + "It runs the real Claude Code, Codex and other tools, on the plans you already pay for. "
               + "They keep working the same way, with or without Coldfall."),
        ]

        // A column of six crosses says nothing the install list below doesn't.
        if !found.isEmpty { views.append(caps("FOUND ON THIS Mac")) }
        for (rt, ok) in checks where !found.isEmpty {
            let line = NSTextField(labelWithString:
                (ok ? "✓  " : "✗  ") + rt.name + (ok ? "" : "   not installed"))
            line.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            line.textColor = ok ? .labelColor : .tertiaryLabelColor
            views.append(line)
        }

        if found.isEmpty {
            // The dead end this used to be: "install one, then reopen". Now
            // the commands are here, and Check again looks without a relaunch.
            views.append(body("You need at least one AI tool to get started, and none are on this Mac yet. "
                + "Pick one below and press Copy. Open the Terminal app, paste it and press Return. "
                + "When it finishes, press Check again."))
            views.append(caps("PICK ONE TO INSTALL"))
            for v in VendorInstall.all { views += installRows(v) }
            views.append(body(VendorInstall.npmNote))
            let again = NSButton(title: "Check again", target: self, action: #selector(checkAgain))
            again.bezelStyle = .rounded
            views.append(again)
        } else {
            views.append(body("Coldfall will make a desk for "
                + found.map(\.0.name).joined(separator: ", ")
                + ", plus a plain terminal desk, which uses no tokens. "
                + "You can change them any time in Settings."))
        }

        if found.count >= 2 {
            views.append(caps("AGENT Mail"))
            views.append(body("You have more than one tool, so your agents can check each other's work. "
                + "Press ⇧⌘M to put a question to a second agent. It sees the whole conversation so far "
                + "and answers in a file you can keep. Where the tool allows it, "
                + "the second agent can only read, not change anything."))
        }

        // Someone with existing agents should not have to configure anything.
        if !self.found.isEmpty {
            views.append(caps("AGENTS ALREADY IN THIS FOLDER"))
            views.append(body("Found \(self.found.count) agent"
                + (self.found.count == 1 ? "" : "s")
                + " you've already set up here. Coldfall will make a desk for each. "
                + "Remove any you don't want in Settings."))
            let names = self.found.prefix(8).map(\.name).joined(separator: ", ")
            let l = NSTextField(wrappingLabelWithString: names
                + (self.found.count > 8 ? ", and \(self.found.count - 8) more" : ""))
            l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = 580
            views.append(l)
        }

        views.append(caps("UPDATES"))
        views.append(body(UpdateCheck.noticeTitle + " " + UpdateCheck.noticeBody))
        updateSwitch.state = UpdateState.load().enabled ? .on : .off
        views.append(updateSwitch)

        let go = NSButton(title: found.isEmpty ? "Continue" : "Create my desks",
                          target: self, action: #selector(finish))
        go.bezelStyle = .rounded
        go.keyEquivalent = "\r"
        views.append(go)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Scrolls, so a long list of found agents or install steps never
        // pushes the button off the bottom of the screen.
        let doc = WelcomeDoc()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: c.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor),
        ])
    }

    /// One vendor's install step: what it is, what it needs, the command with
    /// a Copy button, another way if there is one, and its docs.
    private func installRows(_ v: VendorInstall) -> [NSView] {
        let title = NSTextField(labelWithString: v.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let gap = NSView()
        gap.heightAnchor.constraint(equalToConstant: 4).isActive = true
        let cmd = NSTextField(labelWithString: v.command)
        cmd.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        cmd.isSelectable = true
        let copy = CopyButton(text: v.command)
        let docs = NSButton(title: "Docs", target: self, action: #selector(openDocs(_:)))
        docs.bezelStyle = .rounded
        docs.controlSize = .small
        docs.toolTip = v.docs
        docs.identifier = NSUserInterfaceItemIdentifier(v.docs)
        let row = NSStackView(views: [cmd, copy, docs])
        row.orientation = .horizontal; row.spacing = 8
        var out: [NSView] = [gap, title, body(v.needs), row]
        if let alt = v.alternative {
            let a = NSTextField(labelWithString: alt.hasPrefix("or ") ? alt : "or  " + alt)
            a.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            a.textColor = .secondaryLabelColor
            a.isSelectable = true
            out.append(a)
        }
        return out
    }

    @objc private func openDocs(_ sender: NSButton) {
        if let s = sender.identifier?.rawValue, let u = URL(string: s), u.scheme == "https" { NSWorkspace.shared.open(u) }
    }

    /// Look for CLIs again, without a relaunch.
    @objc private func checkAgain() {
        window?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        build()
    }

    @objc private func finish() {
        DeskConfig.writeStarter()
        // Append discovered agents to whatever the starter wrote.
        if !found.isEmpty {
            var desks = DeskConfig.load()
            for a in Discovery.undeskedAgents(in: projectDir, desks: desks) {
                desks.append(Discovery.desk(from: a, cwd: projectDir))
            }
            DeskConfig.write(desks)
        }
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
    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        title = "Copy"
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.title = "Copy" }
    }
}
