// Coldfall M1 — the desk switcher.
//
// The agent is the unit of work. Each desk owns a long-lived terminal running
// the vendor's own CLI; switching desks swaps which one is visible without
// touching the process. Close the window, the desk keeps running.

import AppKit
import SwiftTerm
import ColdfallCore

// MARK: - app

final class Controller: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate, NSSplitViewDelegate, NSWindowDelegate, NSMenuDelegate {
    var window: NSWindow!
    let sidebar = SidebarView()
    let tree = FileTreeView()
    /// Where the desk that has the keys is drawn: its cell of the grid.
    var host: NSView { slots[keySlot].view }
    let reader = ReaderView()
    let split = SoftSplitView()
    let meter = MeterBar()
    let watcher = WorkspaceWatcher()
    var desks: [Desk] = []
    var sessions: [String: DeskSession] = [:]
    var visible: DeskSession?
    var ui = UIState.load()
    let deskScroll = NSScrollView()
    let strip = TitleStrip()
    var rail: NSSplitView!
    /// The middle column: a header naming the desk, and the terminal under it.
    let center = NSView()
    let tabs = TabBar()
    /// The reader's home when it is docked beside the terminal (the default).
    let readerPane = NSView()
    /// Collapses the meter to nothing when it is toggled off.
    var meterZero: NSLayoutConstraint!
    let palette = Palette()
    let updates = Updates()
    var promptHelper: PromptHelper?

    @objc func openPromptHelper() {
        if promptHelper == nil { promptHelper = PromptHelper() }
        promptHelper?.showWindow(nil)
        promptHelper?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        #if COLDFALL_GHOSTTY
        // `--ghostty-demo [command]`: one Ghostty terminal in a window and
        // nothing else: no desks, no rail. For trying the new terminal by
        // hand before it becomes a pane. With COLDFALL_GHOSTTY_SELFTEST set
        // to a file, it types a line, writes the screen's text there and quits.
        // `--ghostty-held <program>`: a held desk drawn by Ghostty, its state
        // read through the holder. With COLDFALL_GHOSTTY_SELFTEST set, it
        // answers the program's question with "2" after a few seconds, then
        // quits; the states it went through are printed as they change.
        if let k = CommandLine.arguments.firstIndex(of: "--ghostty-held"), k + 1 < CommandLine.arguments.count {
            guard let holder = Pane.holderPath, Holder.ensureRoot(),
                  let d = GhosttyDemo.openHeld(program: CommandLine.arguments[k + 1], holder: holder) else {
                FileHandle.standardError.write("The held Ghostty desk couldn't start.\n".data(using: .utf8)!)
                exit(1)
            }
            if ProcessInfo.processInfo.environment["COLDFALL_GHOSTTY_SELFTEST"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { d.view.send(text: "2") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
                    print("screen: " + d.view.screenText(lines: 12).replacingOccurrences(of: "\n", with: " | ")); fflush(stdout)
                    _ = Holder.end(desk: "ghostty-demo")
                    d.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
                }
            }
            return
        }
        if let k = CommandLine.arguments.firstIndex(of: "--ghostty-demo") {
            let cmd = k + 1 < CommandLine.arguments.count ? CommandLine.arguments[k + 1] : "/bin/zsh -l"
            guard let v = GhosttyDemo.open(command: cmd) else {
                FileHandle.standardError.write("Ghostty's terminal couldn't start.\n".data(using: .utf8)!)
                exit(1)
            }
            if let out = ProcessInfo.processInfo.environment["COLDFALL_GHOSTTY_SELFTEST"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { v.send(text: "typed by the self test\r") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    try? v.screenText(lines: 40).write(toFile: out, atomically: true, encoding: .utf8)
                    if let w = GhosttyDemo.window {
                        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        p.arguments = ["-x", "-o", "-l\(w.windowNumber)", out + ".png"]
                        try? p.run(); p.waitUntilExit()
                    }
                    exit(0)
                }
            }
            return
        }
        #endif
        // Before anything builds a row.
        // In the rail's order, so cmd-1..9 match what is on screen even when
        // a group's desks are scattered through the file.
        desks = DeskOrder.grouped(DeskConfig.load())
        // `--snapshot ... --desks <file.toml>`: picture a made-up desk list
        // instead of the real one. Only with --snapshot, which never saves.
        let args = CommandLine.arguments
        if args.contains("--snapshot"), let k = args.firstIndex(of: "--desks"), k + 1 < args.count {
            desks = DeskOrder.grouped(DeskConfig.load(path: args[k + 1]))
        }
        // `--snapshot ... --reader-hidden`: as if the reader were toggled off.
        // Not saved; snapshots never write the user's layout.
        if args.contains("--snapshot"), args.contains("--reader-hidden") { ui.readerHidden = true }
        // `--desks-on-top` and `--meter-hidden`, for pictures of made-up
        // desks: the rail's desks above the tree, and no real usage numbers.
        if args.contains("--snapshot"), args.contains("--desks-on-top") { ui.treeOnTop = false }
        if args.contains("--snapshot"), args.contains("--meter-hidden") { ui.meterHidden = true }
        let firstRun = desks.isEmpty || !ui.seenWelcome
        if desks.isEmpty {
            DeskConfig.writeStarter()
            // The theme was read before this file existed. Read it again, or
            // the first launch, the one that counts, ignores the starter's.
            Theme.applyGlobally()
            desks = DeskOrder.grouped(DeskConfig.load())
        }
        if desks.isEmpty {
            desks = [Desk(name: "shell", command: "exec zsh -l")]
        }

        // Size to the screen so the resize corner is always reachable. The window
        // was opening taller than the display, which made it look unresizable.
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // `COLDFALL_WINDOW=1500x900` asks for another size, for pictures.
        let asked = (ProcessInfo.processInfo.environment["COLDFALL_WINDOW"] ?? "").split(separator: "x").compactMap { Double($0) }
        let frame = NSRect(x: 0, y: 0,
                           width: min(asked.count == 2 ? asked[0] : 1240, vis.width - 40),
                           height: min(asked.count == 2 ? asked[1] : 820, vis.height - 40))
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Project Coldfall"
        window.titlebarAppearsTransparent = true

        // Left rail: desks on top, folder tree beneath, with a DRAGGABLE divider.
        // A fixed desk height starved the tree once the list got long.
        deskScroll.documentView = sidebar
        deskScroll.hasVerticalScroller = true
        deskScroll.drawsBackground = false
        deskScroll.automaticallyAdjustsContentInsets = false

        rail = SoftSplitView()
        rail.delegate = self
        rail.isVertical = false          // stacked, so the divider is horizontal
        rail.dividerStyle = .thin
        applyRailOrder()
        rail.wantsLayer = true
        Theme.paint(rail, Theme.ui.sidebar)

        split.delegate = self
        split.isVertical = true
        split.dividerStyle = .thin
        // Rail | terminal | reader. The reader used to live in a separate
        // floating window you had to arrange by hand; VS Code shows files
        // inside the window, beside the sidebar. It can still pop out.
        // The desks on screen: one, or several side by side.
        deskSplit.translatesAutoresizingMaskIntoConstraints = false
        deskSplit.set(slots.map(\.view))
        center.addSubview(tabs); center.addSubview(deskSplit)
        // The cards bring their own gap; this keeps them off the window's edges.
        let inset: CGFloat = 4
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: center.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            deskSplit.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            deskSplit.leadingAnchor.constraint(equalTo: center.leadingAnchor, constant: inset),
            deskSplit.trailingAnchor.constraint(equalTo: center.trailingAnchor, constant: -inset),
            deskSplit.bottomAnchor.constraint(equalTo: center.bottomAnchor, constant: -inset),
        ])
        Theme.paint(readerPane, Theme.ui.editor)
        split.addArrangedSubview(rail)
        split.addArrangedSubview(center)
        split.addArrangedSubview(readerPane)
        // Meter along the bottom, under both panes.
        let outer = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        meter.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(strip); outer.addSubview(split); outer.addSubview(meter)
        // The system title would be drawn over the rail; the strip shows it
        // centred instead.
        window.titleVisibility = .hidden
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: outer.topAnchor),
            strip.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            // The standard titlebar height, so the traffic lights sit centred.
            strip.heightAnchor.constraint(equalToConstant: 28),
            split.topAnchor.constraint(equalTo: strip.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            meter.topAnchor.constraint(equalTo: split.bottomAnchor),
            meter.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            meter.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            meter.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
        ])
        meterZero = meter.heightAnchor.constraint(equalToConstant: 0)
        meterZero.priority = .required
        window.contentView = outer
        applySavedLayout()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let w = self.window.contentView?.bounds.width ?? frame.width
            self.split.setPosition(240, ofDividerAt: 0)
            // The reader takes about a third, never less than it needs to be
            // readable, never so much that the terminal is squeezed.
            let readerW = max(300, min(520, w * 0.34))
            if self.readerPane.superview === self.split {
                self.split.setPosition(w - readerW, ofDividerAt: 1)
            } else {
                self.readerWidth = readerW    // for when it is shown
            }
            // Desks first, as much as they need up to 70%; the tree keeps the rest.
            self.fitRail()
        }

        tree.onOpen = { [weak self] url in self?.openReader(url) }
        strip.onSearch = { [weak self] in self?.openPalette() }
        strip.onToggleRail = { [weak self] in self?.toggleRail() }
        strip.onToggleReader = { [weak self] in self?.toggleReader() }
        strip.onToggleMeter = { [weak self] in self?.toggleMeter() }
        strip.onUpdate = { [weak self] in self?.updates.openRelease() }
        DeskSession.onHeaderDrag = { [weak self] s, pt, dropped in self?.headerDragged(s, to: pt, dropped: dropped) }
        DeskSession.onPaneAction = { [weak self] s, a in
            guard let self else { return }
            // The button's own desk, when several are on screen.
            if s !== self.visible, let k = self.slotIndex(of: s) { self.focusSlot(k) }
            switch a {
            case .splitRight: self.splitRight()
            case .splitDown: self.splitDown()
            case .close: self.closePane()
            case .zoom: self.zoomPane()
            }
        }
        sidebar.onBesideDesk = { [weak self] i in self?.openBeside(i) }
        DeskSession.onPaneExit = { [weak self] v in self?.paneExited(v) }
        tabs.onPromptHelper = { [weak self] in self?.openPromptHelper() }
        tabs.onSelect = { [weak self] n in
            guard let self, let i = self.deskIndex(n) else { return }
            self.open(i)
        }
        tabs.onMenu = { [weak self] n in self?.tabMenu(n) }
        tabs.onStop = { [weak self] n in
            guard let self, let i = self.deskIndex(n) else { return }
            self.stopDesk(i)
        }
        tabs.plusMenu = { [weak self] in self?.tabPlusMenu() }
        reader.onPopToggle = { [weak self] in self?.popOutOrDock() }
        palette.onPickDesk = { [weak self] i in self?.open(i) }
        palette.onPickFile = { [weak self] u in self?.openReader(u) }
        palette.deskMenu = { [weak self] in
            guard let self else { return nil }
            let name = self.visible?.desk.name ?? self.waitingName
            guard let n = name, let i = self.deskIndex(n), let m = self.sidebar.actionMenu(for: i) else { return nil }
            return (n, m)
        }
        meter.onClick = { [weak self] in self?.openMeter() }
        meter.onNeedsYou = { [weak self] in self?.openFeed() }
        feed.items = { [weak self] in self?.feedItems() ?? [] }
        tabs.onChanges = { [weak self] in self?.openChanges() }
        // Review comments go the road every send goes: refused while the
        // desk is asking something or you are mid-message there.
        changes.onSend = { [weak self] name, text in
            guard let self else { return (false, "Nothing to send to.") }
            let a = self.inboxSend(name, text: text)
            return (a.outcome == .sent, a.message)
        }
        feed.onGo = { [weak self] n in self?.showDesk(named: n) }
        feed.onAnswer = { [weak self] n, o in self?.answer(desk: n, with: o) }
        meter.onReport = { [weak self] r in self?.applyBudgets(r) }

        // The VS Code behaviour: files the agent touches open themselves.
        watcher.onChanged = { [weak self] urls in
            guard let self else { return }
            for u in urls.prefix(3) { self.reader.openFromAgent(u) }
            // Files an agent touches still open as tabs, but if the user hid
            // the reader they meant it: an agent's edit does not force it back.
            if !urls.isEmpty, self.reader.poppedOut, self.readerWindow?.isVisible != true {
                self.readerWindow?.orderFront(nil)
            }
            self.tree.refresh()
        }

        sidebar.collapsed = Set(ui.collapsed)
        sidebar.liveOn = ui.liveRail
        sidebar.onToggleLive = { [weak self] in self?.toggleLiveRail() }
        sidebar.onSelectGroup = { [weak self] g in self?.goToGroup(g) }
        sidebar.onPinDesk = { [weak self] i, on in self?.pinDesk(i, on) }
        sidebar.onColorDesk = { [weak self] i, c in self?.colorDesk(i, c) }
        sidebar.onAddOffer = { [weak self] rt in self?.addOfferedDesk(rt) }
        sidebar.onDismissOffer = { [weak self] rt in self?.dismissOffer(rt) }
        sidebar.build(desks: desks)
        sidebar.onToggleGroup = { [weak self] g in self?.toggleGroup(g) }
        sidebar.onRenameGroup = { [weak self] g in self?.renameGroup(g) }
        sidebar.onRemoveDesk = { [weak self] i in self?.removeDesk(i) }
        sidebar.onMakeDefault = { [weak self] i in self?.makeDefault(i) }
        sidebar.onRevealAgent = { [weak self] i in self?.revealAgent(i) }
        sidebar.onSelect = { [weak self] i in self?.open(i) }
        sidebar.onRenameDesk = { [weak self] i in self?.renameDesk(i) }
        sidebar.onMcpDesk = { [weak self] i in self?.editMcp(i) }
        sidebar.onInventoryDesk = { [weak self] i in self?.showInventory(i) }
        sidebar.onHideDesk = { [weak self] i in self?.hideDesk(i) }
        NotificationCenter.default.addObserver(forName: .coldfallOpenUninstall, object: nil, queue: .main) {
            [weak self] _ in self?.openUninstall()
        }
        NotificationCenter.default.addObserver(forName: .coldfallConfirmStartChanged, object: nil, queue: .main) {
            [weak self] n in
            guard let self, let on = n.object as? Bool else { return }
            self.ui.confirmStart = on
            self.ui.save()
        }
        sidebar.onOpenNews = { [weak self] c in
            if let u = c.url, let url = URL(string: u) { NSWorkspace.shared.open(url) }
            self?.ui.agentUpdates[c.runtime] = nil; self?.ui.save(); self?.showAgentNews()
        }
        sidebar.onDismissNews = { [weak self] c in
            self?.ui.agentUpdates[c.runtime] = nil; self?.ui.save(); self?.showAgentNews()
        }
        // The switch lives in Settings; the state lives here, and is what
        // gets saved, so Settings says what to set rather than writing it.
        NotificationCenter.default.addObserver(forName: .coldfallFreshStartChanged, object: nil, queue: .main) {
            [weak self] n in
            guard let self, let on = n.object as? Bool else { return }
            self.ui.offerFreshStart = on
            self.ui.save()
        }
        NotificationCenter.default.addObserver(forName: .coldfallReopenSettings, object: nil, queue: .main) {
            [weak self] n in
            guard let self else { return }
            let frame = self.settings?.window?.frame
            self.settings?.close()
            self.openSettings()
            if let f = frame { self.settings?.window?.setFrame(f, display: true) }
            if let tab = n.object as? String,
               let item = self.settings?.tabs?.tabViewItems.first(where: { ($0.identifier as? String) == tab }) {
                self.settings?.tabs?.selectTabViewItem(item)
            }
        }
        NotificationCenter.default.addObserver(forName: .coldfallInboxChanged, object: nil, queue: .main) {
            [weak self] n in
            guard let self else { return }
            if let on = n.object as? Bool { self.ui.inboxOn = on; self.ui.save() }
            self.inboxServer?.stop()
            self.applyInbox()
        }
        NotificationCenter.default.addObserver(forName: .coldfallNotifyChanged, object: nil, queue: .main) {
            [weak self] n in
            guard let self, let on = n.object as? Bool else { return }
            self.ui.notifyDesks = on
            self.ui.save()
        }
        NotificationCenter.default.addObserver(forName: .coldfallTerminalChanged, object: nil, queue: .main) {
            [weak self] n in
            guard let self, let t = n.object as? String else { return }
            self.ui.terminal = t
            Pane.wantsGhostty = t == "ghostty"
            self.ui.save()
        }
        NotificationCenter.default.addObserver(forName: .coldfallSleepChanged, object: nil, queue: .main) {
            [weak self] n in
            guard let self, let m = n.object as? Int else { return }
            self.ui.sleepIdleMinutes = m
            self.ui.save()
        }
        NotificationCenter.default.addObserver(forName: .coldfallKeepRunningChanged, object: nil, queue: .main) {
            [weak self] n in
            guard let self, let on = n.object as? Bool else { return }
            self.ui.keepDesksRunning = on
            DeskSession.keepGlobal = on
            self.ui.save()
        }
        sidebar.onToggleAskResume = { [weak self] i in
            guard let self, self.desks.indices.contains(i) else { return }
            self.desks[i].alwaysResume.toggle()
            self.persist()
            self.refreshRail()
        }
        sidebar.onUnhideDesk = { [weak self] i in self?.unhideDesk(i) }
        sidebar.onStopDesk = { [weak self] i in self?.stopDesk(i) }
        sidebar.onPeekDesk = { [weak self] i in self?.peekDesk(i) }
        sidebar.onMarkUnreadDesk = { [weak self] i in
            guard let self, self.desks.indices.contains(i) else { return }
            self.sessions[self.desks[i].name]?.markUnread()
        }
        sidebar.byPriority = ui.desksByPriority || CommandLine.arguments.contains("--by-priority")
        sidebar.onTogglePriority = { [weak self] in self?.toggleDeskPriority() }
        // An installed done hook is brought up to this version's script (it
        // now passes on why an agent is waiting). Never in a snapshot.
        if !CommandLine.arguments.contains("--snapshot") { DoneSignal.refreshScript() }
        peek.onGo = { [weak self] d in
            guard let self, let i = self.deskIndex(d) else { return }
            self.show(i)
        }
        sidebar.onMoveDesk = { [weak self] i, d in self?.moveDesk(i, to: d) }
        sidebar.onMoveGroup = { [weak self] g, b in self?.moveGroup(g, before: b) }
        sidebar.onSortDesks = { [weak self] in self?.sortDesks() }
        sidebar.onJumpToWaiting = { [weak self] n in self?.showDesk(named: n) }
        sidebar.onClearWaiting = { [weak self] in self?.clearWaiting() }

        // Set the appearance BEFORE showing: every semantic colour in the app
        // resolves off it, so flipping after the fact repaints everything.
        Theme.apply(to: window)
        for sl in slots { Theme.paint(sl.view, Theme.ui.sidebar) }
        Theme.paint(center, Theme.ui.sidebar)

        // `--snapshot <file.png>`: lay the window out, save a picture of it,
        // and quit — WITHOUT starting any desk process and without ever
        // putting a window on screen.
        //
        // This exists because the user runs their own agent sessions inside
        // this app, so relaunching it to check a UI change ends the very
        // conversation doing the checking. A separate copy that never starts a
        // desk and never shows a window can be looked at safely. Sample
        // statuses are filled in so every row state is visible at once.
        if let k = CommandLine.arguments.firstIndex(of: "--snapshot"),
           k + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[k + 1]
            // `--select <desk>`: show that desk instead of the startup one.
            let picked = CommandLine.arguments.firstIndex(of: "--select")
                .flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
                .flatMap { n in desks.firstIndex { $0.name == n } }
            let i = picked ?? DeskConfig.startup(in: desks)
            if desks.indices.contains(i) {
                sidebar.select(i)
                tree.setRoot(desks[i].resolvedCwd)
                let d = desks[i]
                strip.setContext(d.name)
                snapDesk = d.name
            }
            // `--waiting`: the launch screen, the desk shown but not started.
            if CommandLine.arguments.contains("--waiting"), desks.indices.contains(i) {
                // `--restore a,b`: with the desks that were running offered back.
                let a = CommandLine.arguments
                if let k = a.firstIndex(of: "--restore"), k + 1 < a.count {
                    restoreOffer = a[k + 1].split(separator: ",").map(String.init)
                }
                showWaiting(i)
            }
            // `--terminal <file>`: that desk's terminal showing the file's
            // text, as captured from a real command. Nothing is started.
            if let k = CommandLine.arguments.firstIndex(of: "--terminal"), k + 1 < CommandLine.arguments.count,
               desks.indices.contains(i),
               let text = try? String(contentsOfFile: CommandLine.arguments[k + 1], encoding: .utf8) {
                let s = DeskSession(desk: desks[i])
                sessions[desks[i].name] = s
                host.addSubview(s.container)
                s.container.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    s.container.topAnchor.constraint(equalTo: host.topAnchor),
                    s.container.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    s.container.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    s.container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                ])
                s.panes.first?.terminal.feed(text: text.replacingOccurrences(of: "\n", with: "\r\n"))
                // `--beside <desk>`: with that desk next to it (not started).
                // Several, separated by commas, make a grid.
                if let b = CommandLine.arguments.firstIndex(of: "--beside"), b + 1 < CommandLine.arguments.count {
                    visible = s
                    slots[keySlot].session = s
                    for name in CommandLine.arguments[b + 1].split(separator: ",").map(String.init) {
                        guard let other = desks.first(where: { $0.name == name }), sessions[name] == nil,
                              other.name != desks[i].name, slots.count < DeskGrid.most else { continue }
                        let o = DeskSession(desk: other)
                        sessions[other.name] = o
                        mount(o, in: addSlot())
                        o.isVisible = true
                        o.panes.first?.terminal.feed(text: "> waiting for you\r\n")
                    }
                    syncPairFocus()
                    refreshTabs(sidebar.status)
                }
                // `--split`: with a shell pane beside it, to see the cards.
                if CommandLine.arguments.contains("--split") { s.addPaneForPicture() }
            }
            // `--open <file>`: that file in the reader.
            if let k = CommandLine.arguments.firstIndex(of: "--open"), k + 1 < CommandLine.arguments.count {
                openReader(URL(fileURLWithPath: CommandLine.arguments[k + 1]))
            }
            // `--palette <query>` also renders the quick-open box with that
            // query typed in, to <out>-palette.png.
            let paletteQuery: String? = CommandLine.arguments.firstIndex(of: "--palette")
                .flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
            var sample: [String: DeskStatus] = [:]
            let now = Date()
            for (n, d) in desks.enumerated() {
                switch n % 4 {
                case 0: sample[d.name] = DeskStatus(activity: .ready, lastOutput: now.addingTimeInterval(-120), running: true)
                case 1: sample[d.name] = DeskStatus(activity: .working, lastOutput: now, running: true, memory: "946 MB",
                                                    detail: "Tidy the invoice parser")
                case 2: sample[d.name] = DeskStatus(activity: .quiet, lastOutput: now.addingTimeInterval(-3600), running: true,
                                                    memory: "132 MB", news: 2)
                default: sample[d.name] = DeskStatus()
                }
            }
            // `--blocked <desk>`: that desk stopped on a question.
            if let k = CommandLine.arguments.firstIndex(of: "--blocked"), k + 1 < CommandLine.arguments.count {
                sample[CommandLine.arguments[k + 1]] = DeskStatus(activity: .blocked, lastOutput: now.addingTimeInterval(-300), running: true,
                                                                  detail: "wants to use Bash")
            }
            // `--asleep <desk>`: that desk put to sleep (the moon on its row).
            if let k = CommandLine.arguments.firstIndex(of: "--asleep"), k + 1 < CommandLine.arguments.count {
                sample[CommandLine.arguments[k + 1]] = DeskStatus(asleep: true)
            }
            // `--show-hidden`: the rail with its hidden desks listed.
            if CommandLine.arguments.contains("--show-hidden") {
                sidebar.showHidden = true
                sidebar.build(desks: desks)
                sidebar.revealHidden()
            }
            // `--live`: the rail with Keep Active Groups on Top, ordered by
            // the sample activity above.
            if CommandLine.arguments.contains("--live") {
                var waiting: [String: Date] = [:], used: [String: Date] = [:]
                for (n, st) in sample {
                    if case .ready = st.activity, let l = st.lastOutput { waiting[n] = l }
                    if let l = st.lastOutput { used[n] = l }
                }
                sidebar.liveOn = true
                sidebar.groupOrder = DeskOrder.liveGroups(desks, waiting: waiting, used: used)
                sidebar.build(desks: desks)
            }
            // `--pin <desk>`: that desk pinned to the top, for the picture only.
            if let k = CommandLine.arguments.firstIndex(of: "--pin"), k + 1 < CommandLine.arguments.count,
               let i = desks.firstIndex(where: { $0.name == CommandLine.arguments[k + 1] }) {
                desks[i].pinned = true
                sidebar.build(desks: desks)
            }
            sidebar.status = sample
            refreshTabs(sample)
            meter.setCounts(DeskCounts.of(sample.values.filter(\.running).map(\.activity)))
            for (name, s) in sessions { s.setMark(Mark(sample[name] ?? DeskStatus())) }
            // `--offer <runtime>`: the rail offering a desk for that agent.
            // `--budget-demo`: the first desks near and over a made-up budget.
            if CommandLine.arguments.contains("--budget-demo") {
                let names = desks.filter { $0.runtime != "shell" }.map(\.name)
                var b: [String: DeskBudget.Status] = [:]
                if names.count > 0 { b[names[0]] = .over(spent: 62, budget: 50) }
                if names.count > 1 { b[names[1]] = .near(spent: 43, budget: 50) }
                sidebar.budgets = b
            }
            // `--agent-news`: the rail saying an agent updated, with made-up versions.
            if CommandLine.arguments.contains("--agent-news") {
                sidebar.agentNews = [AgentVersions.Change(runtime: "claude", from: "2.1.279", to: "2.1.280")]
            }
            if let k = CommandLine.arguments.firstIndex(of: "--offer"), k + 1 < CommandLine.arguments.count {
                sidebar.offers = [CommandLine.arguments[k + 1]]
            }
            // `--meter-demo`: the usage meter with made-up numbers.
            if CommandLine.arguments.contains("--meter-demo") {
                meter.showDemo(summary: "claude wk 72%→sat 11 am · 5h 18%     codex wk 12%→mon 8 pm     copilot 1.4M",
                               hint: "claude 72% used, codex only 12% — send the next one to codex.")
            }
            // `--toggle-tree`: flip Tree on Top once after launch, the way cmd-T
            // does, without saving the setting.
            if CommandLine.arguments.contains("--toggle-tree") {
                ui.treeOnTop.toggle()
                applyRailOrder()
                window.contentView?.layoutSubtreeIfNeeded()
                fitRail()
            }
            // `--update-available <version>`: the title strip's release link.
            if let k = CommandLine.arguments.firstIndex(of: "--update-available"), k + 1 < CommandLine.arguments.count {
                strip.setUpdate(CommandLine.arguments[k + 1])
            }
            window.setContentSize(NSSize(width: 1180, height: 780))
            window.contentView?.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let v = self?.window.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
                v.cacheDisplay(in: v.bounds, to: rep)
                if let me = self, ProcessInfo.processInfo.environment["COLDFALL_SNAPSHOT_DEBUG"] != nil {
                    let clip = me.deskScroll.contentView
                    let rows = me.sidebar.subviews.compactMap { $0 as? DeskRow }.prefix(2).map { "\($0.frame)" }
                    let lines = [
                        "deskScroll.frame \(me.deskScroll.frame)",
                        "clip.bounds      \(clip.bounds)",
                        "sidebar.frame    \(me.sidebar.frame)",
                        "rows             \(rows)",
                        "tree.frame       \(me.tree.frame)  railOrder=\(me.rail.arrangedSubviews.map { $0 === me.tree ? "tree" : "desks" })",
                        "state            hidden=\(me.deskScroll.isHidden) alpha=\(me.deskScroll.alphaValue) doc=\(me.deskScroll.documentView === me.sidebar) sidebarSuper=\(String(describing: me.sidebar.superview.map { type(of: $0) })) sidebarHidden=\(me.sidebar.isHidden) layer=\(me.deskScroll.wantsLayer) clipLayerBG=\(String(describing: me.deskScroll.contentView.layer?.backgroundColor)) subviews=\(me.sidebar.subviews.count) inWindow=\(me.deskScroll.window != nil)",
                    ]
                    FileHandle.standardError.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
                    // The desk list on its own, to tell a drawing fault in it
                    // from one in how the whole window is captured.
                    let sb = me.sidebar
                    if let srep2 = sb.bitmapImageRepForCachingDisplay(in: sb.bounds) {
                        sb.cacheDisplay(in: sb.bounds, to: srep2)
                        try? srep2.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-sidebar.png"))
                    }
                    // On macOS 26 a scroll view at the top of the window gets a
                    // blurred edge layer that cacheDisplay can't draw, which is why
                    // the desks-on-top picture comes out blank; the list itself draws.
                    let ds = me.deskScroll
                    if let drep = ds.bitmapImageRepForCachingDisplay(in: ds.bounds) {
                        ds.cacheDisplay(in: ds.bounds, to: drep)
                        try? drep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-desks.png"))
                    }
                }
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                }
                if CommandLine.arguments.contains("--prompt-helper") {
                    let helper = PromptHelper()
                    guard let hv = helper.window?.contentView else { exit(1) }
                    hv.wantsLayer = true
                    hv.effectiveAppearance.performAsCurrentDrawingAppearance {
                        hv.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                    }
                    hv.layoutSubtreeIfNeeded()
                    guard let hr = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) else { exit(1) }
                    hv.cacheDisplay(in: hv.bounds, to: hr)
                    do {
                        guard let png = hr.representation(using: .png, properties: [:]) else { exit(1) }
                        try png.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-prompt.png"))
                    } catch { exit(1) }
                    exit(0)
                }
                // `--inventory <desk>`: that desk's "What This Desk Has", to
                // <out>-inventory.png.
                if let k = CommandLine.arguments.firstIndex(of: "--inventory"), k + 1 < CommandLine.arguments.count,
                   let d = self?.desks.first(where: { $0.name == CommandLine.arguments[k + 1] }) {
                    // COLDFALL_DEMO_HOME: read a made-up home folder, for pictures.
                    let home = ProcessInfo.processInfo.environment["COLDFALL_DEMO_HOME"] ?? NSHomeDirectory()
                    let inv = Inventory.of(d, home: home)
                    let iw = InventoryWindow(desk: d, inventory: inv, changes: InventorySeen.load(d.name).map { inv.changes(since: $0) })
                    guard let iv = iw.window?.contentView else { exit(1) }
                    iv.wantsLayer = true
                    iv.effectiveAppearance.performAsCurrentDrawingAppearance {
                        iv.layer?.backgroundColor = Theme.ui.editor.cgColor
                    }
                    iv.layoutSubtreeIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        _ = iw
                        guard let irep = iv.bitmapImageRepForCachingDisplay(in: iv.bounds) else { exit(1) }
                        iv.cacheDisplay(in: iv.bounds, to: irep)
                        if let png = irep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-inventory.png"))
                        }
                        exit(0)
                    }
                    return
                }
                // `--usage`: the usage window, to <out>-usage.png. It scans
                // in the background, so this waits longer than the others.
                if let k = CommandLine.arguments.firstIndex(of: "--usage") {
                    let mw = MeterPanel()
                    // `--usage where` picks a tab; the default is the first.
                    if k + 1 < CommandLine.arguments.count,
                       let t = MeterPanel.Tab.named(CommandLine.arguments[k + 1]) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { mw.show(t) }
                    }
                    guard let mv = mw.content ?? mw.window?.contentView else { exit(1) }
                    mv.wantsLayer = true
                    mv.effectiveAppearance.performAsCurrentDrawingAppearance {
                        mv.layer?.backgroundColor = Theme.ui.editor.cgColor
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        _ = mw
                        mv.layoutSubtreeIfNeeded()
                        // Grow the window to the content's height, then shoot
                        // the whole thing: the tab strip lives outside the
                        // scroll view, so a shot of the content alone loses it.
                        guard let win = mw.window, let rootView = win.contentView else { exit(1) }
                        let h = mv.fittingSize.height + 60
                        win.setContentSize(NSSize(width: win.contentView?.bounds.width ?? 820, height: h))
                        rootView.layoutSubtreeIfNeeded()
                        let shot = rootView
                        guard let mrep = shot.bitmapImageRepForCachingDisplay(in: shot.bounds) else { exit(1) }
                        shot.cacheDisplay(in: shot.bounds, to: mrep)
                        if let png = mrep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-usage.png"))
                        }
                        exit(0)
                    }
                    return
                }
                // `--welcome [none]`: the Welcome screen, to <out>-welcome.png;
                // `none` draws it as a Mac with no vendor CLI would see it.
                if let k = CommandLine.arguments.firstIndex(of: "--welcome") {
                    WelcomeWindow.pretendNothingInstalled =
                        k + 1 < CommandLine.arguments.count && CommandLine.arguments[k + 1] == "none"
                    let ww = WelcomeWindow(projectDir: "/tmp")
                    guard let wv = ww.window?.contentView else { exit(1) }
                    wv.wantsLayer = true
                    wv.effectiveAppearance.performAsCurrentDrawingAppearance {
                        wv.layer?.backgroundColor = Theme.ui.editor.cgColor
                    }
                    wv.layoutSubtreeIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        _ = ww
                        // At 2x: a window that never reaches a screen draws at
                        // 1x, which is blurry on the page it ends up on.
                        guard let wrep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                pixelsWide: Int(wv.bounds.width * 2), pixelsHigh: Int(wv.bounds.height * 2),
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
                        wrep.size = wv.bounds.size
                        wv.cacheDisplay(in: wv.bounds, to: wrep)
                        if let png = wrep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-welcome.png"))
                        }
                        exit(0)
                    }
                    return
                }
                // `--mail <desk> <runtime>`: agent mail from that desk, showing
                // its thread with that runtime, to <out>-mail.png.
                if let k = CommandLine.arguments.firstIndex(of: "--mail"), k + 2 < CommandLine.arguments.count,
                   let me = self, let d = me.desks.first(where: { $0.name == CommandLine.arguments[k + 1] }) {
                    let mp = MailboxPanel(cwd: d.resolvedCwd, from: d.name)
                    mp.showThread(with: CommandLine.arguments[k + 2])
                    guard let mv = mp.window?.contentView else { exit(1) }
                    mv.wantsLayer = true
                    mv.effectiveAppearance.performAsCurrentDrawingAppearance {
                        mv.layer?.backgroundColor = Theme.ui.editor.cgColor
                    }
                    mv.layoutSubtreeIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        _ = mp
                        guard let mrep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                pixelsWide: Int(mv.bounds.width * 2), pixelsHigh: Int(mv.bounds.height * 2),
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
                        mrep.size = mv.bounds.size
                        mv.cacheDisplay(in: mv.bounds, to: mrep)
                        try? mrep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-mail.png"))
                        exit(0)
                    }
                    return
                }
                // `--mcp <desk>`: that desk's MCP Servers chooser, to
                // <out>-mcp.png.
                if let k = CommandLine.arguments.firstIndex(of: "--mcp"), k + 1 < CommandLine.arguments.count,
                   let me = self, let d = me.desks.first(where: { $0.name == CommandLine.arguments[k + 1] }) {
                    let (a, _) = me.mcpAlert(for: d, servers: McpTrim.servers(for: d))
                    a.layout()
                    guard let av = a.window.contentView else { exit(1) }
                    av.wantsLayer = true
                    av.effectiveAppearance.performAsCurrentDrawingAppearance {
                        av.layer?.backgroundColor = Theme.ui.editor.cgColor
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard let arep = av.bitmapImageRepForCachingDisplay(in: av.bounds) else { exit(1) }
                        av.cacheDisplay(in: av.bounds, to: arep)
                        try? arep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-mcp.png"))
                        exit(0)
                    }
                    return
                }
                // `--settings <tab>`: the Settings window on that tab, to
                // <out>-settings.png. Never saved, never shown.
                // `--peek` (with `--terminal <file>`): that desk peeked at,
                // to shot-peek.png.
                if CommandLine.arguments.contains("--peek"), let me = self, me.desks.indices.contains(i),
                   let s = me.sessions[me.desks[i].name] {
                    me.peek.open(over: me.window, desk: me.desks[i].name, session: s)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        guard let pv = me.peek.contentView,
                              let prep = pv.bitmapImageRepForCachingDisplay(in: pv.bounds) else { exit(1) }
                        pv.cacheDisplay(in: pv.bounds, to: prep)
                        if let png = prep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-peek.png"))
                        }
                        exit(0)
                    }
                    return
                }
                // `--schedules`: the Schedules window with made-up ones, to
                // shot-schedules.png.
                if CommandLine.arguments.contains("--schedules"), let me = self {
                    let now = Date().timeIntervalSince1970
                    me.schedules.show([
                        Schedule(name: "Morning plan", desk: "home", prompt: "Plan today from the notes in this folder.", at: "09:00",
                                 days: ["mon", "tue", "wed", "thu", "fri"], skipOverWeekPct: 80),
                        Schedule(name: "Review new commits", desk: "review", prompt: "Review what changed on main since yesterday and list anything risky.",
                                 at: "17:30", precheck: "git log --since=yesterday --oneline | grep -q ."),
                        Schedule(name: "Weekly tidy", desk: "docs", prompt: "Check the help pages against the changelog.", at: "10:00", days: ["mon"], enabled: false),
                    ], runs: [Schedule.Run(name: "Morning plan", at: now - 20_000, outcome: .sent),
                              Schedule.Run(name: "Review new commits", at: now - 70_000, outcome: .skippedPrecheck)],
                    desks: me.desks.map(\.name), size: NSSize(width: 700, height: 470))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard let pv = me.schedules.contentView,
                              let prep = pv.bitmapImageRepForCachingDisplay(in: pv.bounds) else { exit(1) }
                        pv.cacheDisplay(in: pv.bounds, to: prep)
                        if let png = prep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-schedules.png"))
                        }
                        exit(0)
                    }
                    return
                }
                // `--conversations`: the Conversations window with made-up ones,
                // to shot-conversations.png.
                if CommandLine.arguments.contains("--conversations"), let me = self, me.desks.indices.contains(i) {
                    let d = me.desks[i]
                    let t = Date()
                    func c(_ v: String, _ id: String, _ ago: Double, _ kb: Int, _ title: String?, _ p: String) -> Transcripts.Conversation {
                        Transcripts.Conversation(vendor: v, id: id, path: "", folder: "/srv/demo/acme-app",
                                                 modified: t.addingTimeInterval(-ago), bytes: kb * 1024, title: title, firstPrompt: p)
                    }
                    me.transcripts.show(desk: d.name, folder: "/srv/demo/acme-app", [
                        c("claude", "aaaa-1111", 1800, 2300, d.name, "Move the cart totals into their own file"),
                        c("codex", "cccc-3333", 9000, 410, nil, "Review the cart change and say what you'd test"),
                        c("claude", "bbbb-2222", 90000, 5200, nil, "Write the release notes for the spring release"),
                        c("claude", "dddd-4444", 400000, 880, "checkout", "Why does the receipt round per item?"),
                    ], size: NSSize(width: 720, height: 430))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard let pv = me.transcripts.contentView,
                              let prep = pv.bitmapImageRepForCachingDisplay(in: pv.bounds) else { exit(1) }
                        pv.cacheDisplay(in: pv.bounds, to: prep)
                        if let png = prep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-conversations.png"))
                        }
                        exit(0)
                    }
                    return
                }
                // `--changes`: the Changes window with a made-up diff and one
                // comment waiting, to shot-changes.png.
                if CommandLine.arguments.contains("--changes"), let me = self, me.desks.indices.contains(i) {
                    let d = me.desks[i]
                    let files = [Changes.File(path: "Sources/Parser/Invoice.swift", status: "M"),
                                 Changes.File(path: "Sources/Parser/Totals.swift", status: "M"),
                                 Changes.File(path: "Tests/InvoiceTests.swift", status: "A"),
                                 Changes.File(path: "notes/todo.txt", status: "?")]
                    let lines = Changes.parseDiff("""
                    diff --git a/Sources/Parser/Invoice.swift b/Sources/Parser/Invoice.swift
                    --- a/Sources/Parser/Invoice.swift
                    +++ b/Sources/Parser/Invoice.swift
                    @@ -41,7 +41,9 @@ func parse(_ text: String) -> Invoice? {
                         let rows = text.split(separator: ",")
                    -    guard rows.count > 1 else { return nil }
                    +    guard rows.count > 1 else {
                    +        return Invoice.empty
                    +    }
                         let header = rows[0]
                    -    let total = Double(rows.last!)
                    +    let total = Decimal(string: String(rows.last ?? ""))
                         return Invoice(header: String(header), total: total)
                     }
                    """)
                    me.changes.show(desk: d.name, folder: "/srv/demo/work", files: files, lines: lines,
                                    comments: [Changes.Comment(file: "Sources/Parser/Invoice.swift", line: 45, quote: "return Invoice.empty",
                                                               text: "An empty file should still be nil.")],
                                    size: NSSize(width: 940, height: 520),
                                    pr: PullRequest.parse(#"{"number":12,"title":"Cart totals","state":"OPEN","isDraft":false,"url":"https://example.com","reviewDecision":"","statusCheckRollup":[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"test","status":"COMPLETED","conclusion":"FAILURE"}]}"#))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard let pv = me.changes.contentView,
                              let prep = pv.bitmapImageRepForCachingDisplay(in: pv.bounds) else { exit(1) }
                        pv.cacheDisplay(in: pv.bounds, to: prep)
                        if let png = prep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-changes.png"))
                        }
                        exit(0)
                    }
                    return
                }
                // `--feed` (with `--terminal <file>`): Needs You showing that
                // desk's question as read from the file, to shot-feed.png.
                if CommandLine.arguments.contains("--feed"), let me = self, me.desks.indices.contains(i),
                   let s = me.sessions[me.desks[i].name] {
                    let d = me.desks[i]
                    let screen = s.screenText(lines: 60)
                    var list = [FeedPanel.Item(desk: d.name, runtime: d.runtime, icon: d.icon, reason: "wants to use Bash",
                                               prompt: Prompt.parse(screen: screen),
                                               tail: screen.split(separator: "\n", omittingEmptySubsequences: true).suffix(10).joined(separator: "\n"))]
                    if let o = me.desks.first(where: { $0.name != d.name && $0.runtime != "shell" }) {
                        list.append(FeedPanel.Item(desk: o.name, runtime: o.runtime, icon: o.icon, reason: "asked a question",
                                                   prompt: nil, tail: "Which of these should I keep?\n  the old parser, or the new one"))
                    }
                    me.feed.show(list, size: NSSize(width: 620, height: 500))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard let pv = me.feed.contentView,
                              let prep = pv.bitmapImageRepForCachingDisplay(in: pv.bounds) else { exit(1) }
                        pv.cacheDisplay(in: pv.bounds, to: prep)
                        if let png = prep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-feed.png"))
                        }
                        exit(0)
                    }
                    return
                }
                // `--quit-prompt a,b`: the question quitting asks with those
                // desks held, to shot-quit.png. An alert can't be caught in a
                // window snapshot, so its own window is drawn.
                if let k = CommandLine.arguments.firstIndex(of: "--quit-prompt"), k + 1 < CommandLine.arguments.count,
                   let me = self {
                    let alert = me.quitAlert(CommandLine.arguments[k + 1].split(separator: ",").map(String.init))
                    alert.layout()
                    guard let av = alert.window.contentView else { exit(1) }
                    av.wantsLayer = true
                    av.effectiveAppearance.performAsCurrentDrawingAppearance {
                        av.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                    }
                    av.layoutSubtreeIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        _ = alert
                        guard let qrep = av.bitmapImageRepForCachingDisplay(in: av.bounds) else { exit(1) }
                        av.cacheDisplay(in: av.bounds, to: qrep)
                        if let png = qrep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-quit.png"))
                        }
                        exit(0)
                    }
                    return
                }
                if let k = CommandLine.arguments.firstIndex(of: "--settings"), k + 1 < CommandLine.arguments.count {
                    let sw = SettingsWindow(projectDir: NSHomeDirectory())
                    // An unknown tab name threw inside AppKit and crashed the
                    // snapshot; look it up first and stay on the first tab.
                    let want = CommandLine.arguments[k + 1]
                    if let item = sw.tabs?.tabViewItems.first(where: { ($0.identifier as? String) == want }) {
                        sw.tabs?.selectTabViewItem(item)
                    }
                    guard let sv = sw.window?.contentView else { exit(1) }
                    // Offscreen, nothing draws the window's own background,
                    // and light label text vanishes on the blank white.
                    sv.wantsLayer = true
                    sv.effectiveAppearance.performAsCurrentDrawingAppearance {
                        sv.layer?.backgroundColor = Theme.ui.editor.cgColor
                    }
                    sv.layoutSubtreeIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        _ = sw          // keep the window alive until it is drawn
                        guard let srep = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) else { exit(1) }
                        sv.cacheDisplay(in: sv.bounds, to: srep)
                        if let png = srep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-settings.png"))
                        }
                        exit(0)
                    }
                    return
                }
                guard let q = paletteQuery, let me = self else { exit(0) }
                let root = me.desks.indices.contains(i) ? me.desks[i].resolvedCwd : NSHomeDirectory()
                // Commands are read from the menus, which a snapshot doesn't
                // otherwise install.
                if Commands.commandQuery(q) != nil { me.installMenu() }
                me.palette.open(over: me.window, desks: me.desks, root: root, query: q)
                // Give the background file index a moment to land.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    me.palette.setQueryForSnapshot(q)
                    guard let pv = me.palette.contentView,
                          let prep = pv.bitmapImageRepForCachingDisplay(in: pv.bounds) else { exit(0) }
                    pv.cacheDisplay(in: pv.bounds, to: prep)
                    if let png = prep.representation(using: .png, properties: [:]) {
                        let pout = (out as NSString).deletingPathExtension + "-palette.png"
                        try? png.write(to: URL(fileURLWithPath: pout))
                    }
                    exit(0)
                }
            }
            return
        }

        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installMenu()
        watchPaneClicks()
        // `--split` outside a snapshot: a shell split in the startup desk
        // once it is up. For trying a split without a click.
        if !CommandLine.arguments.contains("--snapshot"), CommandLine.arguments.contains("--split") {
            var tries = 0
            Timer.inEveryMode(withTimeInterval: 1, repeats: true) { [weak self] t in
                tries += 1
                guard let self, tries < 30 else { t.invalidate(); return }
                guard self.visible?.started == true else { return }
                t.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.splitRight() }
            }
        }
        // `--beside <desk>` outside a snapshot: open that desk next to the
        // startup one once it is up. For trying two desks without a click.
        if !CommandLine.arguments.contains("--snapshot"),
           let b = CommandLine.arguments.firstIndex(of: "--beside"), b + 1 < CommandLine.arguments.count {
            let names = CommandLine.arguments[b + 1].split(separator: ",").map(String.init)
            // Once a desk is on screen to be beside (the launch screen waits
            // on Start first); given up on after half a minute.
            var tries = 0
            Timer.inEveryMode(withTimeInterval: 1, repeats: true) { [weak self] t in
                tries += 1
                guard let self, tries < 30 else { t.invalidate(); return }
                // The launch screen waits on Start: press it.
                guard self.visible?.started == true else { if tries == 2 { self.startWaiting() }; return }
                t.invalidate()
                for name in names { if let i = self.deskIndex(name) { self.openBeside(i) } }
            }
        }
        // `--grid-selftest a,b,c`: once a desk is up, put those beside it and
        // walk the grid (go to one, replace one, change places, take one
        // off), printing what is on screen after each step. For a throwaway
        // home; it quits when done.
        if !CommandLine.arguments.contains("--snapshot"),
           let g = CommandLine.arguments.firstIndex(of: "--grid-selftest"), g + 1 < CommandLine.arguments.count {
            let names = CommandLine.arguments[g + 1].split(separator: ",").map(String.init)
            var tries = 0
            Timer.inEveryMode(withTimeInterval: 1, repeats: true) { [weak self] t in
                tries += 1
                guard let self, tries < 30 else { t.invalidate(); return }
                // The launch screen waits on Start: press it.
                guard self.visible?.started == true else { if tries == 2 { self.startWaiting() }; return }
                t.invalidate()
                self.gridSelfTest(names)
            }
        }
        watchSystemAppearance()
        watchDeskActivity()
        notifier.onOpen = { [weak self] d in
            guard let self, let i = self.deskIndex(d) else { return }
            self.show(i)
        }
        notifier.start()
        applyInbox()
        watchDeskMemory()
        watchLiveRail()
        watchDeskConfig()
        watchNewAgents()
        // The update sheet names what a relaunch is about to end. Only the
        // controller knows which desks have live processes.
        SelfUpdate.runningDesks = { [weak self] in
            // A held desk carries on through the relaunch, so it isn't named.
            (self?.sessions.filter { $0.value.started && !$0.value.isHeld }.map(\.key)) ?? []
        }
        // Desks still running in their holders from last time come straight
        // back; the ones that went with a restart of the Mac are offered.
        DeskSession.keepGlobal = ui.keepDesksRunning
        if !CommandLine.arguments.contains("--snapshot") { ExitLog.install() }
        // COLDFALL_TERMINAL overrides the setting for one run, for trying it.
        Pane.wantsGhostty = (ProcessInfo.processInfo.environment["COLDFALL_TERMINAL"] ?? ui.terminal) == "ghostty"
            && !CommandLine.arguments.contains("--snapshot")
        if !args.contains("--snapshot") {
            let heldNow = Set(Holder.held())
            for d in desks where heldNow.contains(d.name) { openRemotely(d.name, show: false) }
            restoreOffer = RestoreOffer.desks(wasRunning: ui.runningDesks, names: desks.map(\.name),
                                              hidden: Set(desks.filter(\.hidden).map(\.name)), runningNow: heldNow)
        }
        // The desk you were on, shown but not started: nothing runs until you
        // ask, so opening the app costs no memory and asks no questions.
        showWaiting(DeskConfig.startup(in: desks, last: ui.lastDesk))
        if firstRun { showWelcome() }
        // A snapshot never talks to the network.
        if !CommandLine.arguments.contains("--snapshot") {
            updates.onChange = { [weak self] v in self?.strip.setUpdate(v) }
            updates.start(firstRun: firstRun)
        }
    }

    /// Swap which desk is on screen. The others keep running.
    func show(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        let d = desks[i]
        // A desk is on screen once: choosing one that is there, in another
        // place, moves the keys to it. Any other takes the place of the desk
        // that has the keys.
        if case .focus(let k) = DeskGrid.place(d.name, onScreen: slots.map { $0.session?.desk.name ?? "" }, key: keySlot),
           k != keySlot {
            focusSlot(k)
            return
        }
        lastVisited[d.name] = Date()
        if !steppingHistory { history.visit(d.name) }
        if ui.sleeping.contains(d.name) { ui.sleeping.removeAll { $0 == d.name }; ui.save() }
        notifier.clear(desk: d.name)
        waitingName = nil
        if ui.lastDesk != d.name { ui.lastDesk = d.name; ui.save() }
        let s = sessions[d.name] ?? {
            let new = DeskSession(desk: d)
            new.processDelegate = self
            sessions[d.name] = new
            return new
        }()

        visible?.container.removeFromSuperview()
        stoppedNote?.removeFromSuperview(); stoppedNote = nil
        s.container.delegate = self
        // A desk opened from the CLI or the phone was sized by frame while
        // it was off screen; on screen it follows its slot, or it keeps
        // that size when the window or its neighbour changes.
        s.container.translatesAutoresizingMaskIntoConstraints = false
        if let old = visible, old !== s { old.setPair(false, key: true) }
        mount(s, in: slots[keySlot])
        if !s.started { checkInventory(d) }
        startOrAsk(s, d)
        if visible !== s { visible?.isVisible = false }
        s.isVisible = true
        visible = s
        syncPairFocus()
        meter.currentDesk = d.name
        // Follow the desk that is on screen.
        watcher.start(root: d.resolvedCwd)
        tree.setRoot(d.resolvedCwd)
        sidebar.select(i)
        window.title = "Project Coldfall — \(d.name)"
        strip.setContext(d.name)
        updateTermHeader()
        window.makeFirstResponder(s.focusedPane.terminal.view)
    }

    /// Start a desk, first asking about a big conversation that has sat long
    /// enough for its cache to lapse. Resume is the default and the answer
    /// for everything else: this only ever adds a choice.
    func startOrAsk(_ s: DeskSession, _ d: Desk) {
        guard !s.started, !s.holding, !s.resolving else { return }
        let wrappedAt = ui.wrappedUp[d.name].map { Date(timeIntervalSince1970: $0) }
        // A wrap-up is answered by this start, whichever way it goes.
        if wrappedAt != nil { ui.wrappedUp[d.name] = nil; ui.save() }
        // Only where Coldfall can actually start it fresh, only if asking is
        // on, and never in a snapshot, which must not block on a dialog.
        guard d.runtime == "claude", d.freshCommand() != nil, ui.offerFreshStart, !d.alwaysResume,
              !CommandLine.arguments.contains("--snapshot") else { s.startIfNeeded(); return }
        s.holding = true
        DispatchQueue.global(qos: .userInitiated).async {
            let convo = Reopen.claude(d)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                s.holding = false
                // Ended or replaced while we were looking: nothing to start.
                guard self.sessions[d.name] === s else { return }
                guard Reopen.shouldAsk(desk: d, convo, wrapped: wrappedAt != nil,
                                       enabled: self.ui.offerFreshStart) else { s.startIfNeeded(); return }
                let q = Reopen.question(desk: d, convo, wrappedAt: wrappedAt)
                let a = NSAlert()
                a.messageText = q.title
                a.informativeText = q.body
                // Return presses the first button: picking up where you left
                // off, unless the desk was wrapped up for a clean start.
                let resumeTitle = "Pick Up Where I Left Off", freshTitle = "Start Fresh"
                if q.freshIsDefault {
                    a.addButton(withTitle: freshTitle); a.addButton(withTitle: resumeTitle)
                } else {
                    a.addButton(withTitle: resumeTitle); a.addButton(withTitle: freshTitle)
                }
                a.showsSuppressionButton = true
                a.suppressionButton?.title = "Don't ask for \(d.name); always pick up where I left off"
                let r = a.runModal()
                if a.suppressionButton?.state == .on,
                   let i = self.desks.firstIndex(where: { $0.name == d.name }) {
                    self.desks[i].alwaysResume = true
                    self.persist()
                }
                let fresh = q.freshIsDefault ? r == .alertFirstButtonReturn : r == .alertSecondButtonReturn
                guard fresh, let cmd = d.freshCommand() else {
                    s.startIfNeeded(); return
                }
                // A conversation pinned by id would bring the old one back
                // on the next start; a fresh start means the new one.
                if let i = self.desks.firstIndex(where: { $0.name == d.name }), self.desks[i].session != nil {
                    self.desks[i].session = nil
                    self.persist()
                    s.desk = self.desks[i]
                }
                s.startFresh(cmd)
            }
        }
    }

    /// cmd-1..9 jumps between desks.
    func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        let upd = NSMenuItem(title: "Update Project Coldfall…", action: #selector(openUpdate), keyEquivalent: "u")
        upd.keyEquivalentModifierMask = [.command, .shift, .option]
        upd.target = self
        appMenu.addItem(upd)
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        let welcome = NSMenuItem(title: "Show Welcome", action: #selector(showWelcome), keyEquivalent: "")
        welcome.target = self
        appMenu.addItem(welcome)
        let news = NSMenuItem(title: "What's New", action: #selector(openChangelog), keyEquivalent: "")
        news.target = self
        appMenu.addItem(news)
        appMenu.addItem(.separator())
        // Removing Coldfall's files lives in Settings, General: it sat right
        // above Quit here, one slip of the pointer from it.
        appMenu.addItem(withTitle: "Quit Project Coldfall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Without this menu, cmd-c/v/x/a are bound to nothing and no text field
        // in the app can be pasted into. AppKit does not supply it: the standard
        // editing actions travel the responder chain from MENU ITEMS, so an app
        // with no Edit menu has no clipboard at all.
        //
        // Every item targets nil so it goes to whoever is first responder — a
        // text view handles it itself, and anything else falls through to this
        // controller.
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        func edit(_ title: String, _ sel: Selector, _ key: String,
                  _ mods: NSEvent.ModifierFlags = [.command]) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = nil                      // responder chain, not this object
            editMenu.addItem(it)
        }
        // `undo:` is declared here (below) so #selector resolves it; `redo:` is
        // implemented only by NSTextView, so it has to be named as a string.
        edit("Undo", #selector(undo(_:)), "z")
        edit("Redo", NSSelectorFromString("redo:"), "z", [.command, .shift])
        editMenu.addItem(.separator())
        edit("Cut", #selector(NSText.cut(_:)), "x")
        edit("Copy", #selector(NSText.copy(_:)), "c")
        edit("Paste", #selector(NSText.paste(_:)), "v")
        edit("Select All", #selector(NSText.selectAll(_:)), "a")
        editMenu.addItem(.separator())
        let promptItem = NSMenuItem(title: "Write a Prompt…", action: #selector(openPromptHelper), keyEquivalent: "")
        promptItem.target = self
        editMenu.addItem(promptItem)
        editItem.submenu = editMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        func add(_ m: NSMenu, _ t: String, _ sel: Selector, _ k: String, _ mods: NSEvent.ModifierFlags = [.command]) {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: k)
            it.keyEquivalentModifierMask = mods
            it.target = self
            m.addItem(it)
        }
        add(viewMenu, "Go to Desk or File…", #selector(openPalette), "p")
        add(viewMenu, "Run a Command…", #selector(openCommands), "p", [.command, .shift])
        viewMenu.addItem(.separator())
        add(viewMenu, "Show or Hide Rail", #selector(toggleRail), "b")
        add(viewMenu, "Show or Hide Reader", #selector(toggleReader), "b", [.command, .option])
        add(viewMenu, "Show or Hide Usage Meter", #selector(toggleMeter), "j")
        viewMenu.addItem(.separator())
        add(viewMenu, "Pop Out or Dock Reader", #selector(popOutOrDock), "")
        viewItem.submenu = viewMenu

        let deskItem = NSMenuItem(); main.addItem(deskItem)
        let deskMenu = NSMenu(title: "Desks")
        for (n, i) in DeskOrder.shortcuts(desks).enumerated() {
            let it = NSMenuItem(title: desks[i].name, action: #selector(jump(_:)), keyEquivalent: "\(n + 1)")
            it.tag = i; it.target = self
            deskMenu.addItem(it)
        }
        let waitingItem = NSMenuItem(title: "Go to Desk That Needs You", action: #selector(jumpToWaiting), keyEquivalent: "0")
        waitingItem.target = self
        deskMenu.addItem(waitingItem)
        let dfItem = NSMenuItem(title: "Not This One Yet", action: #selector(deferDesk), keyEquivalent: "u")
        dfItem.keyEquivalentModifierMask = [.command, .control]
        dfItem.target = self
        dfItem.toolTip = "Puts this desk at the back of the waiting queue, still marked, and goes to the next."
        deskMenu.addItem(dfItem)
        let bk = NSMenuItem(title: "Back", action: #selector(goBack), keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        bk.keyEquivalentModifierMask = [.command, .control]
        bk.target = self
        deskMenu.addItem(bk)
        let fw = NSMenuItem(title: "Forward", action: #selector(goForward), keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        fw.keyEquivalentModifierMask = [.command, .control]
        fw.target = self
        deskMenu.addItem(fw)
        let ro = NSMenuItem(title: "Reopen Stopped Desk", action: #selector(reopenStopped), keyEquivalent: "t")
        ro.keyEquivalentModifierMask = [.command, .shift]
        ro.target = self
        deskMenu.addItem(ro)
        let sch = NSMenuItem(title: "Schedules…", action: #selector(openSchedules), keyEquivalent: "")
        sch.target = self
        deskMenu.addItem(sch)
        let cv = NSMenuItem(title: "Conversations…", action: #selector(openConversations), keyEquivalent: "h")
        cv.keyEquivalentModifierMask = [.command, .shift]
        cv.target = self
        deskMenu.addItem(cv)
        let fk = NSMenuItem(title: "Fork Conversation in a Split", action: #selector(forkConversation), keyEquivalent: "")
        fk.target = self
        fk.toolTip = "The vendor's own fork (Claude Code, Codex) in a shell beside this desk. The original carries on."
        deskMenu.addItem(fk)
        let ho = NSMenuItem(title: "Hand Off to Another Desk…", action: #selector(handOff), keyEquivalent: "")
        ho.target = self
        ho.toolTip = "Sends the end of this desk's screen to another running desk as history. Asks first."
        deskMenu.addItem(ho)
        let chItem = NSMenuItem(title: "Changes…", action: #selector(openChanges), keyEquivalent: "g")
        chItem.keyEquivalentModifierMask = [.command, .shift]
        chItem.target = self
        deskMenu.addItem(chItem)
        let feedItem = NSMenuItem(title: "Needs You…", action: #selector(openFeed), keyEquivalent: "0")
        feedItem.keyEquivalentModifierMask = [.command, .option]
        feedItem.target = self
        deskMenu.addItem(feedItem)
        let shellItem = NSMenuItem(title: "New Shell Desk", action: #selector(newShellDesk), keyEquivalent: "n")
        shellItem.target = self
        deskMenu.addItem(shellItem)
        deskMenu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh Files", action: #selector(refreshTree), keyEquivalent: "r")
        refresh.target = self
        deskMenu.addItem(refresh)
        // No key equivalent: cmd-z lives in the Edit menu and reaches undoMove()
        // through the responder chain below. Two menu items sharing cmd-z would
        // leave which one fires up to AppKit.
        let live = NSMenuItem(title: "Keep Active Groups on Top", action: #selector(toggleLiveRail), keyEquivalent: "")
        live.target = self
        live.state = ui.liveRail ? .on : .off
        deskMenu.addItem(live)

        let pri = NSMenuItem(title: "Desks by Priority", action: #selector(toggleDeskPriority), keyEquivalent: "")
        pri.target = self
        pri.state = ui.desksByPriority ? .on : .off
        deskMenu.addItem(pri)
        let nd = NSMenuItem(title: "Next Desk", action: #selector(nextDesk), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        nd.keyEquivalentModifierMask = [.command, .option]
        nd.target = self
        deskMenu.addItem(nd)
        let pd = NSMenuItem(title: "Previous Desk", action: #selector(prevDesk), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        pd.keyEquivalentModifierMask = [.command, .option]
        pd.target = self
        deskMenu.addItem(pd)

        let sortAZ = NSMenuItem(title: "Sort Desks A to Z", action: #selector(sortDesks), keyEquivalent: "")
        sortAZ.target = self
        deskMenu.addItem(sortAZ)
        let undo = NSMenuItem(title: "Undo Move", action: #selector(undoMove), keyEquivalent: "")
        undo.target = self
        deskMenu.addItem(undo)
        let flip = NSMenuItem(title: "Tree on Top", action: #selector(toggleTreePosition), keyEquivalent: "t")
        flip.target = self
        deskMenu.addItem(flip)
        deskMenu.addItem(.separator())

        // Splits. cmd-d reads as "divide" in every terminal that has them.
        let sr = NSMenuItem(title: "Split Right", action: #selector(splitRight), keyEquivalent: "d")
        sr.target = self
        deskMenu.addItem(sr)
        let sd = NSMenuItem(title: "Split Down", action: #selector(splitDown), keyEquivalent: "d")
        sd.keyEquivalentModifierMask = [.command, .shift]
        sd.target = self
        deskMenu.addItem(sd)
        let cp = NSMenuItem(title: "Close Pane", action: #selector(closePane), keyEquivalent: "w")
        cp.target = self
        deskMenu.addItem(cp)
        let zp = NSMenuItem(title: "Zoom Pane", action: #selector(zoomPane), keyEquivalent: "\r")
        zp.keyEquivalentModifierMask = [.command, .shift]
        zp.target = self
        deskMenu.addItem(zp)
        // Every desk, whatever group the list is on: the list only shows one
        // group, and clicking another group moves the desk on screen.
        // A new menu each time the menu bar is built: the bar is rebuilt
        // when desks.toml or keys.json changes, and a menu that is already
        // one item's submenu cannot be given to another (AppKit raises).
        let ob = NSMenuItem(title: "Open Beside", action: nil, keyEquivalent: "")
        besideMenu = NSMenu(title: "Open Beside")
        besideMenu.delegate = self
        ob.submenu = besideMenu
        deskMenu.addItem(ob)
        let cb = NSMenuItem(title: "Take Desk Off Screen", action: #selector(closeBeside), keyEquivalent: "w")
        cb.keyEquivalentModifierMask = [.command, .option]
        cb.target = self
        deskMenu.addItem(cb)
        let nx = NSMenuItem(title: "Next Pane", action: #selector(nextPane), keyEquivalent: "]")
        nx.target = self
        deskMenu.addItem(nx)
        let pv = NSMenuItem(title: "Previous Pane", action: #selector(prevPane), keyEquivalent: "[")
        pv.target = self
        deskMenu.addItem(pv)

        deskMenu.addItem(.separator())
        let agentsItem = NSMenuItem(title: "Agents…", action: #selector(openAgents), keyEquivalent: "a")
        agentsItem.keyEquivalentModifierMask = [.command, .shift]
        agentsItem.target = self
        deskMenu.addItem(agentsItem)
        let usage = NSMenuItem(title: "Usage…", action: #selector(openMeter), keyEquivalent: "u")
        usage.keyEquivalentModifierMask = [.command, .shift]
        usage.target = self
        deskMenu.addItem(usage)
        let mail = NSMenuItem(title: "Agent Mail…", action: #selector(openMailbox), keyEquivalent: "m")
        mail.keyEquivalentModifierMask = [.command, .shift]
        mail.target = self
        deskMenu.addItem(mail)
        deskItem.submenu = deskMenu
        applyKeyMap(to: main)
        NSApp.mainMenu = main
    }

    /// Your shortcuts from keys.json over the built-in ones (see KeyMap).
    /// Problems in the file are kept for Settings to show.
    var keyMapProblems: [String] = []
    var keyMapStamp: Date?
    func applyKeyMap(to main: NSMenu) {
        keyMapStamp = (try? FileManager.default.attributesOfItem(atPath: KeyMap.path))?[.modificationDate] as? Date
        guard let map = KeyMap.load() else { keyMapProblems = []; return }
        keyMapProblems = map.problems
        guard !map.shortcuts.isEmpty else { return }
        var leaves: [NSMenuItem] = []
        func walk(_ m: NSMenu) {
            for it in m.items { if let s = it.submenu { walk(s) } else if !it.isSeparatorItem { leaves.append(it) } }
        }
        walk(main)
        func current(_ it: NSMenuItem) -> KeyMap.Shortcut? {
            guard !it.keyEquivalent.isEmpty else { return nil }
            var mods = it.keyEquivalentModifierMask.rawValue
            let k = it.keyEquivalent
            if k.count == 1, k.uppercased() == k, k.lowercased() != k { mods |= Commands.Mods.shift }
            return KeyMap.Shortcut(key: k.lowercased(), modifiers: mods & (Commands.Mods.command | Commands.Mods.shift | Commands.Mods.option | Commands.Mods.control))
        }
        let given = Set(map.shortcuts.values.filter { $0 != .none })
        for it in leaves {
            if let sc = map.shortcuts[KeyMap.normal(it.title)] {
                it.keyEquivalent = sc.key
                it.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: sc.modifiers)
            } else if let c = current(it), given.contains(c) {
                // Its key now belongs to the command you gave it to.
                it.keyEquivalent = ""
            }
        }
        let known = Set(leaves.map { KeyMap.normal($0.title) })
        for name in map.shortcuts.keys where !known.contains(name) {
            keyMapProblems.append("No command called \u{201C}\(name)\u{201D}. ⌘⇧P lists them all.")
        }
    }

    /// Back in front: if keys.json changed meanwhile, apply it.
    func applicationDidBecomeActive(_ n: Notification) {
        // Back in front of it: the desk on screen is seen again.
        for s in onScreen { s.isVisible = true }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: KeyMap.path))?[.modificationDate] as? Date
        if stamp != keyMapStamp { installMenu() }
    }

    /// Coldfall behind another app: the desk on screen isn't being looked
    /// at, so an answer that lands now is still news when you come back.
    func applicationDidResignActive(_ n: Notification) {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        for s in onScreen { s.isVisible = false }
    }

    @objc func jump(_ sender: NSMenuItem) { open(sender.tag) }

    /// cmd-0: the desk that has waited longest for you.
    @objc func jumpToWaiting() {
        guard let name = NeedsYou.next(in: sidebar.waiting, current: visible?.desk.name) else { NSSound.beep(); return }
        showDesk(named: name)
    }
    /// "Not this one yet": the desk on screen goes to the back of the
    /// waiting queue, still marked, and you go to the next one.
    @objc func deferDesk() {
        guard let s = visible else { NSSound.beep(); return }
        let name = s.desk.name
        sidebar.deferred[name] = Date()
        // Keep it in the queue: looking at it would otherwise have read it.
        if !s.isBlocked { s.markUnread() }
        let rest = sidebar.waiting.filter { $0 != name }
        guard let next = rest.first(where: { sidebar.deferred[$0] == nil }) ?? rest.first else { NSSound.beep(); return }
        showDesk(named: next)
    }

    // MARK: - schedules

    let schedules = SchedulesPanel()
    /// The due time each schedule was last dealt with, from the run log.
    lazy var scheduleHandled: [String: Date] = {
        var m: [String: Date] = [:]
        for r in Schedule.runs() { m[r.name] = max(m[r.name] ?? .distantPast, Date(timeIntervalSince1970: r.at)) }
        return m
    }()
    let schedulesSince = Date()

    @objc func openSchedules() {
        if schedules.isOpen { schedules.close(); return }
        schedules.deskNames = { [weak self] in self?.desks.map(\.name) ?? [] }
        schedules.onRunNow = { [weak self] sc in self?.perform(sc, due: Date()) }
        schedules.open(over: window)
    }

    /// Every half minute: run what is due, note what was missed.
    func runSchedules() {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        let now = Date(), names = desks.map(\.name)
        for sc in Schedule.load() where sc.problem(desks: names) == nil {
            switch sc.due(now: now, handled: scheduleHandled[sc.name], since: schedulesSince) {
            case .no: break
            case .missed(let at):
                scheduleHandled[sc.name] = at
                Schedule.record(Schedule.Run(name: sc.name, at: at.timeIntervalSince1970, outcome: .missed))
            case .run(let at):
                // Marked first, so a slow precheck can't run it twice.
                scheduleHandled[sc.name] = at
                perform(sc, due: at)
            }
        }
    }

    /// One run: the precheck, your quota line, then the send every send goes through.
    func perform(_ sc: Schedule, due: Date) {
        guard let d = desks.first(where: { $0.name == sc.desk }) else { return }
        let folder = d.resolvedCwd
        DispatchQueue.global(qos: .utility).async {
            let ok = Schedule.precheckPasses(sc.precheck, folder: folder)
            let limits = Limits.all()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                func done(_ o: Schedule.Outcome, _ note: String? = nil) {
                    Schedule.record(Schedule.Run(name: sc.name, at: due.timeIntervalSince1970, outcome: o, note: note))
                    if self.schedules.isOpen { self.schedules.reload() }
                }
                guard ok else { return done(.skippedPrecheck) }
                if let line = sc.skipOverWeekPct,
                   let used = limits.first(where: { $0.vendor == d.vendorLabel || $0.vendor == d.runtime })?.liveWeekPct, used >= line {
                    return done(.skippedQuota, "\(d.vendorLabel) is at \(Int(used))% of its week")
                }
                let a = self.inboxSend(sc.desk, text: sc.prompt)
                switch a.outcome {
                case .sent: done(.sent)
                case .notRunning, .blocked, .draft, .hiddenDesk: done(.skippedBusy, a.message)
                default: done(.failed, a.message)
                }
            }
        }
    }

    // MARK: - conversations

    let transcripts = TranscriptsPanel()
    /// Every conversation in this desk's folder, to search and resume.
    @objc func openConversations() {
        if transcripts.isOpen { transcripts.close(); return }
        guard let name = waitingName ?? activeSession?.desk.name, let d = desks.first(where: { $0.name == name }) else { NSSound.beep(); return }
        transcripts.onOpen = { [weak self] cmd in
            // Beside the desk, in a shell: the desk's own agent carries on.
            guard let self, let i = self.deskIndex(d.name) else { return }
            if self.sessions[d.name]?.started != true { self.show(i) }
            guard let s = self.sessions[d.name] else { return }
            if !s.splitRunning(cmd) { NSSound.beep(); return }
            self.updateTermHeader()
            self.window.makeFirstResponder(s.focusedPane.terminal.view)
        }
        transcripts.open(over: window, desk: d.name, folder: d.resolvedCwd)
    }

    // MARK: - fork, and hand off

    /// The desk's conversation, forked by its vendor's own command in a
    /// shell split beside it. The original carries on untouched.
    @objc func forkConversation() {
        guard let s = activeSession, s.started, !s.agentGone else { NSSound.beep(); return }
        let d = s.desk
        let folder = d.resolvedCwd
        let acct = d.claudeAccount()
        DispatchQueue.global(qos: .userInitiated).async {
            // Finding the session reads transcripts: not on the main thread.
            let id = d.runtime == "claude"
                ? Resume.claudeSession(named: d.conversation ?? d.name, cwd: folder, root: acct?.projectsRoot() ?? Resume.claudeProjectsRoot)
                : nil
            let cmd = Handoff.forkCommand(runtime: d.runtime, claudeSession: id, account: acct?.path())
            DispatchQueue.main.async { [weak self, weak s] in
                guard let self, let s else { return }
                guard let cmd else {
                    let a = NSAlert()
                    a.messageText = "This desk's conversation can't be forked from here"
                    a.informativeText = d.runtime == "claude"
                        ? "Coldfall couldn't find the conversation's id. It can once the desk has been named by Coldfall and has said something."
                        : "\(AgentOffer.shortName(d.runtime)) has no fork command Coldfall knows. Claude Code and Codex do."
                    a.runModal()
                    return
                }
                if !s.splitRunning(cmd) { NSSound.beep(); return }
                self.updateTermHeader()
                self.window.makeFirstResponder(s.focusedPane.terminal.view)
            }
        }
    }

    /// The end of this desk's screen, handed to another running desk as
    /// history. Asks first, saying how much goes and that nothing is redacted.
    @objc func handOff() {
        guard let s = activeSession, s.started else { NSSound.beep(); return }
        let from = s.desk
        let others = desks.filter { d in
            d.name != from.name && !d.hidden && d.runtime != "shell" && sessions[d.name]?.started == true
        }
        guard !others.isEmpty else {
            let a = NSAlert()
            a.messageText = "No other desk is running"
            a.informativeText = "Start the desk you want to hand this work to, then try again."
            a.runModal()
            return
        }
        let history = Handoff.tail(s.screenText(lines: 4000))
        let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        for d in others {
            pick.addItem(withTitle: "\(d.name)  ·  \(d.claudeAccount()?.vendor ?? AgentOffer.shortName(d.runtime))")
            pick.lastItem?.representedObject = d.name
            pick.lastItem?.image = VendorIcon.image(runtime: d.runtime, icon: d.icon, size: 14)
        }
        let a = NSAlert()
        a.messageText = "Hand \(from.name)'s work to another desk?"
        a.informativeText = Handoff.warning(to: "the desk you choose", history: history)
            + " The other agent is told it is history to read, to check the folder first, and to change nothing yet."
        a.accessoryView = pick
        a.addButton(withTitle: "Hand Off"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn, let to = pick.selectedItem?.representedObject as? String else { return }
        let msg = Handoff.compose(from: from.name, vendor: from.claudeAccount()?.vendor ?? AgentOffer.shortName(from.runtime),
                                  folder: (from.resolvedCwd as NSString).abbreviatingWithTildeInPath, history: history)
        let r = inboxSend(to, text: msg)
        if r.outcome == .sent { showDesk(named: to) }
        else {
            let b = NSAlert()
            b.messageText = "Nothing was handed off"
            b.informativeText = r.message
            b.runModal()
        }
    }

    // MARK: - back, forward, reopen

    var history = VisitHistory()
    var closedDesks = ClosedDesks()
    /// Going back or forward mustn't itself count as a new visit.
    var steppingHistory = false
    @objc func goBack() { stepHistory(-1) }
    @objc func goForward() { stepHistory(1) }
    func stepHistory(_ d: Int) {
        guard let n = history.step(d, exists: { [desks] n in desks.contains { $0.name == n && !$0.hidden } }) else { NSSound.beep(); return }
        steppingHistory = true
        showDesk(named: n)
        steppingHistory = false
    }
    /// Start again the desk you stopped last.
    @objc func reopenStopped() {
        guard let n = closedDesks.reopen(exists: { [desks] n in desks.contains { $0.name == n } },
                                         running: { [sessions] n in sessions[n]?.started == true }),
              let i = deskIndex(n) else { NSSound.beep(); return }
        show(i)
    }

    func showDesk(named name: String) {
        if let i = desks.firstIndex(where: { $0.name == name }) { open(i) }
    }
    /// Removing a desk removes the shortcut. It does NOT delete the agent
    /// definition and it does NOT stop a running session — both said out loud,
    /// because guessing wrong about either would be somebody's bad afternoon.
    ///
    /// Confirmation is graduated on purpose. A desk backed by a discoverable
    /// agent or an ssh host is one click to restore, so demanding typed
    /// confirmation there is friction without risk — and friction people learn
    /// to click through stops protecting them. A desk carrying a hand-written
    /// `command` is not recoverable, so that one asks you to type its name.
    func removeDesk(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        let d = desks[i]
        let running = sessions[d.name] != nil
        let recoverable = d.agent != nil || d.command?.hasPrefix("ssh -t ") == true

        var detail = "Removes it from desks.toml. Nothing else is deleted."
        if d.agent != nil {
            detail += "\n\nThe agent definition stays where it is, with its memory. "
                + "Delete that with the vendor's own tooling if you want it gone. "
                + "Project Coldfall will offer this desk back the next time it looks."
        } else if d.command?.hasPrefix("ssh -t ") == true {
            detail += "\n\nThe host stays in ~/.ssh/config, so Project Coldfall will offer it back."
        } else if let c = d.command {
            detail += "\n\nThis desk runs a command you wrote by hand and nothing else knows "
                + "about it, so removing it loses that configuration:\n\n    \(c)"
        }
        if running {
            detail += "\n\nIts session is running and keeps running until Project Coldfall quits."
        }

        let a = NSAlert()
        a.messageText = "Remove the \(d.name) desk?"
        a.informativeText = detail
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")

        // Unrecoverable: make them type the name.
        var field: NSTextField? = nil
        if !recoverable {
            a.alertStyle = .critical
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            f.placeholderString = "type \(d.name) to confirm"
            a.accessoryView = f
            field = f
            a.buttons.first?.title = "Remove"
        } else {
            // Nothing typed, so nothing deliberate yet: Return cancels, and
            // removing takes a click on Remove itself.
            a.buttons[0].hasDestructiveAction = true
            a.buttons[0].keyEquivalent = ""
            a.buttons[1].keyEquivalent = "\r"
        }

        guard a.runModal() == .alertFirstButtonReturn else { return }
        if !recoverable {
            let typed = (field?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            guard typed == d.name else {
                let no = NSAlert()
                no.messageText = "Not removed"
                no.informativeText = typed.isEmpty
                    ? "Nothing was typed, so nothing was changed."
                    : "\"\(typed)\" does not match \"\(d.name)\", so nothing was changed."
                no.runModal()
                return
            }
        }

        guard let i = deskIndex(d.name) else { return }
        let before = desks
        desks.remove(at: i)
        persist()
        noteRemovedRuntimes(before: before, after: desks)
        sidebar.build(desks: desks)
        installMenu()
        if visible?.desk.name == d.name, !desks.isEmpty { open(0) }
        else if let v = visible, let j = desks.firstIndex(where: { $0.name == v.desk.name }) {
            sidebar.select(j)
        }
    }

    /// Rename in place. Only the name changes: a desk that runs a `command`
    /// keeps running exactly that command, so a launcher script keyed on the
    /// old name still works. A running session carries on under the new name.
    func renameDesk(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        let old = desks[i].name
        let a = NSAlert()
        a.messageText = "Rename the \(old) desk"
        a.informativeText = "Letters, numbers, - and _. Saved to ~/.config/coldfall/desks.toml."
        a.addButton(withTitle: "Rename"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.stringValue = old
        a.accessoryView = f
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let new = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard new != old else { return }
        if let why = DeskName.problem(new, existing: desks.map(\.name), current: old) {
            let no = NSAlert(); no.messageText = "Not renamed"; no.informativeText = why; no.runModal()
            return
        }
        guard let i = deskIndex(old) else { return }
        desks[i] = desks[i].renamed(from: old, to: new)
        if let s = sessions.removeValue(forKey: old) {
            s.desk.name = new; sessions[new] = s
            if Holder.rename(from: old, to: new) { s.followRename(to: new) }
        } else { Holder.rename(from: old, to: new) }
        persist()
        sidebar.build(desks: desks)
        installMenu()
        if visible?.desk.name == new {
            sidebar.select(i)
            window.title = "Project Coldfall — \(new)"
            strip.setContext(new)
            meter.currentDesk = new
            updateTermHeader()
        } else if let v = visible, let j = desks.firstIndex(where: { $0.name == v.desk.name }) {
            sidebar.select(j)
        }
    }

    /// Stop a desk's processes to get their memory back. A claude desk holds
    /// close to a gigabyte with its MCP servers, so this is the lever when
    /// many are open. The dialog says what comes back when it starts again,
    /// which depends on who launches it.
    func stopDesk(_ i: Int) {
        guard desks.indices.contains(i), let s = sessions[desks[i].name], s.started else { return }
        let d = desks[i]
        // Whether this desk is known to come back where it was: Coldfall
        // resumes it, or its script says how to start fresh (and so resumes
        // by default). Only then can the dialog promise that.
        let resumes = d.resumesItself || d.fresh != nil
        guard resumes, d.runtime == "claude" else { presentStop(d, s, resumes: resumes, convo: nil); return }
        // Finding the conversation reads transcripts, which on a long-lived
        // folder is seconds of work: not on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let convo = Reopen.claude(d)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessions[d.name] === s, s.started else { return }
                self.presentStop(d, s, resumes: resumes, convo: convo)
            }
        }
    }

    func presentStop(_ d: Desk, _ s: DeskSession, resumes: Bool, convo: ConversationInfo?) {
        let a = NSAlert()
        a.messageText = "Stop \(d.name)?"
        if resumes {
            a.informativeText = Reopen.stopBody(desk: d, memory: memory[d.name], convo)
        } else {
            var info = "Ends its processes"
            if let m = memory[d.name] { info += " and frees about \(m)" }
            info += ". Click the desk to start it again."
            if let after = Resume.afterRestart(d) { info += "\n\n" + after }
            a.informativeText = info
        }
        a.addButton(withTitle: "Stop")                       // the default
        let wrap = resumes && Reopen.offersWrapUp(desk: d, convo)
        if wrap { a.addButton(withTitle: "Wrap Up & Stop") }
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        if r == .alertFirstButtonReturn { endDesk(d); return }
        if wrap, r == .alertSecondButtonReturn { wrapUp(d, s) }
    }

    /// Ask the desk to save what's worth keeping, then offer to stop it once
    /// it has answered. It never stops by itself: an agent that stops talking
    /// may be waiting for permission to write its notes, and stopping it
    /// then would save nothing. So the person looks, and decides.
    func wrapUp(_ d: Desk, _ s: DeskSession) {
        guard !s.agentGone else {
            let a = NSAlert()
            a.messageText = "\(d.name)'s agent has already exited"
            a.informativeText = "Only a shell pane is left, so there is nothing to wrap up. Stop the desk and start it again."
            a.runModal(); return
        }
        // The same rules as a send: never into a question (Enter would answer
        // it), never over a message you're writing, never into a bare shell.
        let t = s.remoteTarget()
        if !t.agent || t.blocked || t.draft {
            let a = NSAlert()
            a.messageText = t.blocked ? "\(d.name) is waiting on a question" : (t.draft ? "You're writing in \(d.name)" : "\(d.name)'s agent isn't running")
            a.informativeText = t.blocked ? "Answer it first, then Wrap Up & Stop." :
                (t.draft ? "Send or clear what you're typing first, then Wrap Up & Stop." : "Only a shell is left, so there's nothing to wrap up. Stop the desk instead.")
            a.runModal(); return
        }
        if let i = desks.firstIndex(where: { $0.name == d.name }) { show(i) }
        let sent = Date()
        s.agent.send(text: Reopen.wrapUpPrompt + "\r")
        var ticks = 0
        Timer.inEveryMode(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            ticks += 1
            // Gone: stopped some other way in the meantime.
            guard self.sessions[d.name] === s else { t.invalidate(); return }
            let answered = (s.lastOutput ?? .distantPast) > sent.addingTimeInterval(2)
            let quiet = Date().timeIntervalSince(s.lastOutput ?? .distantPast) >= 6
            if answered && quiet {
                t.invalidate()
                let a = NSAlert()
                a.messageText = "\(d.name) looks done wrapping up"
                a.informativeText = "Check the desk: if it's asking for permission to save, answer that first. "
                    + "Once it's stopped, opening \(d.name) again offers a clean conversation."
                a.addButton(withTitle: "Stop Now")
                a.addButton(withTitle: "Keep It Running")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                self.ui.wrappedUp[d.name] = Date().timeIntervalSince1970
                self.ui.save()
                self.endDesk(d)
            } else if ticks >= 600 {
                t.invalidate()
                let a = NSAlert()
                a.messageText = "\(d.name) is still wrapping up"
                a.informativeText = "It's been ten minutes. Stop it from its menu when it's done."
                a.runModal()
            }
        }
    }

    /// The last week's report, for budgets on desks and the Start screen.
    var lastReport: Usage.Report?
    func applyBudgets(_ r: Usage.Report) {
        lastReport = r
        // A snapshot showing made-up budgets keeps them over the real scan.
        if CommandLine.arguments.contains("--budget-demo") { return }
        var out: [String: DeskBudget.Status] = [:]
        for d in desks where d.budget != nil {
            out[d.name] = DeskBudget.status(spent: DeskBudget.spent(by: d, in: r), budget: d.budget)
        }
        sidebar.budgets = out
    }

    /// A desk's index looked up again by name, for after a dialog: the list
    /// can be regrouped, reordered or shortened under a modal by a reload of
    /// desks.toml, and an index captured before it would then point at the
    /// wrong desk, or off the end.
    func deskIndex(_ name: String) -> Int? { desks.firstIndex { $0.name == name } }

    /// The desk shown at launch, or stopped, and not yet started. By name,
    /// not index: the list moves under it.
    var waitingName: String?
    /// Desks that were running when Coldfall last closed and aren't back.
    var restoreOffer: [String] = []

    /// Keep UIState.runningDesks current, so a restart of the Mac or a crash
    /// knows what to offer back. Written only when it changes.
    func noteRunning() {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        let now = desks.map(\.name).filter { n in sessions[n].map { $0.started || $0.resolving } ?? false }
        guard now != ui.runningDesks else { return }
        ui.runningDesks = now
        ui.save()
    }

    /// Start every desk on the restore offer, each picking up its
    /// conversation. In the background: the one on screen stays.
    @objc func restoreDesks() {
        let names = restoreOffer
        restoreOffer = []
        for n in names { openRemotely(n, show: false) }
        if let n = waitingName, let i = deskIndex(n) { showWaiting(i) }
    }

    /// Picking a desk. One that's running comes up at once; one that isn't
    /// shows its Start button first, so a stray click starts nothing. Places
    /// that need the desk running (Wrap Up, running a command in it, a new
    /// shell someone just asked for) call show() and start it directly.
    func open(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        if ui.confirmStart, sessions[desks[i].name]?.started != true { showWaiting(i) } else { show(i) }
    }

    /// Put a desk on screen without starting it: the rail, the title, the
    /// file tree all follow it, and a Start button (Return) starts it. So
    /// launching the app starts nothing.
    func showWaiting(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        let d = desks[i]
        if sessions[d.name]?.started == true { show(i); return }
        visible?.container.removeFromSuperview()
        visible?.isVisible = false
        visible = nil
        slots[keySlot].session = nil
        stoppedNote?.removeFromSuperview(); stoppedNote = nil

        let title = NSTextField(labelWithString: "\(d.name)")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = Theme.ui.text
        let start = NSButton(title: "Start \(d.name)", target: self, action: #selector(startWaiting))
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        let hint = NSTextField(labelWithString: "Nothing runs until you press Start, or Return.")
        hint.textColor = Theme.ui.dimText
        var views: [NSView] = [title, start, hint]
        // What was running before a restart of the Mac, offered back.
        if let line = RestoreOffer.line(restoreOffer) {
            let note = NSTextField(wrappingLabelWithString: line)
            note.textColor = Theme.ui.dimText
            note.alignment = .center
            note.preferredMaxLayoutWidth = 420
            let again = NSButton(title: RestoreOffer.button(restoreOffer), target: self, action: #selector(restoreDesks))
            again.bezelStyle = .rounded
            let gap = NSView(); gap.heightAnchor.constraint(equalToConstant: 8).isActive = true
            views += [gap, note, again]
        }
        // Over its budget: say so before it starts spending more.
        if let r = lastReport,
           case .over = DeskBudget.status(spent: DeskBudget.spent(by: d, in: r), budget: d.budget),
           let line = DeskBudget.label(DeskBudget.status(spent: DeskBudget.spent(by: d, in: r), budget: d.budget)) {
            let over = NSTextField(labelWithString: "Over budget: " + line + ".")
            over.textColor = .systemRed
            views.insert(over, at: 1)
        }
        let box = NSStackView(views: views)
        box.orientation = .vertical; box.alignment = .centerX; box.spacing = 12
        box.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(box)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        stoppedNote = box
        waitingName = d.name

        sidebar.select(i)
        window.title = "Project Coldfall — \(d.name)"
        strip.setContext(d.name)
        meter.currentDesk = d.name
        watcher.start(root: d.resolvedCwd)
        tree.setRoot(d.resolvedCwd)
    }

    @objc func startWaiting() {
        guard let n = waitingName, let i = deskIndex(n) else { return }
        show(i)
    }

    /// A new plain shell as its own desk, in the folder of the desk on screen.
    @objc func newShellDesk() {
        let cwd = visible?.desk.cwd ?? waitingName.flatMap { n in desks.first { $0.name == n }?.cwd }
        let d = DeskConfig.newShellDesk(in: desks, cwd: cwd)
        desks.append(d)
        guard persist() else { return }
        desks = DeskOrder.grouped(desks)
        refreshRail()
        installMenu()
        if let i = desks.firstIndex(where: { $0.name == d.name }) { show(i) }
    }

    /// End a desk's session, already confirmed.
    func endDesk(_ d: Desk) {
        guard let s = sessions[d.name] else { return }
        // Out of the table first, so the exit callbacks find nothing to tidy.
        sessions.removeValue(forKey: d.name)
        memory.removeValue(forKey: d.name)
        closedDesks.closed(d.name)
        s.terminateAll()
        // One of several on screen: its place closes and the rest stay.
        if slots.count > 1, let k = slotIndex(of: s) {
            closeSlot(k)
        } else if visible === s {
            s.container.removeFromSuperview()
            visible = nil
            slots[keySlot].session = nil
            // Stopped, it waits on its Start button like any desk not running.
            if let i = desks.firstIndex(where: { $0.name == d.name }) { showWaiting(i) }
        }
    }
    var stoppedNote: NSView?

    // MARK: - keep active groups on top

    /// When each desk was last opened, for "most recently used".
    var lastVisited: [String: Date] = [:]
    var liveTimer: Timer?
    var lastLiveApply = Date.distantPast

    /// The Desks section by priority, or by group.
    @objc func toggleDeskPriority() {
        ui.desksByPriority.toggle()
        ui.save()
        sidebar.byPriority = ui.desksByPriority
        fitRail()
        installMenu()
    }

    /// The desk after, or before, this one in the list as it is shown. By
    /// priority, that walks who needs you first.
    @objc func nextDesk() { stepDesk(1) }
    @objc func prevDesk() { stepDesk(-1) }
    func stepDesk(_ d: Int) {
        let here = waitingName ?? visible?.desk.name
        guard let n = DeskOrder.step(sidebar.shownOrder, from: here, by: d) else { NSSound.beep(); return }
        showDesk(named: n)
    }

    @objc func toggleLiveRail() {
        ui.liveRail.toggle()
        ui.save()
        sidebar.liveOn = ui.liveRail
        applyLiveOrder(force: true)
        installMenu()
    }

    /// A group was picked in the Groups section: its desk used most recently,
    /// else one that's running, else its first.
    func goToGroup(_ g: String?) {
        let members = desks.indices.filter { desks[$0].group == g && !desks[$0].hidden }
        guard !members.isEmpty else { return }
        let recent = members.max { (lastVisited[desks[$0].name] ?? .distantPast) < (lastVisited[desks[$1].name] ?? .distantPast) }
        let pick = (recent.flatMap { lastVisited[desks[$0].name] != nil ? $0 : nil })
            ?? members.first { sessions[desks[$0].name]?.started == true } ?? members[0]
        if sessions[desks[pick].name]?.started == true { show(pick) } else { showWaiting(pick) }
    }

    /// The desks get up to 70% of the left column, as much as they need;
    /// the file tree has the rest. Desks are what you came for.
    func fitRail() {
        let h = rail.bounds.height
        let want = ui.treeOnTop ? h * 0.5 : min(sidebar.contentHeight + 8, h * 0.7)
        rail.setPosition(max(120, min(want, h - 120)), ofDividerAt: 0)
    }


    // MARK: - opening desks from outside (coldfall-cli open)

    var lastRemoteServe = Date.distantPast
    var lastRemoteStatus = Date.distantPast

    /// Answer `coldfall-cli open` and keep status.json fresh (see RemoteOpen).
    /// Called from the activity tick; does its own pacing.
    func serveRemote(_ map: [String: DeskStatus]) {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        let now = Date()
        var changed = false
        if now.timeIntervalSince(lastRemoteServe) >= 1 {
            lastRemoteServe = now
            for r in RemoteOpen.pending(now: now) {
                if r.action == "read" || r.action == "send" { serveReadSend(r); continue }
                guard RemoteOpen.claim(r) else { continue }
                let running = Set(sessions.filter { $0.value.started || $0.value.resolving || $0.value.holding }.keys)
                let a = RemoteOpen.decide(r.desk, names: desks.map(\.name),
                                          hidden: Set(desks.filter(\.hidden).map(\.name)), running: running)
                if a.outcome == .started { openRemotely(r.desk, show: r.show); changed = true }
                else if a.outcome == .alreadyRunning, r.show, let i = deskIndex(r.desk) { show(i) }
                RemoteOpen.answer(r, a)
            }
        }
        // Every second: `coldfall-cli wait` is watching it.
        if changed || now.timeIntervalSince(lastRemoteStatus) >= 1 {
            lastRemoteStatus = now
            RemoteOpen.writeStatus(RemoteOpen.Status(desks: desks.map { d in
                let s = sessions[d.name]
                let act: String
                switch map[d.name]?.activity {
                case .working?: act = "working"
                case .ready?: act = "ready"
                case .blocked?: act = "blocked"
                default: act = "quiet"
                }
                return RemoteOpen.DeskState(name: d.name, running: s.map { $0.started || $0.resolving } ?? false, activity: act,
                                            turnEndedAt: s?.turnEndedAt?.timeIntervalSince1970,
                                            needsYou: s?.isBlocked, outputAt: s?.lastOutput?.timeIntervalSince1970,
                                            signaled: s?.isSignaled)
            }))
        }
    }

    /// `coldfall-cli read` and `send`. A send held back by a half-typed
    /// message stays on the queue and is looked at again each second.
    func serveReadSend(_ r: RemoteOpen.Request) {
        let names = desks.map(\.name), hidden = Set(desks.filter(\.hidden).map(\.name))
        let s = sessions[r.desk]
        if r.action == "read" {
            // Reading needs no agent, so no process-table check.
            let target = s.map { RemoteOpen.Target(running: $0.started, agent: true) }
            guard RemoteOpen.claim(r) else { return }
            if let no = RemoteOpen.refuseRead(r.desk, names: names, hidden: hidden, target: target) { RemoteOpen.answer(r, no); return }
            var a = RemoteOpen.Answer(.read, "")
            a.text = s?.screenText(lines: r.lines ?? 60)
            RemoteOpen.answer(r, a)
            return
        }
        let text = r.text ?? ""
        // A half-typed message holds the send without taking it, so the
        // caller can still withdraw it cleanly.
        if s?.holdsDraft == true, s?.isBlocked == false, s?.started == true { return }
        guard RemoteOpen.claim(r) else { return }
        if let no = RemoteOpen.refuseSend(r.desk, names: names, hidden: hidden, target: s?.remoteTarget(), text: text) {
            RemoteOpen.answer(r, no.outcome == .draft ? RemoteOpen.Answer(.draft, "Someone started typing into \(r.desk) just now; nothing was sent.") : no)
            return
        }
        var a = RemoteOpen.Answer(.sent, "Sent to \(r.desk).")
        a.text = s?.screenText(lines: 400)
        a.at = Date().timeIntervalSince1970
        s?.typeOnBehalf(RemoteOpen.keystrokes(text))
        RemoteOpen.answer(r, a)
    }

    /// Start a desk for someone who isn't at the Mac. Like a click, but it
    /// never asks the start-fresh question (nobody is there to answer it, so
    /// it picks up where it left off), and unless asked it leaves the screen
    /// on whatever desk is showing.
    func openRemotely(_ name: String, show onScreen: Bool) {
        guard let i = deskIndex(name) else { return }
        let d = desks[i]
        let s = sessions[d.name] ?? {
            let new = DeskSession(desk: d)
            new.processDelegate = self
            sessions[d.name] = new
            return new
        }()
        // The size it will have on screen, so the agent draws for it now
        // rather than for a zero-size terminal.
        s.container.translatesAutoresizingMaskIntoConstraints = true
        s.container.frame = host.bounds
        s.container.layoutSubtreeIfNeeded()
        checkInventory(d)
        s.startIfNeeded()
        // Started first, so show() finds it on its way and asks nothing.
        if onScreen { show(i) }
        refreshRail()
    }

    /// Pin a desk to the top of the rail, or take it back off. Saved in
    /// desks.toml as `pinned = true`.
    /// Give a desk its own colour, or take it away. Saved to desks.toml.
    func colorDesk(_ i: Int, _ color: String?) {
        guard desks.indices.contains(i), desks[i].color != color else { return }
        desks[i].color = color
        persist()
        sessions[desks[i].name]?.desk = desks[i]
        refreshRail()
        refreshTabs(sidebar.status)
    }

    func pinDesk(_ i: Int, _ on: Bool) {
        guard desks.indices.contains(i), desks[i].pinned != on else { return }
        desks[i].pinned = on
        persist()
        refreshRail()
    }

    func watchLiveRail() {
        applyLiveOrder(force: true)
        liveTimer = Timer.inEveryMode(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.applyLiveOrder() }
    }

    /// Reorder groups by activity, at a calm moment: not while the pointer
    /// is over the rail, not mid-drag, and not more than every 30 seconds.
    /// Only the display moves; desks.toml, and so cmd-1..9, keep your order.
    func applyLiveOrder(force: Bool = false) {
        guard ui.liveRail else {
            if sidebar.groupOrder != nil { sidebar.groupOrder = nil; refreshRail() }
            return
        }
        if !force {
            guard !sidebar.pointerInside, !sidebar.isDragging,
                  Date().timeIntervalSince(lastLiveApply) >= 30 else { return }
        }
        var waiting: [String: Date] = [:], used: [String: Date] = [:]
        for (name, s) in sessions {
            if s.activity == .ready || s.activity == .blocked, let l = s.lastOutput { waiting[name] = l }
            if let l = s.lastOutput { used[name] = l }
        }
        for (name, d) in lastVisited { used[name] = max(used[name] ?? .distantPast, d) }
        let order = DeskOrder.liveGroups(desks, waiting: waiting, used: used)
        lastLiveApply = Date()
        guard order != sidebar.groupOrder else { return }
        sidebar.groupOrder = order
        refreshRail()
    }

    // MARK: - agents installed after the first run

    var offerTimer: Timer?

    /// Look for installed agents with no desk now, whenever the app comes
    /// back to the front (you may have just installed one in Terminal), and
    /// once a minute.
    func watchNewAgents() {
        DeskConfig.warmLoginShellPath { [weak self] in self?.checkOffers(); self?.checkAgentVersions() }
        checkOffers()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.checkOffers() }
        offerTimer = Timer.inEveryMode(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.checkOffers() }
    }

    /// Ask each installed agent its version, once per launch, and say which
    /// ones changed since last time. Local only: no model call, no tokens.
    func checkAgentVersions() {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        showAgentNews()
        let before = ui.agentVersions
        DispatchQueue.global(qos: .utility).async {
            let now = AgentVersions.current()
            DispatchQueue.main.async { [weak self] in
                guard let self, !now.isEmpty else { return }
                for c in AgentVersions.changes(from: before, to: now) {
                    // Keep where it started, if an earlier update is still unread.
                    let from = self.ui.agentUpdates[c.runtime]?.first ?? c.from
                    self.ui.agentUpdates[c.runtime] = [from, c.to]
                }
                self.ui.agentVersions.merge(now) { $1 }
                self.ui.save()
                self.showAgentNews()
            }
        }
    }

    func showAgentNews() {
        sidebar.agentNews = ui.agentUpdates.keys.sorted().compactMap { rt in
            guard let v = ui.agentUpdates[rt], v.count == 2 else { return nil }
            return AgentVersions.Change(runtime: rt, from: v[0], to: v[1])
        }
    }

    func checkOffers() {
        let dismissed = Set(ui.dismissedOffers)
        let snapshot = desks
        DispatchQueue.global(qos: .utility).async {
            let missing = AgentOffer.missing(installed: AgentOffer.installed(), desks: snapshot, dismissed: dismissed)
            DispatchQueue.main.async { [weak self] in self?.sidebar.offers = missing }
        }
    }

    func addOfferedDesk(_ runtime: String) {
        let d = AgentOffer.desk(for: runtime, in: desks)
        desks.append(d)
        guard persist() else { return }
        desks = DeskOrder.grouped(desks)
        sidebar.offers.removeAll { $0 == runtime }
        refreshRail()
    }

    /// A runtime whose last desk was removed isn't offered again.
    func noteRemovedRuntimes(before: [Desk], after: [Desk]) {
        for rt in AgentOffer.removed(before: before, after: after) { dismissOffer(rt) }
    }

    /// The needs-you line's Clear: every waiting desk counts as seen.
    func clearWaiting() {
        for name in sidebar.waiting { sessions[name]?.markSeen() }
    }

    func dismissOffer(_ runtime: String) {
        if !ui.dismissedOffers.contains(runtime) { ui.dismissedOffers.append(runtime); ui.save() }
        sidebar.offers.removeAll { $0 == runtime }
    }

    /// Out of the rail and cmd-1..9, kept in desks.toml. A running desk is
    /// offered a stop too, so a desk you can't see isn't quietly holding a
    /// gigabyte; its conversation comes back when it is opened again.
    func hideDesk(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        let d = desks[i]
        var stop = false
        if let s = sessions[d.name], s.started {
            let a = NSAlert()
            a.messageText = "Hide the \(d.name) desk?"
            var info = "It's running"
            if let m = memory[d.name] { info += " and using about \(m)" }
            info += ". Stop it too, so it isn't using memory while hidden?"
            if let after = Resume.afterRestart(d) { info += "\n\n" + after }
            info += "\n\nShow hidden desks from the bottom of the rail, or open one with cmd-P."
            a.informativeText = info
            a.addButton(withTitle: "Hide and Stop")
            a.addButton(withTitle: "Hide, Keep Running")
            a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn: stop = true
            case .alertSecondButtonReturn: stop = false
            default: return
            }
        }
        guard let i = deskIndex(d.name) else { return }
        desks[i].hidden = true
        persist()
        if stop { endDesk(d) }
        refreshRail()
        // Hidden while on screen: show something that is still in the rail.
        if visible?.desk.name == d.name || waitingName == d.name,
           let j = desks.firstIndex(where: { !$0.hidden && $0.name != d.name }) { open(j) }
    }

    func unhideDesk(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        desks[i].hidden = false
        persist()
        refreshRail()
    }

    /// Rebuild the rail and the Desks menu, keeping the selection.
    func refreshRail() {
        sidebar.build(desks: desks)
        installMenu()
        if let v = visible, let j = desks.firstIndex(where: { $0.name == v.desk.name }) { sidebar.select(j) }
    }

    var inventoryWindow: InventoryWindow?
    /// Desks whose servers, hooks, skills or plugins changed since they were
    /// last looked at: name -> how many. Shown on the desk's row.
    var inventoryNews: [String: Int] = [:]

    /// On a desk's start: compare what it has with what was last seen. The
    /// first time there is nothing to compare, so that becomes the baseline.
    func checkInventory(_ d: Desk) {
        guard d.runtime != "shell" else { return }
        let inv = Inventory.of(d)
        guard let before = InventorySeen.baseline(desk: d.name, runtime: d.runtime, current: inv.seen) else {
            InventorySeen.markSeen(desk: d.name, runtime: d.runtime, seen: inv.seen); return
        }
        let n = inv.changes(since: before).count
        inventoryNews[d.name] = n > 0 ? n : nil
    }

    func showInventory(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        let d = desks[i]
        let inv = Inventory.of(d)
        let before = InventorySeen.baseline(desk: d.name, runtime: d.runtime, current: inv.seen)
        inventoryWindow = InventoryWindow(desk: d, inventory: inv, changes: before.map { inv.changes(since: $0) })
        // Looked at: this is now what the desk has. Account-wide items count
        // as seen for every desk of this runtime, so the same plugin does not
        // have to be dismissed desk by desk.
        InventorySeen.markSeen(desk: d.name, runtime: d.runtime, seen: inv.seen)
        inventoryNews[d.name] = nil
        clearSharedNews(runtime: d.runtime, except: d.name)
        inventoryWindow?.showWindow(nil)
        inventoryWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// The other desks of this runtime may have been showing the same
    /// account-wide change. Recount them now it has been seen.
    func clearSharedNews(runtime: String, except name: String) {
        let others = desks.filter { $0.runtime == runtime && $0.name != name && inventoryNews[$0.name] != nil }
        guard !others.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let counts = others.map { d -> (String, Int) in
                let inv = Inventory.of(d)
                let before = InventorySeen.baseline(desk: d.name, runtime: d.runtime, current: inv.seen)
                return (d.name, before.map { inv.changes(since: $0).count } ?? 0)
            }
            DispatchQueue.main.async {
                for (n, c) in counts { self.inventoryNews[n] = c > 0 ? c : nil }
            }
        }
    }

    /// Which of the folder's MCP servers this desk starts. Saved at once;
    /// takes effect the next time the desk starts.
    func editMcp(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        let d = desks[i]
        let servers = McpTrim.servers(for: d)
        let claude = d.runtime == "claude"
        let a = NSAlert()
        a.messageText = "MCP servers for \(d.name)"
        guard !servers.isEmpty else {
            a.informativeText = claude
                ? "This desk's folder has no .mcp.json, so there are no local MCP servers to switch off. "
                  + "claude.ai connectors and plugins are managed in Claude itself."
                : "Codex has no MCP servers set up in ~/.codex/config.toml, so there's nothing to switch off."
            a.runModal(); return
        }
        let (alert, boxes) = mcpAlert(for: d, servers: servers)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Keep entries for servers not in .mcp.json right now, so a server
        // that comes back later is still off for this desk.
        let listed = Set(servers)
        guard let i = deskIndex(d.name) else { return }
        desks[i].mcpOff = d.mcpOff.filter { !listed.contains($0) }
            + zip(servers, boxes).filter { $0.1.state == .off }.map(\.0)
        persist()
    }

    /// The chooser itself, with a checkbox per server. Separate so a
    /// snapshot can draw it without running it.
    func mcpAlert(for d: Desk, servers: [String]) -> (NSAlert, [NSButton]) {
        let claude = d.runtime == "claude"
        let a = NSAlert()
        a.messageText = "MCP servers for \(d.name)"
        var info = "Each one is a separate program this desk starts, with its own memory. "
            + "Untick the ones this desk doesn't need. "
            + (claude ? "claude.ai connectors and plugins aren't affected. " : "")
            + "Takes effect the next time the desk starts."
        if let c = d.command, !c.isEmpty, !claude {
            info += "\n\nThis desk runs its own command, so Coldfall can't pass the choice to Codex."
        } else if let c = d.command, !c.isEmpty, !McpTrim.commandHonors(c) {
            info += "\n\nThis desk runs its own command, which doesn't pass the choice on to Claude yet. "
                + "Add --settings \"$\(McpTrim.envKey)\" to the claude line in that script when the variable is set."
        }
        a.informativeText = info
        let boxes = servers.map { s -> NSButton in
            let b = NSButton(checkboxWithTitle: s, target: nil, action: nil)
            b.state = d.mcpOff.contains(s) ? .off : .on
            return b
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: CGFloat(boxes.count) * 24)
        a.accessoryView = stack
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        return (a, boxes)
    }

    /// The changelog lives in the repo, so the app and GitHub read one file.
    /// What Coldfall would leave behind, and an offer to remove it. Nothing
    /// here touches the agents: that is the first thing the alert says.
    @objc func openUninstall() {
        let items = Uninstall.items()
        let recorders = Uninstall.settingsFiles(desks: desks).filter { Limits.recorderInstalledAt($0) }

        let a = NSAlert()
        a.messageText = "Remove Project Coldfall's files?"
        let body = Uninstall.summary(items: items, recorders: recorders, doneHook: DoneSignal.isInstalled)
        a.informativeText = body
        if items.isEmpty && recorders.isEmpty {
            a.addButton(withTitle: "OK")
            a.runModal(); return
        }
        a.addButton(withTitle: "Delete These Files")
        a.addButton(withTitle: "Cancel")
        // Return must never delete. NSAlert makes the first button the
        // default, so a habitual Return would have wiped everything; Cancel
        // takes Return (and Escape), and deleting needs a deliberate click.
        a.buttons[0].hasDestructiveAction = true
        a.buttons[0].keyEquivalent = ""
        a.buttons[1].keyEquivalent = "\r"
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let log = Uninstall.removeEverything(desks: desks)
        let done = NSAlert()
        done.messageText = "Removed"
        done.informativeText = log.joined(separator: "\n")
            + "\n\nQuit Project Coldfall and drag it to the Trash to finish. "
            + "Your agents are as they were."
        done.runModal()
    }

    @objc func openChangelog() {
        NSWorkspace.shared.open(URL(string: "https://github.com/anthonyproctor/project-coldfall/blob/main/CHANGELOG.md")!)
    }

    /// Drag in the rail. Saved at once, and the menu is rebuilt so cmd-1..9
    /// follow the order on screen.
    func moveDesk(_ i: Int, to drop: DeskDrop) {
        reorder(DeskOrder.grouped(DeskOrder.move(desks, from: i, to: drop)))
    }

    /// Drag a group's header: the whole group moves.
    func moveGroup(_ g: String, before: String?) {
        reorder(DeskOrder.moveGroup(desks, g, before: before))
    }

    /// Groups and desks A to Z, once. Dragging afterwards still works, so this
    /// asks first: the order it replaces is not kept anywhere.
    @objc func sortDesks() {
        let sorted = DeskOrder.sortedAZ(desks)
        guard sorted.map(\.name) != desks.map(\.name) else { return }
        let a = NSAlert()
        a.messageText = "Sort desks A to Z?"
        a.informativeText = "Groups and the desks in each group are sorted by name. Ungrouped desks stay on top. You can still drag desks and groups afterwards."
        a.addButton(withTitle: "Sort"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        reorder(sorted)
    }

    /// Save a new order, and rebuild the menu so cmd-1..9 follow the rail.
    private func reorder(_ next: [Desk]) {
        let key = { (ds: [Desk]) in ds.map { "\($0.name)|\($0.group ?? "")" } }
        guard key(next) != key(desks) else { return }
        desks = next
        persist()
        sidebar.build(desks: desks)
        installMenu()
        if let v = visible, let j = desks.firstIndex(where: { $0.name == v.desk.name }) { sidebar.select(j) }
    }

    /// The safe half of deleting an agent: show it, let them decide.
    func revealAgent(_ i: Int) {
        guard desks.indices.contains(i), let agent = desks[i].agent else { return }
        let root = desks[i].resolvedCwd
        let candidates = [
            "\(root)/.claude/agents/\(agent).md",
            "\(root)/.github/agents/\(agent).agent.md",
            NSString(string: "~/.claude/agents/\(agent).md").expandingTildeInPath,
        ]
        if let hit = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit)])
        } else {
            let a = NSAlert()
            a.messageText = "No definition found for \(agent)"
            a.informativeText = "Looked in .claude/agents, .github/agents and ~/.claude/agents."
            a.runModal()
        }
    }

    @objc func refreshTree() { tree.refresh() }
    @objc func undoMove() { tree.undoLastMove() }

    // MARK: - NSSplitViewDelegate
    //
    // Floors on every pane. Without these the rail divider could be dragged —
    // or land, on a short window — such that the desk list had zero height and
    // no way back, which is exactly what happened with the tree on top.

    func splitView(_ sv: NSSplitView, constrainMinCoordinate p: CGFloat,
                   ofSubviewAt i: Int) -> CGFloat {
        if sv === rail { return p + 80 }
        // rail at least 170; the terminal at least 320.
        if sv === split { return p + (i == 0 ? 170 : 320) }
        return p + 120          // a pane, which needs far less room than the rail
    }

    func splitView(_ sv: NSSplitView, constrainMaxCoordinate p: CGFloat,
                   ofSubviewAt i: Int) -> CGFloat {
        if sv === rail { return p - 120 }
        // terminal at least 320; the reader at least 280.
        if sv === split { return p - (i == 0 ? 320 : 280) }
        return p - 120
    }

    func splitView(_ sv: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        // Only the terminal absorbs a window resize; the rail and the reader
        // keep the widths the user gave them. Panes inside a desk share.
        sv === split ? view === center : true
    }

    /// One default per runtime. Marking a desk clears the flag on its siblings
    /// but leaves other runtimes alone, so a Claude home and a Codex home can
    /// both exist.
    func makeDefault(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        let rt = desks[i].runtime
        for j in desks.indices where desks[j].runtime == rt { desks[j].isDefault = false }
        desks[i].isDefault = true
        persist()
        sidebar.build(desks: desks)
        if let v = visible, let j = desks.firstIndex(where: { $0.name == v.desk.name }) {
            sidebar.select(j)
        }
    }

    /// The cross-vendor bridge: drive the mailbox rather than invent a protocol.
    var updateWindow: UpdateWindow?
    @objc func openUpdate() {
        guard let root = SelfUpdate.sourceRoot else {
            let a = NSAlert()
            a.messageText = "This build has no source to update from"
            a.informativeText = "Project Coldfall records where it was built from when you run "
                + "scripts/build-app.sh. This bundle has no such record, or the source has moved, "
                + "so there is nothing to rebuild."
            a.runModal(); return
        }
        updateWindow = UpdateWindow(root: root)
        updateWindow?.showWindow(nil)
        updateWindow?.window?.makeKeyAndOrderFront(nil)
    }

    var settings: SettingsWindow?
    var welcome: WelcomeWindow?

    @objc func openSettings() {
        settings = SettingsWindow(projectDir: visible?.desk.resolvedCwd
                                  ?? desks.first?.resolvedCwd
                                  ?? FileManager.default.currentDirectoryPath)
        settings?.onSaved = { [weak self] in self?.reloadDesks() }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showWelcome() {
        welcome = WelcomeWindow(projectDir: desks.first?.resolvedCwd
                                ?? FileManager.default.currentDirectoryPath)
        welcome?.onFinish = { [weak self] in self?.reloadDesks() }
        welcome?.showWindow(nil)
        welcome?.window?.makeKeyAndOrderFront(nil)
    }

    /// Config changed under us: rebuild the rail, keep running desks alive.
    func reloadDesks() {
        var fresh = DeskOrder.grouped(DeskConfig.load())
        guard !fresh.isEmpty else { return }
        // A desk renamed on disk keeps its running terminal: its session,
        // and what the rail knows about it, move to the new name.
        var pinned = false
        for (from, to) in DeskSync.renames(from: desks, to: fresh) {
            // A rename in the file, like one made in the app, keeps the
            // desk's conversation: the transcript is titled with the old name.
            if let i = fresh.firstIndex(where: { $0.name == to }) {
                let r = fresh[i].renamed(from: from, to: to)
                if r.conversation != fresh[i].conversation { fresh[i] = r; pinned = true }
            }
            if let s = sessions.removeValue(forKey: from) {
                sessions[to] = s
                if Holder.rename(from: from, to: to) { s.followRename(to: to) }
            } else { Holder.rename(from: from, to: to) }
            if let v = inventoryNews.removeValue(forKey: from) { inventoryNews[to] = v }
            if let v = lastVisited.removeValue(forKey: from) { lastVisited[to] = v }
            if let v = memory.removeValue(forKey: from) { memory[to] = v }
        }
        for (name, s) in sessions { if let d = fresh.first(where: { $0.name == name }) { s.desk = d } }
        // A desk gone from the file is gone: its processes end, and nothing
        // it left behind (a "needs you", a memory figure) outlives it. Not on
        // the instant, though: an editor that autosaves writes half-typed
        // files, and a `[desk.]` mid-rename read as "gone" used to kill a
        // running agent. The file gets five seconds to settle first; a desk
        // still missing then is ended.
        let gone = sessions.keys.filter { n in !fresh.contains { $0.name == n } }
        if !gone.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                for n in gone where self.deskIndex(n) == nil {
                    if let s = self.sessions[n] { self.endDesk(s.desk) }
                }
            }
        }
        noteRemovedRuntimes(before: desks, after: fresh)
        desks = fresh
        knownConfig = DeskSync.snapshot()
        if pinned { persist() }
        refreshRail()
        // A budget set or changed in the file shows at once.
        if let r = lastReport { applyBudgets(r) }
        if let v = visible {
            window.title = "Project Coldfall — \(v.desk.name)"
            strip.setContext(v.desk.name)
            meter.currentDesk = v.desk.name
            updateTermHeader()
        }
        NotificationCenter.default.post(name: .coldfallDesksReloaded, object: nil)
    }

    /// desks.toml as this app last read or wrote it. Anything else on disk
    /// was written by someone else.
    var knownConfig: String?
    let configWatcher = DeskConfigWatcher(path: DeskConfig.path)

    /// Save the desk list, unless desks.toml changed on disk since it was
    /// read: then take what's on disk and say so, rather than write the old
    /// list back over someone else's edit.
    @discardableResult
    func persist() -> Bool {
        if let now = DeskSync.snapshot(), let known = knownConfig, now != known {
            reloadDesks()
            let a = NSAlert()
            a.messageText = "desks.toml changed on disk"
            a.informativeText = "Something else edited it just now, so Project Coldfall loaded that version "
                + "instead of saving over it. Your last change wasn't saved; please make it again."
            a.runModal()
            return false
        }
        DeskConfig.write(desks)
        knownConfig = DeskSync.snapshot()
        return true
    }

    /// An edit from outside the app: pick it up, unless it's our own write.
    func watchDeskConfig() {
        knownConfig = DeskSync.snapshot()
        configWatcher.onChange = { [weak self] in
            guard let self, DeskSync.snapshot() != self.knownConfig else { return }
            self.reloadDesks()
        }
        configWatcher.start()
    }

    var agentsPanel: AgentsPanel?
    @objc func openAgents() {
        let dir = visible?.desk.resolvedCwd ?? desks.first?.resolvedCwd
                  ?? FileManager.default.currentDirectoryPath
        agentsPanel = AgentsPanel(projectDir: dir)
        agentsPanel?.onDeskAdded = { [weak self] in self?.reloadDesks() }
        agentsPanel?.onRunInDesk = { [weak self] runtime, cmd in
            self?.runInDesk(runtime: runtime, command: cmd)
        }
        agentsPanel?.showWindow(nil)
        agentsPanel?.window?.makeKeyAndOrderFront(nil)
    }

    /// Open a desk for this runtime and type a command into it. Used to hand
    /// agent creation back to the vendor instead of rebuilding it here.
    func runInDesk(runtime: String, command: String) {
        let idx = DeskConfig.general(for: runtime, in: desks)
        guard let i = idx else {
            let a = NSAlert()
            a.messageText = "No \(runtime) desk to run that in"
            a.informativeText = "Add one in Settings, then try again."
            a.runModal(); return
        }
        if sessions[desks[i].name]?.agentGone == true {
            let a = NSAlert()
            a.messageText = "\(desks[i].name)'s agent has exited"
            a.informativeText = "Only a shell pane is left, so that can't be run there. Stop the desk and start it again."
            a.runModal(); return
        }
        show(i)
        window.makeKeyAndOrderFront(nil)
        // The desk it was meant for, held now: switching desks in the next
        // few seconds must not move the command to another one.
        guard let target = sessions[desks[i].name] else { return }
        let name = desks[i].name
        // Let the CLI finish starting before typing at it, and only type
        // once it's really there: into a bare shell it would run as a command.
        func attempt(_ left: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (left == 8 ? 0.3 : 1.0)) { [weak self] in
                guard let self, self.sessions[name] === target else { return }
                if target.agentAlive() { target.agent.send(text: command + "\n"); return }
                if left > 0 { attempt(left - 1); return }
                let a = NSAlert()
                a.messageText = "\(name)'s agent didn't come up"
                a.informativeText = "Nothing was typed. Start the desk, then try again."
                a.runModal()
            }
        }
        attempt(8)
    }

    /// Last stop on the responder chain for cmd-z. A text view being edited
    /// handles `undo:` itself and this never fires; anywhere else — the tree,
    /// the desk list, a terminal — it means "put that file back".
    @objc func undo(_ sender: Any?) { undoMove() }

    /// Follow the OS light/dark switch when the theme is on "system".
    ///
    /// The terminals are repainted explicitly: SwiftTerm holds its colours as
    /// concrete values rather than semantic ones, so unlike the rest of the UI
    /// it does not follow the appearance on its own.
    func watchSystemAppearance() {
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard let self else { return }
            let was = Theme.isDark
            Theme.invalidate()
            guard Theme.isDark != was else { return }
            DispatchQueue.main.async {
                Theme.apply(to: self.window)
                Theme.paint(self.rail, Theme.ui.sidebar)
                for sl in self.slots { Theme.paint(sl.view, Theme.ui.sidebar) }
                Theme.paint(self.center, Theme.ui.sidebar)
                self.tabs.restyle()
                for s in self.sessions.values {
                    s.applyColor()
                }
                self.sidebar.restyle()
                self.tree.restyle()
                self.meter.restyle()
                self.strip.restyle()
            }
        }
    }
    var appearanceObserver: NSKeyValueObservation?

    /// Refresh the activity badges once a second.
    ///
    /// Polled rather than event-driven on purpose: "finished" is inferred from
    /// output STOPPING, and nothing fires an event when data does not arrive.
    /// A one-second tick against a handful of desks costs nothing.
    /// What desks' agents have said about being done (see DoneSignal).
    let doneSignals: DoneSignal.Reader = { DoneSignal.trim(); return DoneSignal.Reader() }()

    func watchDeskActivity() {
        activityTimer = Timer.inEveryMode(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            let said = self.doneSignals.read()
            if !said.isEmpty {
                for sig in said {
                    // By the name the desk started under: a rename doesn't
                    // reach the agent's environment until it restarts.
                    for (name, s) in self.sessions where DoneSignal.fileName(s.launchName ?? name) == sig.desk { s.noteSignal(sig.event, message: sig.message) }
                }
            }
            var map: [String: DeskStatus] = [:]
            var waiting = 0
            let front = NSApp.isActive
            for (name, s) in self.sessions where self.desks.contains(where: { $0.name == name }) {
                if s.onTurnStart == nil { s.onTurnStart = { [weak self, weak s] in if let s { self?.snapshotTurn(s) } } }
                s.dropRepaint()
                let a = s.activity
                if self.ui.notifyDesks, !CommandLine.arguments.contains("--snapshot") {
                    // On screen means any place in the grid, not only the one with the keys.
                    let alert = NotifyRule.decide(from: self.lastActivity[name] ?? .quiet, to: a, signaled: s.isSignaled,
                                                  appActive: front, deskVisible: self.slotIndex(of: s) != nil,
                                                  event: s.alertEvent, alerted: self.lastAlerted[name])
                    if alert != .silent { self.lastAlerted[name] = s.alertEvent ?? .distantPast }
                    self.notifier.deliver(alert, desk: name, activity: a, reason: s.detailLine)
                }
                self.lastActivity[name] = a
                map[name] = DeskStatus(activity: a, lastOutput: s.lastOutput, running: s.started,
                                       memory: self.memory[name], news: self.inventoryNews[name] ?? 0,
                                       detail: s.started ? s.detailLine : nil)
                if a == .ready || a == .blocked { waiting += 1 }
            }
            // Asleep: no session, but the row should say why it isn't running.
            // Awake again, however it was started: no longer asleep.
            if self.ui.sleeping.contains(where: { self.sessions[$0]?.started == true }) {
                self.ui.sleeping.removeAll { self.sessions[$0]?.started == true }
                self.ui.save()
            }
            for n in self.ui.sleeping where map[n] == nil { map[n] = DeskStatus(asleep: true) }
            if self.sidebar.tick % 85 == 0 { self.sleepIdleDesks(); self.runSchedules() }
            self.sidebar.tick &+= 1
            // Context and branch move slowly: every five seconds or so.
            if self.sidebar.tick % 14 == 0 { self.visible?.refreshHeaders() }
            self.sidebar.status = map
            self.refreshTabs(map)
            self.meter.setCounts(DeskCounts.of(map.values.filter(\.running).map(\.activity)))
            for (name, s) in self.sessions { s.setMark(Mark(map[name] ?? DeskStatus())) }
            self.serveRemote(map)
            self.noteRunning()

            // The dock badge is the half that works when Coldfall is not the
            // front app, which is exactly when you have walked away from a desk.
            NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
        }
    }
    var activityTimer: Timer?
    /// Each desk's state as of the last tick, to notice it change.
    var lastActivity: [String: DeskActivity] = [:]
    /// The agent's report each desk was last alerted for (see NotifyRule).
    var lastAlerted: [String: Date] = [:]
    let notifier = Notifier()
    var inboxServer: InboxServer?
    let peek = PeekPanel()
    let feed = FeedPanel()
    let changes = ChangesPanel()

    // MARK: - two desks side by side

    /// The desk shown next to the one on screen, if any. It is a whole desk
    /// with its own agent, not a pane of the first.
    /// One place in the grid of desks on screen.
    final class DeskSlot {
        let view = NSView()
        var session: DeskSession?
    }
    /// The desks on screen, in order. Always at least one place; the one at
    /// `keySlot` holds `visible`, the desk the keys, the list and the tabs
    /// are on.
    var slots = [DeskSlot()]
    var keySlot = 0
    let deskSplit = DeskGridView()
    var onScreen: [DeskSession] { slots.compactMap(\.session) }
    func slotIndex(of s: DeskSession) -> Int? { slots.firstIndex { $0.session === s } }
    /// The desk pane commands act on: the one with the keys.
    var activeSession: DeskSession? { visible }

    var besideMenu = NSMenu(title: "Open Beside")
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === besideMenu else { return }
        menu.removeAllItems()
        let all = desks.map { (name: $0.name, group: $0.group, running: sessions[$0.name]?.started == true, hidden: $0.hidden) }
        let list = DeskGrid.choices(all, onScreen: onScreen.map(\.desk.name))
        if list.isEmpty {
            menu.addItem(NSMenuItem(title: visible == nil ? "No desk on screen" : (slots.count >= DeskGrid.most ? "The screen is full" : "No other desks"), action: nil, keyEquivalent: ""))
            return
        }
        var wasRunning = list.first?.running ?? false
        for c in list {
            if wasRunning && !c.running { menu.addItem(.separator()) }
            wasRunning = c.running
            let it = NSMenuItem(title: c.title, action: #selector(openBesideFromMenu(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.name
            menu.addItem(it)
        }
    }
    @objc func openBesideFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let i = deskIndex(name) else { return }
        openBeside(i)
    }

    /// Put a desk next to the ones on screen, starting it if need be. It
    /// goes after the desk that has the keys, and takes them.
    func openBeside(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        let d = desks[i]
        if let k = slots.firstIndex(where: { $0.session?.desk.name == d.name }) { focusSlot(k); return }
        guard visible != nil, DeskGrid.canAdd(d.name, onScreen: onScreen.map(\.desk.name)) else { NSSound.beep(); return }
        // A new place with the keys and nothing in it yet: show() fills it,
        // and finds no desk there to take off the screen.
        _ = addSlot(after: keySlot)
        keySlot += 1
        visible = nil
        show(i)
    }

    /// A tab's right-click menu: its desk's own, as in the list. For a desk
    /// that is on screen, putting it beside or peeking at it means nothing,
    /// and taking it off the screen does.
    func tabMenu(_ name: String) -> NSMenu? {
        guard let i = deskIndex(name), let m = sidebar.actionMenu(for: i) else { return nil }
        guard slots.contains(where: { $0.session?.desk.name == name }) else { return m }
        for it in m.items where it.title == "Open Beside" || it.title == "Peek" { m.removeItem(it) }
        if slots.count > 1 {
            let off = NSMenuItem(title: "Take Off Screen", action: #selector(takeOffFromMenu(_:)), keyEquivalent: "")
            off.target = self
            off.representedObject = name
            m.insertItem(off, at: 0)
            if m.items.count > 1, !m.items[1].isSeparatorItem { m.insertItem(.separator(), at: 1) }
        }
        while m.items.first?.isSeparatorItem == true { m.removeItem(at: 0) }
        return m
    }
    @objc func takeOffFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let k = slots.firstIndex(where: { $0.session?.desk.name == name }) else { return }
        closeSlot(k)
    }

    /// A new, empty place in the grid.
    @discardableResult
    func addSlot(after k: Int? = nil) -> DeskSlot {
        let slot = DeskSlot()
        Theme.paint(slot.view, Theme.ui.sidebar)
        slots.insert(slot, at: min((k ?? slots.count - 1) + 1, slots.count))
        deskSplit.set(slots.map(\.view))
        return slot
    }

    /// Draw `s` in a place, pinned to it.
    func mount(_ s: DeskSession, in slot: DeskSlot) {
        if let old = slot.session, old !== s { old.container.removeFromSuperview() }
        slot.session = s
        s.container.delegate = self
        s.container.translatesAutoresizingMaskIntoConstraints = false
        guard s.container.superview !== slot.view else { return }
        slot.view.addSubview(s.container)
        NSLayoutConstraint.activate([
            s.container.topAnchor.constraint(equalTo: slot.view.topAnchor),
            s.container.bottomAnchor.constraint(equalTo: slot.view.bottomAnchor),
            s.container.leadingAnchor.constraint(equalTo: slot.view.leadingAnchor),
            s.container.trailingAnchor.constraint(equalTo: slot.view.trailingAnchor),
        ])
    }

    /// Move the keys to the desk in place `k`. The list, the tabs, the
    /// explorer and the meter follow it, as they follow a desk you choose.
    func focusSlot(_ k: Int, takeKeys: Bool = true) {
        guard slots.indices.contains(k), let s = slots[k].session else { return }
        keySlot = k
        visible = s
        let d = s.desk
        lastVisited[d.name] = Date()
        if !steppingHistory { history.visit(d.name) }
        notifier.clear(desk: d.name)
        if ui.lastDesk != d.name { ui.lastDesk = d.name; ui.save() }
        syncPairFocus()
        meter.currentDesk = d.name
        watcher.start(root: d.resolvedCwd)
        tree.setRoot(d.resolvedCwd)
        if let i = deskIndex(d.name) { sidebar.select(i) }
        window.title = "Project Coldfall — \(d.name)"
        strip.setContext(d.name)
        updateTermHeader()
        if takeKeys { window.makeFirstResponder(s.focusedPane.terminal.view) }
    }

    /// Take the desk in place `k` off the screen. It keeps running. The
    /// last one stays: a window shows at least one desk.
    func closeSlot(_ k: Int) {
        guard slots.count > 1, slots.indices.contains(k) else { return }
        let hadKeys = k == keySlot
        if let s = slots[k].session {
            s.container.removeFromSuperview()
            s.isVisible = false
            s.setPair(false, key: true)
        }
        let next = DeskGrid.keyAfterRemoving(k, key: keySlot, count: slots.count)
        slots.remove(at: k)
        keySlot = next
        deskSplit.set(slots.map(\.view))
        if hadKeys || visible == nil { focusSlot(next) } else { syncPairFocus(); refreshTabs(sidebar.status) }
    }

    /// Take the desk that has the keys off the screen. It keeps running.
    @objc func closeBeside() {
        guard slots.count > 1 else { return }
        closeSlot(keySlot)
    }

    /// A pane header dragged over the grid: the place under the pointer is
    /// outlined, and letting go there makes the two desks change places.
    func headerDragged(_ s: DeskSession, to pt: NSPoint, dropped: Bool) {
        guard slots.count > 1, let from = slotIndex(of: s) else { return }
        let over = deskSplit.cell(at: pt).flatMap { $0 == from ? nil : $0 }
        guard dropped else { deskSplit.dropTarget = over; return }
        deskSplit.dropTarget = nil
        guard let to = over else { return }
        let keyDesk = slots[keySlot].session
        slots.swapAt(from, to)
        keySlot = slots.firstIndex { $0.session === keyDesk } ?? keySlot
        deskSplit.set(slots.map(\.view))
        refreshTabs(sidebar.status)
    }

    func gridSelfTest(_ names: [String]) {
        func say(_ what: String) {
            let on = slots.map { $0.session?.desk.name ?? "-" }
            let sizes = slots.map { "\(Int($0.view.frame.width))x\(Int($0.view.frame.height))" }
            let running = Set(sessions.filter { $0.value.started }.map(\.key))
            let row = DeskTabs.list(desks, current: visible?.desk.name, running: running, onScreen: onScreen.map(\.desk.name))
            let seen = onScreen.filter(\.isVisible).map(\.desk.name)
            print("grid: \(what): on screen \(on) keys \(visible?.desk.name ?? "-") tabs \(row) seen \(seen) title \(window.title) cells \(sizes)")
            fflush(stdout)
        }
        var steps: [(String, () -> Void)] = []
        say("start")
        for n in names { steps.append(("open \(n) beside", { [self] in if let i = deskIndex(n) { openBeside(i) } })) }
        if let first = slots.first?.session?.desk.name {
            steps.append(("choose \(first), already on screen", { [self] in if let i = deskIndex(first) { show(i) } }))
        }
        if let spare = desks.first(where: { d in !names.contains(d.name) && d.name != visible?.desk.name && !d.hidden }) {
            steps.append(("choose \(spare.name), not on screen", { [self] in if let i = deskIndex(spare.name) { show(i) } }))
        }
        steps.append(("drag the first onto the last", { [self] in
            guard let s = slots.first?.session, let last = slots.last else { return }
            let pt = last.view.convert(NSPoint(x: last.view.bounds.midX, y: last.view.bounds.midY), to: nil)
            headerDragged(s, to: pt, dropped: false)
            headerDragged(s, to: pt, dropped: true)
        }))
        // The menu bar is rebuilt whenever desks or keys change; twice here,
        // because a menu kept between builds raised on the second (0.3.43).
        steps.append(("rebuild the menu bar twice", { [self] in installMenu(); installMenu() }))
        // Every tab has its desk's right-click menu, also for a desk from a
        // group the list isn't showing.
        steps.append(("tab menus", { [self] in
            for s in onScreen {
                let titles = tabMenu(s.desk.name)?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
                print("grid: tab menu for \(s.desk.name): \(titles.count) items: \(titles.prefix(6))")
            }
        }))
        // Clicking a group is a look at its desks: the list changes, the
        // desks on screen do not.
        steps.append(("look at another group", { [self] in
            guard let other = desks.first(where: { $0.group != visible?.desk.group && !$0.hidden }) else { return }
            print("grid: the list showed \(sidebar.shownOrder)")
            sidebar.browse(other.group)
            print("grid: looking at \(other.group ?? "General"), the list shows \(sidebar.shownOrder)")
        }))
        steps.append(("take the one with the keys off", { [self] in closeBeside() }))
        steps.append(("take the first off", { [self] in closeSlot(0) }))
        var i = 0
        Timer.inEveryMode(withTimeInterval: 1.2, repeats: true) { t in
            guard i < steps.count else { t.invalidate(); print("grid: done"); fflush(stdout); exit(0) }
            steps[i].1(); say(steps[i].0); i += 1
        }
    }

    /// The focus outline on whichever desk has the keys, when there are several.
    func syncPairFocus() {
        let many = slots.count > 1
        for (k, sl) in slots.enumerated() { sl.session?.setPair(many, key: k == keySlot, beside: many) }
    }

    /// Put to sleep every desk that has earned it (see Hibernate). Checked
    /// every half minute; off unless Settings names a time.
    func sleepIdleDesks() {
        guard ui.sleepIdleMinutes > 0, !CommandLine.arguments.contains("--snapshot") else { return }
        let now = Date(), after = TimeInterval(ui.sleepIdleMinutes * 60)
        for d in desks {
            guard let s = sessions[d.name], slotIndex(of: s) == nil, !(peek.isOpen && peek.desk == d.name) else { continue }
            let f = Hibernate.Facts(runtime: d.runtime, resumes: d.resumesItself, running: s.started, visible: s.isVisible,
                                    activity: s.activity, lastOutput: s.lastOutput, lastKey: s.lastKey,
                                    panes: s.panes.count, draft: s.holdsDraft)
            guard Hibernate.shouldSleep(f, now: now, after: after) else { continue }
            if !ui.sleeping.contains(d.name) { ui.sleeping.append(d.name) }
            // Ended the way Stop Desk ends it, but not a "stopped" desk to
            // reopen: it is still yours, just resting.
            sessions.removeValue(forKey: d.name)
            memory.removeValue(forKey: d.name)
            s.terminateAll()
        }
        ui.sleeping.removeAll { n in !desks.contains { $0.name == n } }
        ui.save()
    }

    /// Remember a desk's folder as it is now, at the start of a turn. Off
    /// the main thread: on a big repository it takes a moment.
    func snapshotTurn(_ s: DeskSession) {
        guard s.desk.runtime != "shell", !snapshotting.contains(s.desk.name) else { return }
        let name = s.desk.name, folder = s.desk.resolvedCwd
        snapshotting.insert(name)
        DispatchQueue.global(qos: .utility).async {
            let tree = Changes.snapshot(in: folder)
            DispatchQueue.main.async { [weak self, weak s] in
                self?.snapshotting.remove(name)
                if let tree { s?.turnBase = tree }
            }
        }
    }
    var snapshotting: Set<String> = []

    /// Changes: what the desk on screen changed in its folder, to read and
    /// comment on.
    @objc func openChanges() {
        if changes.isOpen { changes.close(); return }
        guard let name = waitingName ?? visible?.desk.name, let d = desks.first(where: { $0.name == name }) else { NSSound.beep(); return }
        changes.open(over: window, desk: d.name, folder: d.resolvedCwd, turnBase: sessions[d.name]?.turnBase)
    }

    /// Needs You: the desks stopped on a question, to answer from one place.
    @objc func openFeed() { feed.toggle(over: window) }

    /// The desks waiting on an answer, longest wait first, each with the
    /// question read off its screen.
    func feedItems() -> [FeedPanel.Item] {
        sidebar.waiting.compactMap { name in
            guard let s = sessions[name], s.isBlocked, let d = desks.first(where: { $0.name == name }), !d.hidden else { return nil }
            let screen = s.screenText(lines: 60)
            let tail = screen.split(separator: "\n", omittingEmptySubsequences: true).suffix(10).joined(separator: "\n")
            return FeedPanel.Item(desk: name, runtime: d.runtime, icon: d.icon, reason: s.reason,
                                  prompt: Prompt.parse(screen: screen), tail: tail)
        }
    }

    /// Press an option in a waiting desk. Only while it is still asking,
    /// its agent is there, and that option is still what its screen offers.
    /// Nil when pressed; otherwise why not.
    func answer(desk name: String, with option: Prompt.Option) -> String? {
        guard let s = sessions[name], s.agentAlive() else { return "\(name) isn't running." }
        guard s.isBlocked else { return "\(name) isn't asking anything now." }
        guard let key = Prompt.key(for: option, on: s.screenText(lines: 60)) else {
            return "Its question has changed. Open the desk to answer."
        }
        s.typeOnBehalf(key)
        return nil
    }

    /// Memory per desk, sampled every five seconds from one `ps` call off the
    /// main thread. Cheap enough to leave on, and it answers "which desk is
    /// the heavy one" before you have to go looking in Activity Monitor.
    var memory: [String: String] = [:]
    var memoryTimer: Timer?
    func watchDeskMemory() {
        memoryTimer = Timer.inEveryMode(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Tailscale can come up after Coldfall, or change address.
            self.applyInbox()
            let roots = self.sessions.mapValues(\.pids)
            // Nothing running: nothing to show, rather than the last numbers.
            guard !roots.isEmpty else { self.memory = [:]; return }
            DispatchQueue.global(qos: .utility).async {
                let rows = ProcessTree.read()
                var m: [String: String] = [:]
                for (name, pids) in roots {
                    let kb = pids.reduce(0) { $0 + ProcessTree.totalKB(root: $1, in: rows) }
                    if let l = ProcessTree.label(kb: kb) { m[name] = l }
                }
                DispatchQueue.main.async {
                    // Only desks still running the same processes: one stopped,
                    // renamed or restarted meanwhile keeps no stale number.
                    self.memory = m.filter { name, _ in self.sessions[name].map { $0.pids == roots[name] } ?? false }
                }
            }
        }
    }

    // MARK: - panes

    @objc func splitRight() { addPane(vertical: true) }
    @objc func splitDown()  { addPane(vertical: false) }

    /// A desk keeps one axis. The first split chooses it; a later split in the
    /// other direction joins the existing one rather than nesting, and says so
    /// once instead of silently doing something else than the menu promised.
    func addPane(vertical: Bool) {
        guard let s = activeSession else { return }
        if s.panes.count > 1 && s.isVertical != vertical && !warnedAboutAxis {
            warnedAboutAxis = true
            let a = NSAlert()
            a.messageText = "This desk is already split \(s.isVertical ? "into columns" : "into rows")"
            a.informativeText = "Panes in a desk share one axis, so this one joins the "
                + "existing split instead of nesting inside a pane.\n\n"
                + "Nested splits are on the roadmap if people want them."
            a.addButton(withTitle: "OK")
            a.runModal()
        }
        guard s.split(vertical: vertical) != nil else {
            NSSound.beep(); return          // four panes is the ceiling
        }
        updateTermHeader()
        window.makeFirstResponder(s.focusedPane.terminal.view)
    }
    var warnedAboutAxis = false

    /// Closing a pane kills its process. For a shell that costs nothing; for the
    /// agent it throws away a session that may have been running for hours, so
    /// that one asks.
    @objc func closePane() {
        // cmd-w closes the innermost thing, the way every terminal does it: the
        // pane if there is more than one, otherwise the window. Beeping here
        // instead would quietly take cmd-w away from closing the window at all.
        // The second desk's only pane: off the screen, still running.
        if slots.count > 1, let v = visible, v.panes.count < 2 { closeBeside(); return }
        guard let s = activeSession, s.panes.count > 1 else {
            window.performClose(nil); return
        }
        if s.focusedPane.isAgent {
            let a = NSAlert()
            a.messageText = "Close the agent pane?"
            a.informativeText = "This is \(s.desk.name)'s own session, not a shell. "
                + "Closing it ends the agent and loses its context. The other panes stay."
            a.addButton(withTitle: "Close Agent")
            a.addButton(withTitle: "Cancel")
            a.buttons.first?.hasDestructiveAction = true
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        _ = s.closeFocused()
        updateTermHeader()
        window.makeFirstResponder(s.focusedPane.terminal.view)
    }

    /// One pane filling the desk; again to bring the others back.
    @objc func zoomPane() {
        guard let s = activeSession else { return }
        s.toggleZoom()
        window.makeFirstResponder(s.focusedPane.terminal.view)
    }
    @objc func nextPane() { cyclePane(1) }
    @objc func prevPane() { cyclePane(-1) }
    func cyclePane(_ d: Int) {
        guard let s = activeSession, s.panes.count > 1 else { return }
        s.cycleFocus(d)
        window.makeFirstResponder(s.focusedPane.terminal.view)
    }

    /// Clicking a pane focuses it. SwiftTerm takes first responder itself, so
    /// this only has to keep the ring in step with where the keystrokes go.
    func watchPaneClicks() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] ev in
            guard let self, ev.window === self.window else { return ev }
            let pt = ev.locationInWindow
            for s in self.onScreen {
                for (i, p) in s.panes.enumerated()
                where p.box.superview != nil
                    && p.box.convert(p.box.bounds, to: nil).contains(pt) {
                    if s.panes.count > 1 { s.focus(i) }
                    // With several desks on screen, the one clicked has the
                    // keys, and the list and the tabs follow it.
                    if s !== self.visible, let k = self.slotIndex(of: s) { self.focusSlot(k, takeKeys: false) }
                    return ev
                }
            }
            return ev
        }
    }
    var clickMonitor: Any?

    var meterPanel: MeterPanel?
    @objc func openMeter() {
        if meterPanel == nil { meterPanel = MeterPanel() } else { meterPanel?.reload() }
        meterPanel?.showWindow(nil)
        meterPanel?.window?.makeKeyAndOrderFront(nil)
    }

    var mailPanel: MailboxPanel?
    @objc func openMailbox() {
        let from = visible?.desk.name ?? "you"
        let cwd = visible?.desk.resolvedCwd ?? NSHomeDirectory()
        if mailPanel == nil { mailPanel = MailboxPanel(cwd: cwd, from: from) }
        mailPanel?.showWindow(nil)
        mailPanel?.window?.makeKeyAndOrderFront(nil)
    }

    /// Desks above the tree, or the tree above the desks. Persisted.
    func applyRailOrder() {
        rail.arrangedSubviews.forEach { rail.removeArrangedSubview($0); $0.removeFromSuperview() }
        if ui.treeOnTop {
            rail.addArrangedSubview(tree); rail.addArrangedSubview(deskScroll)
        } else {
            rail.addArrangedSubview(deskScroll); rail.addArrangedSubview(tree)
        }
        // Re-seated views keep their old frames until the split view lays
        // them out again, which it doesn't do on its own: cmd-T swapped the
        // order and nothing on screen moved.
        rail.adjustSubviews()
        rail.needsDisplay = true
    }

    @objc func toggleTreePosition() {
        ui.treeOnTop.toggle(); ui.save()
        applyRailOrder()
        fitRail()
    }

    func toggleGroup(_ g: String) {
        if sidebar.collapsed.contains(g) { sidebar.collapsed.remove(g) } else { sidebar.collapsed.insert(g) }
        ui.collapsed = Array(sidebar.collapsed); ui.save()
        sidebar.build(desks: desks)
    }

    /// Renaming writes back to the config, so the change survives a restart.
    func renameGroup(_ g: String) {
        let a = NSAlert()
        a.messageText = "Rename group"
        a.informativeText = "Renames it in ~/.config/coldfall/desks.toml."
        a.addButton(withTitle: "Rename"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.stringValue = g
        a.accessoryView = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let new = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != g else { return }

        if let text = try? String(contentsOfFile: DeskConfig.path, encoding: .utf8) {
            let updated = text.replacingOccurrences(of: "group = \"\(g)\"", with: "group = \"\(new)\"")
            try? updated.write(toFile: DeskConfig.path, atomically: true, encoding: .utf8)
        }
        for i in desks.indices where desks[i].group == g { desks[i].group = new }
        if sidebar.collapsed.remove(g) != nil { sidebar.collapsed.insert(new) }
        ui.collapsed = Array(sidebar.collapsed); ui.save()
        sidebar.build(desks: desks)
    }

    // MARK: - the reader: a pane by default, its own window when popped out

    var readerWindow: NSWindow?
    private let readerWindowBox = NSView()

    /// Pin a view to every edge of a container.
    private func mount(_ v: NSView, in box: NSView) {
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: box.topAnchor),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
    }

    private func ensureReaderWindow() {
        guard readerWindow == nil else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.contentView = readerWindowBox
        w.title = "Files"
        Theme.apply(to: w)
        w.isReleasedWhenClosed = false
        w.delegate = self
        if let main = window {
            w.setFrameOrigin(NSPoint(x: main.frame.maxX + 12, y: main.frame.origin.y))
        }
        readerWindow = w
    }

    /// Put the reader back in the pane beside the terminal.
    func dockReader(show: Bool) {
        mount(reader, in: readerPane)
        reader.poppedOut = false
        readerWindow?.orderOut(nil)       // orderOut, not close: close would re-enter here
        ui.readerPoppedOut = false
        setReaderPaneHidden(!show)
    }

    /// Move the reader into its own window — for a second screen.
    func popOutReader() {
        ensureReaderWindow()
        mount(reader, in: readerWindowBox)
        reader.poppedOut = true
        ui.readerPoppedOut = true
        // The pane collapses, but the user's hidden/shown preference is left
        // alone so docking back restores it.
        placeReaderPane(shown: false)
        ui.save()
        refreshToggles()
        readerWindow?.makeKeyAndOrderFront(nil)
    }

    /// Closing the popped-out window docks the reader back rather than
    /// throwing its tabs away. It comes back hidden: closing meant "out of the
    /// way", and cmd-opt-B shows it again.
    func windowWillClose(_ n: Notification) {
        guard (n.object as? NSWindow) === readerWindow, reader.poppedOut else { return }
        DispatchQueue.main.async { self.dockReader(show: false) }
    }

    func openReader(_ url: URL) {
        reader.open(url)
        if reader.poppedOut {
            ensureReaderWindow()
            readerWindow?.makeKeyAndOrderFront(nil)
        } else if readerPane.isHidden {
            setReaderPaneHidden(false)    // opening a file on purpose shows the reader
        }
    }

    // MARK: - layout toggles: cmd-B, cmd-opt-B, cmd-J — VS Code's keys

    @objc func toggleRail() {
        rail.isHidden.toggle()
        ui.railHidden = rail.isHidden
        ui.save()
        split.adjustSubviews()
        split.needsDisplay = true
        refreshToggles()
    }

    @objc func toggleReader() {
        if reader.poppedOut { dockReader(show: true); return }
        setReaderPaneHidden(!readerPane.isHidden)
    }

    func setReaderPaneHidden(_ h: Bool) {
        placeReaderPane(shown: !h)
        ui.readerHidden = h
        ui.save()
        refreshToggles()
    }

    /// The reader's width when it was last on screen, to put it back at.
    private var readerWidth: CGFloat = 0

    /// Put the reader pane in the split, or take it out.
    ///
    /// Hiding it in place was not enough: the split view kept drawing the
    /// divider for the hidden pane where it used to be, a dark line down the
    /// middle of the terminal. Out of the split, there is no divider to draw.
    func placeReaderPane(shown: Bool) {
        readerPane.isHidden = !shown
        let inSplit = readerPane.superview === split
        if !shown, inSplit {
            if readerPane.frame.width > 0 { readerWidth = readerPane.frame.width }
            split.removeArrangedSubview(readerPane)
            readerPane.removeFromSuperview()
            split.adjustSubviews()
        } else if shown, !inSplit {
            split.addArrangedSubview(readerPane)
            split.adjustSubviews()
            let w = split.bounds.width
            let want = readerWidth > 0 ? readerWidth : max(300, min(520, w * 0.34))
            split.setPosition(w - want, ofDividerAt: 1)
        } else {
            split.adjustSubviews()
        }
        split.needsDisplay = true
    }

    @objc func toggleMeter() {
        let h = !meter.isHidden
        meter.isHidden = h
        meterZero.isActive = h
        ui.meterHidden = h
        ui.save()
        refreshToggles()
    }

    @objc func popOutOrDock() {
        if reader.poppedOut { dockReader(show: true) } else { popOutReader() }
    }

    func refreshToggles() {
        strip.setShowing(rail: !rail.isHidden,
                         reader: reader.poppedOut || !readerPane.isHidden,
                         meter: !meter.isHidden)
    }

    /// Restore the layout the user left, from ui.json.
    func applySavedLayout() {
        rail.isHidden = ui.railHidden
        meter.isHidden = ui.meterHidden
        meterZero.isActive = ui.meterHidden
        mount(reader, in: readerPane)
        if ui.readerPoppedOut {
            popOutReader()
        } else {
            placeReaderPane(shown: !ui.readerHidden)
        }
        split.adjustSubviews()
        refreshToggles()
    }

    // MARK: - quick open (cmd-P)

    /// A look at a running desk over the current one (see PeekPanel).
    func peekDesk(_ i: Int) {
        guard desks.indices.contains(i), let s = sessions[desks[i].name], s.started, s !== visible else { return }
        s.notePeeked()
        peek.open(over: window, desk: desks[i].name, session: s)
    }

    @objc func openPalette() {
        if palette.isOpen { palette.close(); return }
        let root = visible?.desk.resolvedCwd ?? NSHomeDirectory()
        palette.open(over: window, desks: desks, root: root)
    }

    /// ⌘⇧P: quick open already asking for commands.
    @objc func openCommands() {
        if palette.isOpen { palette.close(); return }
        let root = visible?.desk.resolvedCwd ?? NSHomeDirectory()
        palette.open(over: window, desks: desks, root: root, query: "> ")
    }

    /// The tabs and the pane headers follow the desk on screen.
    func updateTermHeader() {
        visible?.refreshHeaders()
        refreshTabs(sidebar.status)
    }

    /// The desk in a --snapshot, which starts no session to be visible.
    var snapDesk: String?

    /// The tab row: the running desks in the on-screen desk's group, and the
    /// desk beside it wherever that one lives.
    func refreshTabs(_ status: [String: DeskStatus]) {
        let current = waitingName ?? visible?.desk.name ?? snapDesk
        let running = Set(status.filter { $0.value.running }.map(\.key))
        let names = DeskTabs.list(desks, current: current, running: running, onScreen: onScreen.map(\.desk.name))
        let list: [TabBar.Tab] = names.compactMap { n in
            guard let d = desks.first(where: { $0.name == n }) else { return nil }
            return TabBar.Tab(name: n, runtime: d.runtime, icon: d.icon, status: status[n] ?? DeskStatus(), color: d.color)
        }
        tabs.set(list, current: current)
    }

    /// "+" on the tab row: this group's stopped desks, then a new shell desk.
    func tabPlusMenu() -> NSMenu {
        let m = NSMenu()
        let current = waitingName ?? visible?.desk.name
        let running = Set(sessions.filter { $0.value.started }.map(\.key))
        for n in DeskTabs.startable(desks, current: current, running: running) {
            guard let d = desks.first(where: { $0.name == n }) else { continue }
            let item = NSMenuItem(title: "Start \(n)", action: #selector(startFromTabs(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = n
            item.image = VendorIcon.image(runtime: d.runtime, icon: d.icon, size: 14)
            m.addItem(item)
        }
        if !m.items.isEmpty { m.addItem(.separator()) }
        let shell = NSMenuItem(title: "New Shell Desk", action: #selector(newShellDesk), keyEquivalent: "")
        shell.target = self
        m.addItem(shell)
        return m
    }

    @objc func startFromTabs(_ item: NSMenuItem) {
        guard let n = item.representedObject as? String, let i = deskIndex(n) else { return }
        show(i)
    }

    // LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    /// An agent's terminal title is its own word for what it is working on.
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let s = sessions.values.first(where: { $0.agent.view === source && !$0.agentGone }) else { return }
        s.title = DeskDetail.title(title, desk: s.desk.name, runtime: s.desk.runtime)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { paneExited(source) }

    /// A pane's program ended, whichever terminal drew it.
    func paneExited(_ source: NSView) {
        // A desk exiting is not the app exiting, and a PANE exiting is not the
        // desk exiting. Typing `exit` in a shell pane should close that pane and
        // leave the agent next to it untouched.
        guard let entry = sessions.first(where: { s in
            s.value.panes.contains(where: { $0.terminal.view === source })
        }) else { return }

        if entry.value.panes.count > 1 {
            // The agent pane going leaves a shell that must not be mistaken
            // for the agent by Wrap Up or "run this in the desk".
            if entry.value.panes.first?.terminal.view === source { entry.value.agentGone = true }
            entry.value.drop(view: source)
            if entry.value === visible {
                updateTermHeader()
                window.makeFirstResponder(entry.value.focusedPane.terminal.view)
            }
            return
        }
        if slots.count > 1, let k = slotIndex(of: entry.value) { closeSlot(k) }
        sessions.removeValue(forKey: entry.key)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool {
        ExitLog.note("the last window closed: quitting follows")
        return true
    }

    /// The question itself, apart so a snapshot can draw it.
    func quitAlert(_ held: [String]) -> NSAlert {
        let t = QuitPrompt.text(desks: held)
        let alert = NSAlert()
        alert.messageText = t.title
        alert.informativeText = t.body
        alert.addButton(withTitle: t.keep)
        alert.addButton(withTitle: t.end)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[2].keyEquivalent = "\u{1b}"
        return alert
    }

    /// Quitting with held desks running asks whether they keep going. Keep
    /// is the default: it's the point of holding them. Nothing to ask when
    /// no desk is held, or when an update is relaunching Coldfall, which
    /// keeps them.
    func applicationShouldTerminate(_ a: NSApplication) -> NSApplication.TerminateReply {
        let held = desks.map(\.name).filter { n in
            guard let s = sessions[n], s.started, s.isHeld else { return false }
            return Holder.isHeld(desk: n)
        }
        guard !held.isEmpty, !SelfUpdate.relaunching else {
            ExitLog.leaving(SelfUpdate.relaunching ? "quit to relaunch after an update" : "quit, no held desks to ask about")
            return .terminateNow
        }
        ExitLog.note("quit asked for, \(held.count) held desks: showing the keep or end question")
        switch quitAlert(held).runModal() {
        case .alertFirstButtonReturn:
            ExitLog.leaving("quit: desks kept running")
            return .terminateNow
        case .alertSecondButtonReturn:
            ExitLog.leaving("quit: \(held.count) held desks ended, by the answer to the question")
            for n in held { Holder.end(desk: n) }
            // Ended on purpose: nothing to offer back next time.
            ui.runningDesks.removeAll { held.contains($0) }
            ui.save()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

MainActor.assumeIsolated {
    // Move state from the old Deskwork paths BEFORE anything else runs.
    //
    // It cannot live in applicationDidFinishLaunching: Controller's stored
    // properties (UIState among them) load the moment it is constructed, which
    // is earlier. Reading the new path before migration finds nothing, the
    // first save CREATES the new directory, and migration then sees two real
    // directories, reports a conflict and does nothing — so every desk the user
    // had would appear to be gone.
    for (path, outcome) in Migration.runAll() {
        switch outcome {
        case .migrated:        NSLog("Project Coldfall: moved \(path), left a link behind")
        case .conflict:        NSLog("Project Coldfall: both \(path) and its new home exist; left both alone")
        case .failed(let why): NSLog("Project Coldfall: migration problem: \(why)")
        case .nothing, .alreadyDone: break
        }
    }

    let app = NSApplication.shared
    // Before any window exists, so none of them is ever drawn in the wrong
    // appearance first and then repainted.
    Theme.applyGlobally()
    let c = Controller()
    app.delegate = c
    app.setActivationPolicy(.regular)
    withExtendedLifetime(c) { app.run() }
}

extension Notification.Name {
    /// desks.toml was reloaded; open windows showing desks should refresh.
    static let coldfallDesksReloaded = Notification.Name("coldfallDesksReloaded")
    /// Settings changed something the controller keeps in ui.json.
    static let coldfallFreshStartChanged = Notification.Name("coldfallFreshStartChanged")
    static let coldfallKeepRunningChanged = Notification.Name("coldfallKeepRunningChanged")
    static let coldfallSleepChanged = Notification.Name("coldfallSleepChanged")
    static let coldfallTerminalChanged = Notification.Name("coldfallTerminalChanged")
    static let coldfallNotifyChanged = Notification.Name("coldfallNotifyChanged")
    static let coldfallInboxChanged = Notification.Name("coldfallInboxChanged")
    static let coldfallReopenSettings = Notification.Name("coldfallReopenSettings")
    /// Settings asked for the Remove Files dialog, which the controller owns.
    static let coldfallOpenUninstall = Notification.Name("coldfallOpenUninstall")
    static let coldfallConfirmStartChanged = Notification.Name("coldfallConfirmStartChanged")
}
