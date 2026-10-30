import AppKit
import ColdfallCore

/// Settings, so nobody has to hand-edit TOML to use this.
///
/// Three things people need to change: which desks exist, which CLIs Coldfall
/// found, and where agent mail lives. Writing the config back out keeps the file
/// as the source of truth — you can still edit it by hand, and this never
/// silently owns it.
final class SettingsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onSaved: (() -> Void)?
    private var desks: [Desk] = []
    private let table = NSTableView()
    private let name = NSTextField(), group = NSTextField()
    private let cwd = NSTextField(), command = NSTextField()
    private let account = NSTextField()
    private let budget = NSTextField()
    private let runtime = NSPopUpButton()
    private let themePalette = NSPopUpButton()
    private let themeMode = NSPopUpButton()
    private let themeFont = NSTextField()
    private let themeSize = NSTextField()
    private var editing: Int?
    /// desks.toml as it was when this window loaded it, and whether the
    /// desk list here has been edited since.
    private var openedWith: String?
    private var dirty = false
    private var projectDir = FileManager.default.currentDirectoryPath
    private let discoveredStack = NSStackView()
    private let hostsStack = NSStackView()

    convenience init(projectDir: String = FileManager.default.currentDirectoryPath) {
        // Never taller than the screen it opens on.
        let vis = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(860, vis.width - 40),
                                             height: min(600, vis.height - 60)),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.contentMinSize = NSSize(width: 700, height: 420)
        w.backgroundColor = Theme.ui.editor
        self.init(window: w)
        w.title = "Project Coldfall Settings"
        self.projectDir = projectDir
        desks = DeskConfig.load()
        openedWith = DeskSync.snapshot()
        build()
        // Edited elsewhere while this is open: with nothing changed here,
        // just show the new list.
        NotificationCenter.default.addObserver(forName: .coldfallDesksReloaded, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.dirty else { return }
            self.reloadFromDisk()
        }
        w.center()
    }

    private func caps(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: TextStyle.sentence(s))
        l.font = .systemFont(ofSize: 12, weight: .medium); l.textColor = .secondaryLabelColor
        return l
    }
    private func note(_ s: String, width: CGFloat = 520) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = width
        return l
    }
    private func field(_ f: NSTextField, _ ph: String) -> NSView {
        f.placeholderString = ph
        f.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        return f
    }

    private func build() {
        guard let c = window?.contentView else { return }

        for col in [("name", "Desk", 110), ("group", "Group", 130),
                    ("how", "Runs", 420)] {
            let t = NSTableColumn(identifier: .init(col.0))
            t.title = col.1; t.width = CGFloat(col.2)
            table.addTableColumn(t)
        }
        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let tScroll = NSScrollView(); tScroll.documentView = table
        tScroll.hasVerticalScroller = true; tScroll.borderType = .bezelBorder
        tScroll.translatesAutoresizingMaskIntoConstraints = false

        runtime.addItems(withTitles: ["claude", "codex", "antigravity", "copilot", "grok", "ollama"])
        let form = NSStackView(views: [
            caps("DESK"),
            field(name, "name, e.g. api"),
            field(group, "group (optional), e.g. work"),
            caps("RUNTIME"), runtime,
            field(cwd, "working directory, e.g. ~/src/api"),
            field(account, "account, e.g. ~/.claude-second"),
            field(budget, "weekly budget in dollars (optional), e.g. 50"),
            note("Optional, Claude only: the folder of a second Claude login. The first start asks you to sign in; "
               + "after that it stays on that account.", width: 350),
            caps("OR RUN THIS VERBATIM"),
            field(command, "command (optional) — overrides runtime"),
            note("Leave command empty to launch the runtime's own CLI. Use it when you "
               + "already have a wrapper script that handles resume-vs-new.", width: 350),
        ])
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 6

        // Appearance belongs here, not only in a TOML file. "Where do I go to
        // change the theme" having no answer but "edit a config file" is a
        // wrong answer for the thing a user looks at all day.
        let t = DeskConfig.themeSettings()
        themePalette.addItems(withTitles: ["vscode", "gruvbox", "nord", "solarized"])
        themePalette.selectItem(withTitle: t.palette ?? "vscode")
        themeMode.addItems(withTitles: ["dark", "light", "system"])
        themeMode.selectItem(withTitle: t.mode ?? "dark")
        themeFont.stringValue = t.font ?? "JetBrainsMono Nerd Font Mono"
        themeFont.placeholderString = "font, e.g. JetBrains Mono"
        themeSize.stringValue = String(t.size ?? 14)
        themeSize.placeholderString = "size"
        for f in [themeFont, themeSize] { f.font = .systemFont(ofSize: 12) }
        themeSize.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let themeRow = NSStackView(views: [themePalette, themeMode, themeSize])
        themeRow.orientation = .horizontal; themeRow.spacing = 8
        let themeBlock = NSStackView(views: [
            caps("APPEARANCE"), themeRow, themeFont,
            note("nord and solarized are dark only and stay dark in light mode, "
               + "rather than inventing a light variant badly. A font that is not "
               + "installed falls back to the next one that is."),
        ])
        themeBlock.orientation = .vertical; themeBlock.alignment = .leading; themeBlock.spacing = 6

        let addBtn = NSButton(title: "Add / Update", target: self, action: #selector(addOrUpdate))
        let delBtn = NSButton(title: "Remove", target: self, action: #selector(remove))
        let saveBtn = NSButton(title: "Save to desks.toml", target: self, action: #selector(save))
        saveBtn.keyEquivalent = "\r"
        [addBtn, delBtn, saveBtn].forEach { $0.bezelStyle = .rounded }
        let btns = NSStackView(views: [addBtn, delBtn, NSView(), saveBtn])
        btns.orientation = .horizontal; btns.spacing = 8

        // What Coldfall actually found, and what it can guarantee.
        var rtLines: [NSView] = [caps("RUNTIMES DETECTED")]
        for rt in Bridge.known {
            let p = DeskConfig.which(rt.bin)
            let l = NSTextField(labelWithString: (p != nil ? "✓  " : "✗  ") + rt.name
                + (p != nil ? (rt.readOnlyEnforced ? "   read-only enforced" : "   read-only not enforced") : "   not installed"))
            l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            l.textColor = p != nil ? .labelColor : .tertiaryLabelColor
            rtLines.append(l)
            // Not installed: how to install it, right there.
            if p == nil, let v = VendorInstall.of(rt.name) {
                let cmd = NSTextField(labelWithString: v.command)
                cmd.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
                cmd.textColor = .secondaryLabelColor
                cmd.isSelectable = true
                let row = NSStackView(views: [cmd, CopyButton(text: v.command)])
                row.orientation = .horizontal; row.spacing = 6
                row.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
                rtLines.append(row)
            }
        }
        rtLines.append(caps("LIVE PLAN LIMITS"))
        let limitsBtn = NSButton(title: Limits.recorderInstalled ? "Claude recorder installed ✓" : "Turn on live limits for Claude",
                                 target: self, action: #selector(installLimits))
        limitsBtn.bezelStyle = .rounded
        limitsBtn.isEnabled = !Limits.recorderInstalled
        rtLines.append(limitsBtn)
        // Each other Claude account has its own statusline, so its own recorder.
        for a in ClaudeAccount.used(by: desks) {
            let on = Limits.recorderInstalled(for: a)
            let b = NSButton(title: on ? "\(a.vendor) recorder installed ✓" : "Turn on live limits for \(a.vendor)",
                             target: self, action: #selector(installAccountLimits(_:)))
            b.bezelStyle = .rounded
            b.identifier = NSUserInterfaceItemIdentifier(a.folder)
            b.isEnabled = !on
            rtLines.append(b)
        }
        var seen: [String] = []
        for l in Limits.all() {
            var t = "✓  \(l.vendor)"
            if let w = l.weekPct { t += String(format: "  week %.0f%%", w) }
            if let p = l.planType { t += "  (\(p))" }
            seen.append(t)
        }
        let live = NSTextField(labelWithString: seen.isEmpty ? "no live limits yet" : seen.joined(separator: "\n"))
        live.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        rtLines.append(live)
        rtLines.append(note("Codex writes its quota into its own session log, so it needs nothing. "
            + "Claude tells only its statusline, so the button above installs a recorder as that "
            + "statusline — any statusline you already have keeps working, the recorder chains to it. "
            + "Any other tool can join by writing ~/.local/share/coldfall/limits/<vendor>.json."))
        rtLines.append(caps("KNOWING WHEN A DESK IS DONE"))
        let doneOn = DoneSignal.isInstalled
        let doneBtn = NSButton(title: doneOn ? "Agents report when they're done ✓" : "Let agents say when they're done",
                               target: self, action: #selector(toggleDoneHooks(_:)))
        doneBtn.bezelStyle = .rounded
        doneBtn.toolTip = "Adds a small hook to Claude Code (and Codex, if it's here) that notes when a desk's agent "
            + "finishes or needs you, so a desk turns green on the agent's word instead of a guess from its output. "
            + "It writes one line to a file on this Mac and sends nothing anywhere. Click again to remove it."
        rtLines.append(doneBtn)
        if !doneOn {
            let note = NSTextField(wrappingLabelWithString:
                "Without it, a desk turns green when its output stops, which can be fooled by a repaint.")
            note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
            rtLines.append(note)
        }
        rtLines.append(caps("AGENTS FOUND ON DISK"))
        discoveredStack.orientation = .vertical
        discoveredStack.alignment = .leading
        discoveredStack.spacing = 3
        rtLines.append(discoveredStack)
        rtLines.append(note("Agent definitions already in .claude/agents or .github/agents that "
            + "have no desk yet. Adding one creates a desk that launches the vendor's own CLI "
            + "with that agent."))
        refreshDiscovered()

        rtLines.append(caps("SSH HOSTS"))
        hostsStack.orientation = .vertical
        hostsStack.alignment = .leading
        hostsStack.spacing = 3
        rtLines.append(hostsStack)
        rtLines.append(note("Hosts from ~/.ssh/config with no desk yet. A remote box is exactly "
            + "what a desk is for — it holds state between visits. Connects by alias, so ssh "
            + "applies identity files and jump hosts from your own config."))
        refreshHosts()

        rtLines.append(caps("AGENT MAIL"))
        let box = Mailbox.load()
        rtLines.append(note("Threads are appended to \((box.dir as NSString).abbreviatingWithTildeInPath)."
            + (box.runner != nil ? " Using your own runner: \(box.runner!)." : " Using the built-in handoff.")))

        var updLines: [NSView] = [caps("UPDATES")]
        let upd = UpdateState.load()
        let updSwitch = NSButton(checkboxWithTitle: UpdateCheck.switchLabel, target: self,
                                 action: #selector(toggleUpdateCheck(_:)))
        updSwitch.state = upd.enabled ? .on : .off
        updLines.append(updSwitch)
        updLines.append(note(UpdateCheck.noticeBody.replacingOccurrences(
            of: " You can turn this off any time in Settings.", with: "")
            + " The server's code is in the repo under server/."))

        // Leaving, kept here on purpose: findable by someone looking for it,
        // and nowhere near Quit.
        updLines.append(caps("REMOVE Project Coldfall"))
        let bye = NSButton(title: "Remove Project Coldfall's Files…", target: self, action: #selector(openUninstall))
        bye.bezelStyle = .rounded
        updLines.append(bye)
        updLines.append(note("Shows exactly what it would delete first, and deletes nothing until you confirm. "
            + "Your agents, their logins and conversations aren't touched."))

        // Four tabs instead of one column. The single column was taller than
        // a laptop screen, and the window could not be made to fit it.
        // Reopening lives with the desks it applies to.
        let freshSwitch = NSButton(checkboxWithTitle: "Offer a clean start when reopening a big conversation",
                                   target: self, action: #selector(toggleFreshStart(_:)))
        freshSwitch.state = UIState.load().offerFreshStart ? .on : .off
        let startSwitch = NSButton(checkboxWithTitle: "Show a Start button before starting a desk",
                                   target: self, action: #selector(toggleConfirmStart(_:)))
        startSwitch.state = UIState.load().confirmStart ? .on : .off
        let reopen = NSStackView(views: [
            caps("STARTING DESKS"), startSwitch,
            note("Picking a desk that isn't running shows it with a Start button, so a stray click "
               + "starts nothing. Off, a click starts it straight away.", width: 350),
            caps("REOPENING DESKS"), freshSwitch,
            note("When a conversation of 150K tokens or more has sat for an hour, opening its desk asks "
               + "whether to pick up where you left off or start clean. Off, every desk always picks up "
               + "where it left off. To switch one desk on its own, right-click it.", width: 350),
        ])
        reopen.orientation = .vertical; reopen.alignment = .leading; reopen.spacing = 6
        let deskSide = NSStackView(views: [form, reopen, btns])
        deskSide.orientation = .vertical; deskSide.alignment = .leading; deskSide.spacing = 10
        let desksTab = NSStackView(views: [tScroll, deskSide])
        desksTab.orientation = .horizontal; desksTab.alignment = .top; desksTab.spacing = 16
        deskSide.widthAnchor.constraint(equalToConstant: 350).isActive = true
        tScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        for (title, content, scrolls) in [("Desks", desksTab as NSView, false),
                                          ("Appearance", column([themeBlock]), true),
                                          ("Agents", column(rtLines), true),
                                          ("General", column(updLines), true)] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = pad(content, scrolls: scrolls)
            tabs.addTabViewItem(item)
        }
        self.tabs = tabs
        c.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: c.topAnchor, constant: 8),
            tabs.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -12),
            tabs.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
        ])
    }

    private(set) var tabs: NSTabView?

    /// A vertical run of settings, as wide as a note.
    private func column(_ views: [NSView]) -> NSView {
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.alignment = .leading; s.spacing = 10
        return s
    }

    /// Inset a tab's content, and let it scroll when it is taller than the
    /// window rather than running off the bottom of the screen.
    private func pad(_ content: NSView, scrolls: Bool) -> NSView {
        let box = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        guard scrolls else {
            box.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
                content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
                content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
                content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            ])
            return box
        }
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -20),
        ])
        return box
    }

    func numberOfRows(in t: NSTableView) -> Int { desks.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let d = desks[row]
        let s: String
        switch col?.identifier.rawValue {
        case "name":  s = d.name
        case "group": s = d.group ?? "—"
        default:      s = d.command ?? (d.agent.map { "\(d.vendorLabel) --agent \($0)" } ?? d.vendorLabel)
        }
        let l = NSTextField(labelWithString: s)
        l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        l.lineBreakMode = .byTruncatingMiddle
        l.isBordered = false; l.drawsBackground = false
        return l
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        let r = table.selectedRow
        guard desks.indices.contains(r) else { return }
        editing = r
        let d = desks[r]
        name.stringValue = d.name
        group.stringValue = d.group ?? ""
        cwd.stringValue = d.cwd ?? ""
        command.stringValue = d.command ?? ""
        account.stringValue = d.account ?? ""
        budget.stringValue = d.budget.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? ""
        runtime.selectItem(withTitle: d.runtime)
    }

    /// Only agents without a desk are worth showing; the rest is noise.
    private func refreshDiscovered() {
        discoveredStack.subviews.forEach { $0.removeFromSuperview() }
        let found = Discovery.undeskedAgents(in: projectDir, desks: desks)
        if found.isEmpty {
            let l = NSTextField(labelWithString: "every agent already has a desk")
            l.font = .systemFont(ofSize: 11); l.textColor = .tertiaryLabelColor
            discoveredStack.addArrangedSubview(l)
            return
        }
        for a in found.prefix(20) {
            let b = NSButton(title: "＋  \(a.name)   \(a.runtime)", target: self,
                             action: #selector(addDiscovered(_:)))
            b.bezelStyle = .inline
            b.isBordered = false
            b.alignment = .left
            b.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            b.contentTintColor = .controlAccentColor
            b.toolTip = a.blurb + "\n\n" + a.path
            b.identifier = NSUserInterfaceItemIdentifier(a.name + "\u{1}" + a.runtime)
            discoveredStack.addArrangedSubview(b)
        }
    }

    @objc private func addDiscovered(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: "\u{1}").map(String.init)
        guard parts.count == 2,
              let a = Discovery.agents(in: projectDir).first(where: { $0.name == parts[0] && $0.runtime == parts[1] })
        else { return }
        desks.append(Discovery.desk(from: a, cwd: projectDir))
        dirty = true
        table.reloadData()
        refreshDiscovered()
    }

    private func refreshHosts() {
        hostsStack.subviews.forEach { $0.removeFromSuperview() }
        let found = SSHHosts.undesked(desks: desks)
        if found.isEmpty {
            let l = NSTextField(labelWithString:
                SSHHosts.all().isEmpty ? "no ~/.ssh/config hosts found" : "every host already has a desk")
            l.font = .systemFont(ofSize: 11); l.textColor = .tertiaryLabelColor
            hostsStack.addArrangedSubview(l)
            return
        }
        for h in found.prefix(20) {
            let b = NSButton(title: "＋  \(h.alias)   \(h.blurb)", target: self,
                             action: #selector(addHost(_:)))
            b.bezelStyle = .inline; b.isBordered = false; b.alignment = .left
            b.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            b.contentTintColor = .controlAccentColor
            b.toolTip = h.command
            b.identifier = NSUserInterfaceItemIdentifier(h.alias)
            hostsStack.addArrangedSubview(b)
        }
    }

    @objc private func addHost(_ sender: NSButton) {
        guard let alias = sender.identifier?.rawValue,
              let h = SSHHosts.all().first(where: { $0.alias == alias }) else { return }
        desks.append(SSHHosts.desk(from: h))
        dirty = true
        table.reloadData(); refreshHosts()
    }

    @objc private func addOrUpdate() {
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { NSSound.beep(); return }
        // Start from the desk being edited, so what this form does not show
        // (agent, model, default, trimmed MCP servers) survives the edit.
        var d = desks.first(where: { $0.name == n }) ?? Desk(name: n)
        d.group = group.stringValue.isEmpty ? nil : group.stringValue
        d.cwd = cwd.stringValue.isEmpty ? nil : cwd.stringValue
        d.command = command.stringValue.isEmpty ? nil : command.stringValue
        d.runtime = runtime.titleOfSelectedItem ?? "claude"
        let acct = account.stringValue.trimmingCharacters(in: .whitespaces)
        d.account = acct.isEmpty || d.runtime != "claude" ? nil : acct
        let cap = Double(budget.stringValue.replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces))
        d.budget = cap.flatMap { $0 > 0 ? $0 : nil }
        if let i = desks.firstIndex(where: { $0.name == n }) { desks[i] = d } else { desks.append(d) }
        dirty = true
        table.reloadData()
    }

    @objc private func toggleConfirmStart(_ sender: NSButton) {
        NotificationCenter.default.post(name: .coldfallConfirmStartChanged, object: sender.state == .on)
    }

    @objc private func openUninstall() {
        NotificationCenter.default.post(name: .coldfallOpenUninstall, object: nil)
    }

    @objc private func toggleFreshStart(_ sender: NSButton) {
        NotificationCenter.default.post(name: .coldfallFreshStartChanged, object: sender.state == .on)
    }

    @objc private func toggleUpdateCheck(_ sender: NSButton) {
        var s = UpdateState.load()
        s.enabled = sender.state == .on
        s.noticeShown = true        // they have plainly seen it now
        s.save()
    }

    @objc private func installAccountLimits(_ sender: NSButton) {
        guard let f = sender.identifier?.rawValue, let a = ClaudeAccount(folder: f) else { return }
        let msg = Limits.installRecorder(for: a)
        let al = NSAlert(); al.messageText = "Live plan limits for \(a.vendor)"; al.informativeText = msg
        al.runModal()
    }

    @objc private func toggleDoneHooks(_ sender: NSButton) {
        let on = DoneSignal.isInstalled
        let lines = on ? DoneSignal.uninstall(desks: desks) : DoneSignal.install(desks: desks)
        let a = NSAlert()
        a.messageText = on ? "Agents no longer report when they're done" : "Agents now report when they're done"
        a.informativeText = (lines.isEmpty ? "Nothing to change." : lines.joined(separator: "\n\n"))
            + (on ? "" : "\n\nDesks already running pick it up the next time they start.")
        a.runModal()
        sender.title = DoneSignal.isInstalled ? "Agents report when they're done ✓" : "Let agents say when they're done"
    }

    @objc private func installLimits() {
        let msg = Limits.installRecorder()
        let a = NSAlert(); a.messageText = "Live plan limits"; a.informativeText = msg
        a.runModal()
    }

    @objc private func remove() {
        guard desks.indices.contains(table.selectedRow) else { return }
        desks.remove(at: table.selectedRow)
        dirty = true
        table.reloadData()
        refreshDiscovered(); refreshHosts()
    }

    private func reloadFromDisk() {
        desks = DeskConfig.load()
        openedWith = DeskSync.snapshot()
        dirty = false
        table.reloadData()
    }

    @objc private func save() {
        // Never write this window's list over an edit made while it was open.
        if let now = DeskSync.snapshot(), now != openedWith {
            let a = NSAlert()
            a.messageText = "desks.toml changed while Settings was open"
            a.informativeText = "Something else edited it, and saving now would undo that edit. "
                + "Reload Settings to see the current desks, then make your changes again."
            a.addButton(withTitle: "Reload Settings"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { reloadFromDisk() }
            return
        }
        // The theme goes out with the desks. Saving used to rebuild the file
        // from the desk list alone, which silently deleted [theme].
        var t = DeskConfig.themeSettings()
        t.palette = themePalette.titleOfSelectedItem
        t.mode = themeMode.titleOfSelectedItem
        t.font = themeFont.stringValue.trimmingCharacters(in: .whitespaces)
        t.size = Int(themeSize.stringValue) ?? t.size
        Theme.invalidate()
        defer { Theme.applyGlobally() }   // switching dark/light takes effect now, every window
        DeskConfig.write(desks, theme: t)
        onSaved?()
        close()
    }
}
