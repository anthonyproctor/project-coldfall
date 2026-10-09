// Splits — more than one terminal per desk.
//
// A desk is one agent. Real work wants a second view of the same directory:
// the agent in one pane, a shell in the other to look at what it just did.
//
// Panes are NOT desks, and the difference is the whole design. A desk is
// configured, named, metered and durable. A pane is a way of looking at one,
// has no config, and dies with the window. Pane 0 runs the desk's own command;
// every other pane is a plain login shell in the same cwd.
//
// One orientation per desk rather than a nested tree. Nesting doubles the
// interaction surface — which pane splits which way, how focus traverses,
// where a new pane lands — to serve a layout nobody has asked for yet. If
// somebody does, it is an issue with a thumbs-up on it.

import AppKit
import SwiftTerm
import ColdfallCore

// MARK: - knowing a desk answered

// `DeskActivity` and its timing live in ColdfallCore, under test.

/// A terminal that reports when its process writes something.
///
/// `dataReceived` is the only honest signal available. A CLI does not announce
/// "I have finished answering"; all that reaches us is bytes, so "finished"
/// has to be inferred from bytes stopping.
final class DeskTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?
    /// Something was sent into the desk: a keystroke, a paste, a drop.
    var onInput: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?()
        super.send(source: source, data: data)
    }

    // MARK: - getting a file INTO the conversation
    //
    // SwiftTerm has no drag support at all, so dropping a file on a desk did
    // nothing. Every real terminal inserts the path instead, and in a tool
    // built for talking to agents that is not a nicety: showing an agent a
    // screenshot means handing it a path, and there was no way to produce one
    // without leaving the app.

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !urls(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = urls(from: sender).map { ShellPath.escape(DeskTerminalView.stable($0).path) }
        guard !paths.isEmpty else { return false }
        // A trailing space, so a second drop does not glue two paths together
        // and so the path is finished as an argument either way.
        send(txt: paths.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }

    /// A dropped file that macOS is about to delete gets copied somewhere it
    /// will not.
    ///
    /// Dragging the floating screenshot thumbnail hands over a path inside
    /// .../TemporaryItems/NSIRD_screencaptureui_*, which macOS removes within
    /// seconds. The path was typed correctly and was already dead by the time
    /// anything read it — reported as two screenshots that simply vanished.
    /// Anything under the per-user temp tree is treated the same way, since
    /// none of it is promised to survive.
    static func stable(_ url: URL) -> URL {
        let p = url.path
        let temp = NSTemporaryDirectory()
        let doomed = p.contains("/TemporaryItems/") || p.contains("NSIRD_screencaptureui")
            || (!temp.isEmpty && p.hasPrefix(temp))
        guard doomed else { return url }

        let dir = NSString(string: "~/.local/share/coldfall/pasted").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        // Keep the original name's extension; drop macOS's narrow no-break
        // spaces and ordinary spaces so the pasted path needs no escaping.
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let dest = URL(fileURLWithPath: dir)
            .appendingPathComponent("dropped-\(f.string(from: Date()))\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return url          // copy failed: the original is still better than nothing
        }
    }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Paste, with one addition: an IMAGE on the clipboard becomes a file and
    /// the path is pasted instead.
    ///
    /// cmd-ctrl-shift-4 puts a screenshot on the clipboard and nowhere else, so
    /// without this the fastest way to capture something is also the one way
    /// you cannot hand it to an agent. Text pasting is untouched.
    override func paste(_ sender: Any) {
        guard let path = DeskTerminalView.imageFileFromClipboard() else {
            super.paste(sender)
            return
        }
        send(txt: ShellPath.escape(path) + " ")
    }

    /// Write a clipboard image to disk and return its path. Nil when the
    /// clipboard holds no image, which is the ordinary case.
    static func imageFileFromClipboard() -> String? {
        let pb = NSPasteboard.general
        // A file COPIED in Finder is already a path; let normal paste have it.
        if pb.canReadObject(forClasses: [NSURL.self],
                            options: [.urlReadingFileURLsOnly: true]) { return nil }
        guard let img = NSImage(pasteboard: pb),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }

        let dir = NSString(string: "~/.local/share/coldfall/pasted").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let path = (dir as NSString)
            .appendingPathComponent("pasted-\(f.string(from: Date())).png")
        guard (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return nil }
        return path
    }

    // Path escaping lives in ColdfallCore/ShellPath, under test.
}

// MARK: - a pane

/// A single terminal inside a desk, wrapped in a box that can show focus.
final class Pane {
    let term: DeskTerminalView
    let box: PaneBox
    /// Pane 0 runs the desk's CLI. The rest are shells, and closing one is free.
    let isAgent: Bool
    private(set) var started = false

    init(isAgent: Bool) {
        self.isAgent = isAgent
        term = DeskTerminalView(frame: .zero)
        term.translatesAutoresizingMaskIntoConstraints = false
        Theme.apply(to: term)
        box = PaneBox(term: term)
    }

    /// End this pane's shell and everything running in it. The tree is read
    /// before the terminal lets go of the shell, or there is no root to find.
    func end() {
        let root = term.process?.shellPid ?? 0
        let tree = root > 0 ? ProcessTree.descendants(of: root, in: ProcessTree.read()) : []
        term.terminate()
        ProcessTree.end(tree)
    }

    /// Launch the process. `command` is nil for a shell pane, which just lands
    /// in the directory and waits.
    func start(desk: Desk, command: String?) {
        guard !started else { return }
        started = true

        if let command {
            // A CLI can take several seconds to boot. Paint something
            // immediately, written straight to the view rather than through the
            // pty, so a blank screen never reads as "nothing happened".
            term.feed(text: "\u{1b}[2J\u{1b}[H"
                + "\u{1b}[36m●\u{1b}[0m starting \u{1b}[1m\(desk.name)\u{1b}[0m\r\n"
                + "\u{1b}[2m  \(command)\r\n"
                + "  in \(desk.resolvedCwd)\u{1b}[0m\r\n\r\n")
        }

        term.startProcess(executable: "/bin/zsh", args: ["-l"],
                          environment: Pane.environment(for: desk))

        // Land in the desk's directory, then launch its CLI. No `clear` here —
        // wiping the screen would throw away the only feedback there is.
        // Quoted whole: a folder name can hold ; $() or a newline, and only
        // escaping spaces let those run as commands.
        let dir = Shell.quote(desk.resolvedCwd)
        let line = command.map { "cd \(dir) && \($0)\n" } ?? "cd \(dir)\n"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.term.send(txt: line)
        }
    }

    /// Coldfall hands its own environment to every desk, so anything the app
    /// inherited is inherited again by the agent. CLAUDECODE marks "you are
    /// already inside a Claude Code session" and makes a nested one refuse to
    /// start — which happens whenever Coldfall is launched from a terminal that
    /// is itself running an agent. Scrub it rather than depending on how the app
    /// was launched.
    static func environment(for desk: Desk) -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let poison = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
                      "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_BRIDGE_SESSION_ID",
                      "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
                      "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_PID", "CLAUDE_EFFORT"]
        env.removeAll { entry in poison.contains(where: { entry.hasPrefix($0 + "=") }) }
        // Hooks and desk-scoped behaviour key off this, same as the shell wrapper.
        env.append("CLAUDE_DESK=\(desk.name)")
        env.append("COLDFALL=1")
        // For a desk whose own command starts Claude: the trimmed servers,
        // for it to pass on (see McpTrim). Built-in desks get the flag directly.
        if let s = McpTrim.settingsJSON(off: desk.mcpOff) { env.append("\(McpTrim.envKey)=\(s)") }
        return env
    }
}

// MARK: - the focus ring

/// Holds one terminal and draws a ring around it when it has focus.
///
/// The ring only appears once a desk has more than one pane. A border around a
/// single pane is noise — there is nowhere else the keystrokes could go.
final class PaneBox: NSView {
    private let ring: CGFloat = 2
    var showsFocus = false { didSet { if showsFocus != oldValue { restyle() } } }
    var focused = true { didSet { if focused != oldValue { restyle() } } }
    private weak var term: NSView?

    init(term: NSView) {
        super.init(frame: .zero)
        self.term = term
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        addSubview(term)

        // Text butting against the frame is the first thing that makes a
        // terminal feel cheap, and the box rather than the terminal owns the
        // gap so the terminal's own background still fills it.
        let cfg = DeskConfig.themeSettings()
        let x = CGFloat(cfg.padX), y = CGFloat(cfg.padY)
        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: topAnchor, constant: y),
            term.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -y),
            term.leadingAnchor.constraint(equalTo: leadingAnchor, constant: x),
            term.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -x),
        ])
        layer?.backgroundColor = Theme.current().skin.terminal.background.cgColor
    }
    required init?(coder: NSCoder) { nil }

    /// Dim the unfocused pane rather than only ringing the focused one. Ghostty
    /// does this (`unfocused-split-opacity`) and it reads faster: the eye finds
    /// the bright pane without looking for a border.
    private func restyle() {
        alphaValue = (showsFocus && !focused) ? 0.72 : 1.0
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        Theme.current().skin.terminal.background.setFill()
        bounds.fill()
        guard showsFocus, focused else { return }
        let r = bounds.insetBy(dx: ring / 2, dy: ring / 2)
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        let p = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        p.lineWidth = ring
        p.stroke()
    }
}

// MARK: - a desk's panes

/// One live desk: its panes, which one has focus, and the split view holding them.
final class DeskSession {
    /// A var so a rename reaches a desk that is already running. The launch
    /// command was read when it started, so the running process is unaffected.
    var desk: Desk
    /// Every pane reports process exit to the same delegate, so a shell pane
    /// closing is handled the same way the agent's own exit is.
    weak var processDelegate: LocalProcessTerminalViewDelegate? {
        didSet { for p in panes { p.term.processDelegate = processDelegate } }
    }
    private(set) var panes: [Pane] = []
    private(set) var focused = 0
    /// Columns when vertical, rows when not. Set by the first split and kept.
    private(set) var isVertical = true

    /// The view to put on screen. A single pane is shown bare; a split view is
    /// only introduced once there is something to divide.
    let container = NSSplitView()

    init(desk: Desk) {
        self.desk = desk
        container.translatesAutoresizingMaskIntoConstraints = false
        container.dividerStyle = .thin
        container.isVertical = true
        panes.append(Pane(isAgent: true))
        rebuild()
        wireOutput()
    }

    /// The agent's terminal — where a routed command goes, regardless of which
    /// pane the user happens to be looking at.
    var agentTerm: DeskTerminalView { panes[0].term }

    /// Inferring "finished" from output stopping is fiddly enough to be worth
    /// testing, so the rule lives in ColdfallCore rather than here.
    private var activityState = ActivityState()

    var isVisible: Bool {
        get { activityState.visible }
        set {
            if activityState.visible, !newValue { hiddenScreen = screen() }
            activityState.setVisible(newValue)
        }
    }

    /// The screen as it was when the desk went out of view.
    private var hiddenScreen: [String]?
    /// Whether this burst of hidden output has been checked against it.
    private var screenChecked = false

    func noteOutput() { activityState.noteOutput(); screenChecked = false }
    func noteInput() { activityState.noteInput() }

    /// The agent terminal's live screen as text, wherever you have scrolled
    /// to. See ScreenChange.liveRows.
    func screen() -> [String] {
        let t = agentTerm.getTerminal()
        return ScreenChange.liveRows(buffer: String(decoding: t.getBufferAsData(), as: UTF8.self), rows: t.rows)
    }

    /// Once a desk has gone quiet and would show as waiting: if its screen
    /// is what it was when you left, the output was a repaint, not news.
    func dropRepaint() {
        guard !screenChecked, case .ready = activity, let before = hiddenScreen else { return }
        screenChecked = true
        if !ScreenChange.meaningful(before: before, after: screen()) { markSeen() }
    }
    func markSeen() { activityState.markSeen() }

    /// What the rail should draw right now.
    var activity: DeskActivity { activityState.activity() }
    /// When this desk last wrote anything, for the rail's "2m".
    var lastOutput: Date? { activityState.lastOutput }
    var focusedPane: Pane { panes[min(focused, panes.count - 1)] }
    var started: Bool { panes[0].started }

    /// Every pane's process id, for measuring the desk's memory.
    var pids: [Int32] { panes.compactMap { $0.started ? $0.term.process?.shellPid : nil } }

    /// End every pane's process. The session is finished after this.
    func terminateAll() {
        ended = true
        for p in panes where p.started { p.end() }
    }

    /// Finding the conversation to reopen reads session files, which can be
    /// many on a busy Mac, so it happens off the main thread. A desk stopped
    /// in the meantime is not started when the answer comes back.
    private var resolving = false
    private var ended = false

    /// Waiting on the person: whether to resume or start fresh. Nothing
    /// starts while this is set, so a second click can't start it twice.
    var holding = false
    /// The agent pane exited while a shell pane stayed. What's left is a
    /// shell, not the agent, whatever agentTerm now points at.
    var agentGone = false

    func startIfNeeded() {
        guard !started, !resolving, !holding else { return }
        let d = desk
        guard d.resumesItself else { startPanes(d.launchCommand()); return }
        resolving = true
        DispatchQueue.global(qos: .userInitiated).async {
            let cmd = d.resumingLaunchCommand()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resolving = false
                if !self.ended { self.startPanes(cmd) }
            }
        }
    }

    /// Start with a new conversation instead of the one on disk.
    func startFresh(_ command: String) {
        guard !started, !resolving, !holding, !ended else { return }
        startPanes(command)
    }

    private func startPanes(_ command: String) {
        panes[0].start(desk: desk, command: command)
        for p in panes.dropFirst() { p.start(desk: desk, command: nil) }
    }

    /// Add a pane. The first split picks the orientation for the desk; later
    /// ones join it, because a desk has one axis rather than a tree.
    @discardableResult
    func split(vertical: Bool) -> Pane? {
        // Four is where panes stop being useful and start being a mosaic.
        guard panes.count < 4 else { return nil }
        if panes.count == 1 { isVertical = vertical; container.isVertical = vertical }
        let p = Pane(isAgent: false)
        p.term.processDelegate = processDelegate
        p.term.onOutput = { [weak self] in self?.noteOutput() }
        p.term.onInput = { [weak self] in self?.noteInput() }
        panes.insert(p, at: focused + 1)
        focused += 1
        rebuild()
        p.start(desk: desk, command: nil)
        return p
    }

    /// Close a pane, killing its process. Refuses the last one — a desk with no
    /// terminal is managed from the desk list, not from here.
    @discardableResult
    func closeFocused() -> Bool {
        guard panes.count > 1 else { return false }
        let p = panes.remove(at: focused)
        p.end()
        p.box.removeFromSuperview()
        focused = min(focused, panes.count - 1)
        rebuild()
        return true
    }

    func focus(_ i: Int) {
        guard panes.indices.contains(i) else { return }
        focused = i
        markFocus()
    }

    /// Move focus by one, wrapping. `cmd-[` and `cmd-]`.
    func cycleFocus(_ delta: Int) {
        guard panes.count > 1 else { return }
        focus((focused + delta + panes.count) % panes.count)
    }

    /// Focus whichever pane owns this terminal. Used when a click lands in one.
    func focusPane(owning term: TerminalView) -> Bool {
        guard let i = panes.firstIndex(where: { $0.term === term }) else { return false }
        focus(i)
        return true
    }

    func drop(term: TerminalView) {
        guard let i = panes.firstIndex(where: { $0.term === term }) else { return }
        guard panes.count > 1 else { return }   // the desk itself dying is handled above
        panes[i].box.removeFromSuperview()
        panes.remove(at: i)
        focused = min(focused, panes.count - 1)
        rebuild()
    }

    /// Any pane writing counts as the desk writing — a shell pane finishing a
    /// build is as worth knowing about as the agent answering.
    private func wireOutput() {
        for p in panes {
            p.term.onOutput = { [weak self] in self?.noteOutput() }
            p.term.onInput = { [weak self] in self?.noteInput() }
        }
    }

    private func rebuild() {
        for v in container.arrangedSubviews { container.removeArrangedSubview(v) }
        for p in panes { container.addArrangedSubview(p.box) }
        markFocus()
    }

    private func markFocus() {
        let many = panes.count > 1
        for (i, p) in panes.enumerated() {
            p.box.showsFocus = many
            p.box.focused = (i == focused)
        }
    }
}
