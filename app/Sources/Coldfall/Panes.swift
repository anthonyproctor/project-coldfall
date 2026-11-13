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
    var onInput: (([UInt8]) -> Void)?
    /// The program reported its status over OSC 7501 (see ProgramStatus).
    var onStatus: ((ProgramStatus.Report) -> Void)?
    /// A plain terminal notification (OSC 9, 99, 777), as its message.
    var onNotice: ((String) -> Void)?

    /// Listen for OSC 7501. Called once the terminal exists.
    func listenForStatus() {
        getTerminal().registerOscHandler(code: 7501) { [weak self] data in
            guard let r = ProgramStatus.parse(String(decoding: data, as: UTF8.self)) else { return }
            self?.onStatus?(r)
        }
        // Plain terminal notifications, from agents that speak neither the
        // hook nor 7501 (see TerminalNotice).
        for code in [9, 99, 777] {
            getTerminal().registerOscHandler(code: code) { [weak self] data in
                guard let m = TerminalNotice.message(code: code, payload: String(decoding: data, as: UTF8.self)) else { return }
                self?.onNotice?(m)
            }
        }
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !quiet { onInput?(Array(data)) }
        super.send(source: source, data: data)
    }

    /// Typed by Coldfall itself (a desk's launch line): not you, not a question.
    private var quiet = false
    func sendQuietly(_ text: String) {
        quiet = true
        send(txt: text)
        quiet = false
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
        // Down to the millisecond, plus a few random letters: two pastes or
        // drops in the same second each keep their own file.
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let tag = String(UUID().uuidString.prefix(4)).lowercased()
        // Keep the original name's extension; drop macOS's narrow no-break
        // spaces and ordinary spaces so the pasted path needs no escaping.
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let dest = URL(fileURLWithPath: dir)
            .appendingPathComponent("dropped-\(f.string(from: Date()))-\(tag)\(ext)")
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
        // Down to the millisecond, plus a few random letters: two pastes or
        // drops in the same second each keep their own file.
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let tag = String(UUID().uuidString.prefix(4)).lowercased()
        let path = (dir as NSString)
            .appendingPathComponent("pasted-\(f.string(from: Date()))-\(tag).png")
        guard (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return nil }
        return path
    }

    // Path escaping lives in ColdfallCore/ShellPath, under test.
}

// MARK: - a pane

/// A single terminal inside a desk, wrapped in a box that can show focus.
final class Pane {
    /// The terminal that draws this pane: SwiftTerm, or Ghostty's.
    let terminal: PaneTerminal
    let box: PaneBox
    /// Pane 0 runs the desk's CLI. The rest are shells, and closing one is free.
    let isAgent: Bool
    private(set) var started = false
    /// Running through a holder, so it outlives Coldfall (see Holder).
    private(set) var held = false
    private var heldDesk: String?

    /// How the agent pane starts. `reattach` finds it already running.
    enum Hold { case none, fresh, reattach }

    /// The holder that ships beside the app, if this bundle has one.
    static var holderPath: String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let p = dir.appendingPathComponent("coldfall-holder").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// Which terminal new desks get: Ghostty's when Settings asks for it
    /// and this build has it, otherwise SwiftTerm.
    static var wantsGhostty = false

    init(isAgent: Bool, ghostty: Bool = false) {
        self.isAgent = isAgent
        terminal = PaneTerminals.make(isAgent: isAgent, ghostty: ghostty)
        box = PaneBox(term: terminal.view)
    }

    /// End this pane's shell and everything running in it. The tree is read
    /// before the terminal lets go of the shell, or there is no root to find.
    func end() {
        if held, let d = heldDesk {
            // The holder owns the tree; it ends it the same way, then exits,
            // and the attach in this terminal goes with it. If the holder
            // can't be reached, the tree is ended directly, so nothing runs
            // on unseen to be started a second time.
            let shell = Holder.heldPid(desk: d)
            let t = terminal
            DispatchQueue.global(qos: .userInitiated).async {
                if Holder.end(desk: d) { return }
                if let p = shell { ProcessTree.end(ProcessTree.descendants(of: p, in: ProcessTree.read())) }
                DispatchQueue.main.async { t.terminate() }
            }
            return
        }
        // The process table is read off the main thread; the terminal lets go
        // of the shell only after, or there'd be no tree to find.
        let root = terminal.shellPid ?? 0
        let t = terminal
        DispatchQueue.global(qos: .userInitiated).async {
            let tree = root > 0 ? ProcessTree.descendants(of: root, in: ProcessTree.read()) : []
            DispatchQueue.main.async { t.terminate() }
            ProcessTree.end(tree)
        }
    }

    /// Launch the process. `command` is nil for a shell pane, which just lands
    /// in the directory and waits.
    func start(desk: Desk, command: String?, hold: Hold = .none) {
        guard !started else { return }
        started = true

        if hold != .none, let holder = Pane.holderPath {
            held = true
            heldDesk = desk.name
            if hold == .fresh, let command { paintStarting(desk: desk, command: command) }
            terminal.start(executable: holder, args: ["attach", desk.name, "--", "/bin/zsh", "-l"], desk: desk,
                           extraEnv: ["COLDFALL_HOLDER_DIR=\(Holder.root)"], held: desk.name)
            // Already running: it carries on where it was, nothing to type.
            if hold == .reattach { return }
            typeLaunch(desk: desk, command: command)
            return
        }

        if let command { paintStarting(desk: desk, command: command) }

        terminal.start(executable: "/bin/zsh", args: ["-l"], desk: desk, extraEnv: [], held: nil)
        typeLaunch(desk: desk, command: command)
    }

    /// The held shell's pid when held, else this terminal's own shell.
    var shellPid: Int32? {
        if held, let d = heldDesk { return Holder.heldPid(desk: d) }
        return terminal.shellPid
    }

    /// Follow a rename of the desk this pane holds, once its socket moved.
    func renamed(to name: String) { if held { heldDesk = name } }

    /// A CLI can take several seconds to boot. Paint something immediately,
    /// written straight to the view rather than through the pty, so a blank
    /// screen never reads as "nothing happened".
    private func paintStarting(desk: Desk, command: String) {
        terminal.feed(text: "\u{1b}[2J\u{1b}[H"
            + "\u{1b}[36m●\u{1b}[0m starting \u{1b}[1m\(desk.name)\u{1b}[0m\r\n"
            + "\u{1b}[2m  \(command)\r\n"
            + "  in \(desk.resolvedCwd)\u{1b}[0m\r\n\r\n")
    }

    private func typeLaunch(desk: Desk, command: String?) {
        // Land in the desk's directory, then launch its CLI. No `clear` here —
        // wiping the screen would throw away the only feedback there is.
        // Quoted whole: a folder name can hold ; $() or a newline, and only
        // escaping spaces let those run as commands.
        let dir = Shell.quote(desk.resolvedCwd)
        let line = command.map { "cd \(dir) && \($0)\n" } ?? "cd \(dir)\n"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.terminal.sendQuietly(line)
        }
    }

    /// Coldfall hands its own environment to every desk, so anything the app
    /// inherited is inherited again by the agent. CLAUDECODE marks "you are
    /// already inside a Claude Code session" and makes a nested one refuse to
    /// start — which happens whenever Coldfall is launched from a terminal that
    /// is itself running an agent. Scrub it rather than depending on how the app
    /// was launched.
    /// What must not reach a desk from Coldfall's own environment.
    static let poison = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
                         "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_BRIDGE_SESSION_ID",
                         "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
                         "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_PID", "CLAUDE_EFFORT"]

    static func environment(for desk: Desk) -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.removeAll { entry in poison.contains(where: { entry.hasPrefix($0 + "=") }) }
        return env + additions(for: desk)
    }

    /// What Coldfall adds to a desk's environment, as "KEY=value".
    static func additions(for desk: Desk) -> [String] {
        var env: [String] = []
        // Hooks and desk-scoped behaviour key off this, same as the shell wrapper.
        env.append("CLAUDE_DESK=\(desk.name)")
        env.append("COLDFALL=1")
        // For a desk whose own command starts Claude: the trimmed servers,
        // for it to pass on (see McpTrim). Built-in desks get the flag directly.
        if let s = McpTrim.settingsJSON(off: desk.mcpOff) { env.append("\(McpTrim.envKey)=\(s)") }
        return env
    }
}

// MARK: - the pane card

/// What a pane header's buttons ask for. The controller does the work, on
/// the pane the button belongs to (it takes focus first).
enum PaneAction { case splitRight, splitDown, zoom, close }

/// A pane's own header, as Herdr heads each pane:
///
///   ✳ work   Claude · ~/Code/work          ○    ⊟ ⊞ ✕
///
/// The agent pane names the desk and its vendor; a shell pane says shell.
final class PaneHeader: NSView {
    static let height: CGFloat = 28
    var onAction: ((PaneAction) -> Void)?

    private let iconView = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    let mark = MarkView()
    private let right = PaneHeader.button("rectangle.split.2x1", tip: "Split right  ⌘D")
    private let down = PaneHeader.button("rectangle.split.1x2", tip: "Split down  ⇧⌘D")
    private let close = PaneHeader.button("xmark", tip: "Close pane  ⌘W")
    private let zoom = PaneHeader.button("arrow.up.left.and.arrow.down.right", tip: "Zoom this pane  ⇧⌘↩")
    /// How full the conversation is ("ctx 62%"), from 60% up.
    private let gauge = NSTextField(labelWithString: "")
    private var buttons = NSStackView()
    /// The buttons show while the pointer is over the card (Herdr's rule):
    /// a row of icons on every pane, all the time, is noise.
    var hovering = false { didSet { if hovering != oldValue { buttons.animator().alphaValue = hovering ? 1 : 0 } } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        right.target = self; right.action = #selector(splitR)
        down.target = self; down.action = #selector(splitD)
        close.target = self; close.action = #selector(closeP)
        zoom.target = self; zoom.action = #selector(zoomP)
        gauge.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        gauge.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.lineBreakMode = .byTruncatingTail
        sub.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons = NSStackView(views: [right, down, zoom, close])
        buttons.orientation = .horizontal
        buttons.spacing = 0
        buttons.alphaValue = 0
        for v in [iconView, title, sub, gauge, mark, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            sub.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            sub.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            gauge.leadingAnchor.constraint(greaterThanOrEqualTo: sub.trailingAnchor, constant: 8),
            gauge.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.leadingAnchor.constraint(equalTo: gauge.trailingAnchor, constant: 8),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    /// The conversation's fullness. Quiet under 60%; orange, then red.
    func setContext(_ pct: Double?) {
        guard let p = pct, ContextGauge.level(p) != .fine else { gauge.stringValue = ""; gauge.toolTip = nil; return }
        gauge.stringValue = ContextGauge.text(p)
        gauge.textColor = ContextGauge.level(p) == .full ? .systemRed : .systemOrange
        gauge.toolTip = ContextGauge.level(p) == .full
            ? "This conversation is nearly full. The agent will compact it soon; a fresh start or /compact now keeps its answers sharp."
            : "This conversation is filling up."
    }

    func set(icon: NSImage?, title t: String, detail: String, panes: Int, zoomed: Bool = false, canClose: Bool? = nil) {
        iconView.image = icon
        title.stringValue = t
        sub.stringValue = detail
        zoom.isHidden = panes < 2
        zoom.image = NSImage(systemSymbolName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                             accessibilityDescription: "Zoom")
        zoom.toolTip = zoomed ? "Show all panes  ⇧⌘↩" : "Zoom this pane  ⇧⌘↩"
        // Closing the last pane would leave a desk with no terminal; beside
        // another desk, it takes this desk off the screen instead.
        let closable = canClose ?? (panes > 1)
        close.isEnabled = closable
        close.alphaValue = closable ? 1 : 0.35
        if panes < 2 { close.toolTip = closable ? "Take this desk off the screen (it keeps running)" : "Close pane  ⌘W" }
        else { close.toolTip = "Close pane  ⌘W" }
    }

    func restyle() {
        let ui = Theme.ui
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = ui.text
        sub.font = .systemFont(ofSize: 11.5)
        sub.textColor = ui.dimText
        for b in [right, down, zoom, close] { b.contentTintColor = ui.dimText }
        mark.needsDisplay = true
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        // A hairline between the header and the terminal.
        Theme.ui.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func splitR() { onAction?(.splitRight) }
    @objc private func splitD() { onAction?(.splitDown) }
    @objc private func closeP() { onAction?(.close) }
    @objc private func zoomP() { onAction?(.zoom) }

    private static func button(_ symbol: String, tip: String) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.bezelStyle = .inline
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }
}

/// One pane as a card: rounded, its own header, a small gap around it so the
/// window's chrome shows between panes. With more than one pane the focused
/// card is outlined and the others dim a little (Ghostty's
/// unfocused-split-opacity: the eye finds the bright pane first).
final class PaneBox: NSView {
    /// The gap from the card to the edge of its slot; two slots side by side
    /// make twice this between cards.
    static let gap: CGFloat = 4
    var showsFocus = false { didSet { if showsFocus != oldValue { restyle() } } }
    var focused = true { didSet { if focused != oldValue { restyle() } } }
    let header = PaneHeader()
    private let card = NSView()
    /// The desk's own colour: the card's outline and a wash on its header
    /// and background, so the pane says which desk it is without being read.
    var tint: String? { didSet { if tint != oldValue { restyle() } } }
    private weak var term: NSView?

    init(term: NSView) {
        super.init(frame: .zero)
        self.term = term
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        card.wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer?.cornerRadius = 9
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        addSubview(card)
        card.addSubview(header)
        card.addSubview(term)

        // Text butting against the frame is the first thing that makes a
        // terminal feel cheap, and the card rather than the terminal owns the
        // gap so the terminal's own background still fills it.
        let cfg = DeskConfig.themeSettings()
        let x = CGFloat(cfg.padX), y = CGFloat(cfg.padY)
        let g = Self.gap
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: g),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -g),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: g),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -g),
            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            term.topAnchor.constraint(equalTo: header.bottomAnchor, constant: y),
            term.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -y),
            term.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: x),
            term.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -x),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { header.hovering = true }
    override func mouseExited(with e: NSEvent) { header.hovering = false }

    func restyle() {
        let ui = Theme.ui
        layer?.backgroundColor = ui.sidebar.cgColor
        card.layer?.backgroundColor = DeskTint.wash(Theme.current().skin.terminal.background, tint).cgColor
        let lit = showsFocus && focused
        if let t = DeskTint.color(tint) {
            // Its own colour all the time; brighter and thicker with focus.
            card.layer?.borderColor = t.withAlphaComponent(lit || !showsFocus ? 0.9 : 0.45).cgColor
            card.layer?.borderWidth = lit ? 2 : 1.5
            header.layer?.backgroundColor = t.withAlphaComponent(0.16).cgColor
        } else {
            card.layer?.borderColor = (lit ? NSColor.controlAccentColor.withAlphaComponent(0.75) : ui.border).cgColor
            card.layer?.borderWidth = lit ? 1.5 : 1
            header.layer?.backgroundColor = NSColor.clear.cgColor
        }
        alphaValue = (showsFocus && !focused) ? 0.78 : 1.0
        header.restyle()
    }
}

/// Two desks side by side: the main one and, when asked for, a second.
///
/// Laid out by hand rather than with NSSplitView, which takes a half added
/// later for a collapsed pane and gives it no width. The boundary between
/// the halves drags; double-click it for even halves again.
final class DeskPairView: NSView {
    private weak var main: NSView?
    private weak var side: NSView?
    /// The main desk's share of the width while two are shown.
    private(set) var ratio: CGFloat = 0.5
    static let minHalf: CGFloat = 260
    var showsSide = false { didSet { if showsSide != oldValue { if showsSide { ratio = 0.5 }; needsLayout = true; layoutSubtreeIfNeeded(); window?.invalidateCursorRects(for: self) } } }

    func install(main: NSView, side: NSView) {
        self.main = main; self.side = side
        for v in [main, side] {
            v.translatesAutoresizingMaskIntoConstraints = true
            v.autoresizingMask = []
            addSubview(v)
        }
        side.isHidden = true
    }

    private var boundary: CGFloat {
        let w = bounds.width
        let lo = min(Self.minHalf, w / 2), hi = max(w - Self.minHalf, w / 2)
        return min(max((w * ratio).rounded(), lo), hi)
    }

    override func layout() {
        super.layout()
        guard let main, let side else { return }
        side.isHidden = !showsSide
        if showsSide {
            let x = boundary
            main.frame = NSRect(x: 0, y: 0, width: x, height: bounds.height)
            side.frame = NSRect(x: x, y: 0, width: bounds.width - x, height: bounds.height)
        } else {
            main.frame = bounds
        }
        // The halves' own contents are pinned to them with constraints, and
        // those were solved before the frames above changed: solve again, or
        // a desk keeps its old width under its neighbour.
        for v in [main, side] { v.needsLayout = true; v.layoutSubtreeIfNeeded() }
    }
    override func setFrameSize(_ n: NSSize) { super.setFrameSize(n); needsLayout = true }

    // The few points either side of the boundary belong to the drag.
    private var grip: NSRect { NSRect(x: boundary - 4, y: 0, width: 8, height: bounds.height) }
    override func hitTest(_ p: NSPoint) -> NSView? {
        if showsSide, let sv = superview, grip.contains(convert(p, from: sv)) { return self }
        return super.hitTest(p)
    }
    override func resetCursorRects() { if showsSide { addCursorRect(grip, cursor: .resizeLeftRight) } }
    override func mouseDown(with e: NSEvent) {
        guard showsSide else { return super.mouseDown(with: e) }
        if e.clickCount == 2 { ratio = 0.5; needsLayout = true; window?.invalidateCursorRects(for: self) }
    }
    override func mouseDragged(with e: NSEvent) {
        guard showsSide, bounds.width > 0 else { return }
        ratio = convert(e.locationInWindow, from: nil).x / bounds.width
        needsLayout = true
    }
    override func mouseUp(with e: NSEvent) { window?.invalidateCursorRects(for: self) }
}

/// The split view that holds a desk's cards. No divider line: the gap
/// between cards is the divider, and still drags.
final class CardSplitView: NSSplitView {
    override var dividerColor: NSColor { .clear }
}

// MARK: - a desk's panes

/// One live desk: its panes, which one has focus, and the split view holding them.
final class DeskSession {
    /// A var so a rename reaches a desk that is already running. The launch
    /// command was read when it started, so the running process is unaffected.
    var desk: Desk { didSet { if desk.color != oldValue.color { applyColor() } } }

    /// The desk's colour on every pane: terminal wash, card outline, header.
    func applyColor() {
        for p in panes {
            p.terminal.applyTheme(wash: desk.color)
            p.box.tint = desk.color
            p.box.restyle()
        }
    }
    /// Every pane reports process exit to the same delegate, so a shell pane
    /// closing is handled the same way the agent's own exit is.
    weak var processDelegate: LocalProcessTerminalViewDelegate? {
        didSet { for p in panes { p.terminal.exitDelegate = processDelegate } }
    }
    private(set) var panes: [Pane] = []
    private(set) var focused = 0
    /// Columns when vertical, rows when not. Set by the first split and kept.
    private(set) var isVertical = true

    /// The view to put on screen. A single pane is shown bare; a split view is
    /// only introduced once there is something to divide.
    let container = CardSplitView()

    init(desk: Desk) {
        self.desk = desk
        container.translatesAutoresizingMaskIntoConstraints = false
        container.dividerStyle = .thin
        container.isVertical = true
        // Ghostty's terminal learns a desk's state from its holder, so it is
        // only for a desk whose holder's socket path fits; the rest keep SwiftTerm.
        usesGhostty = Pane.wantsGhostty && PaneTerminals.hasGhostty && Pane.holderPath != nil
            && Holder.fits(Holder.socketPath(desk: desk.name))
        panes.append(Pane(isAgent: true, ghostty: usesGhostty))
        rebuild()
        wireOutput()
    }

    /// The agent's terminal — where a routed command goes, regardless of which
    /// pane the user happens to be looking at.
    var agent: PaneTerminal { panes[0].terminal }
    /// Drawn by Ghostty's terminal, and so always through a holder.
    let usesGhostty: Bool
    /// A pane's program ended (for a terminal with no delegate of its own).
    static var onPaneExit: ((NSView) -> Void)?

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
    func noteInput(_ bytes: [UInt8], from term: PaneTerminal?) {
        activityState.noteInput()
        // A shell split beside the agent isn't asking the agent anything.
        guard term === agent else { return }
        // A prompt sent to an agent that wasn't mid-question starts a turn.
        // (Enter on a permission prompt is an answer, part of the same turn.)
        let startsTurn = ActivityState.isSubmit(bytes) && !activityState.needsYou
            && (activityState.draftOpen || bytes.count > 1)      // typed then Enter, or sent whole
        activityState.noteTyping(bytes)
        if ActivityState.isSubmit(bytes) { activityState.noteAsked() }
        if startsTurn { onTurnStart?() }
    }

    /// Whether the agent is really there: started, its pane not closed, and
    /// something still running under the pane's shell. An agent that exited
    /// (or crashed) leaves a bare shell, and typing into that runs commands.
    /// Reads the process table: call it for an action, not on a timer.
    func agentAlive() -> Bool {
        guard started, !agentGone, desk.runtime != "shell", let shell = panes[0].shellPid else { return false }
        // Who has the terminal: the shell at its prompt means no agent,
        // whatever was left running in the background or suspended.
        return ProcessTree.runsForeground(shell: shell, foreground: ProcessTree.foregroundGroup(of: shell))
    }

    /// What a send, an ask or the inbox may do with this desk right now.
    func remoteTarget() -> RemoteOpen.Target {
        RemoteOpen.Target(running: started, agent: agentAlive(), blocked: isBlocked, draft: holdsDraft)
    }

    /// Stopped on a question for you (see ActivityState.needsYou).
    var isBlocked: Bool { activityState.needsYou }
    /// You're partway through typing a message into the agent.
    var holdsDraft: Bool { activityState.holdsDraft() }
    /// Whether the done hook speaks for this desk.
    var isSignaled: Bool { activityState.signaled }
    var turnEndedAt: Date? { activityState.turnEndedAt }

    /// The agent pane as text, scrollback included, the last `lines` rows.
    func screenText(lines: Int) -> String {
        RemoteOpen.lastLines(agent.screenText(), lines: lines)
    }

    /// Type into the agent as if from the keyboard. Goes the same road as
    /// a keystroke, so it counts as asking and a finished turn turns green.
    func typeOnBehalf(_ bytes: [UInt8]) {
        agent.send(bytes: bytes)
    }

    /// The agent terminal's live screen as text, wherever you have scrolled
    /// to. See ScreenChange.liveRows.
    func screen() -> [String] {
        agent.liveRows()
    }

    /// Once a desk has gone quiet and would show as waiting: if its screen
    /// is what it was when you left, the output was a repaint, not news.
    func dropRepaint() {
        // The agent's own word needs no second opinion from the screen.
        guard !activityState.signaled else { return }
        guard !screenChecked, case .ready = activity, let before = hiddenScreen else { return }
        screenChecked = true
        let fresh = ScreenChange.newLines(before: before, after: screen())
        if fresh.isEmpty { markSeen() } else { ScreenChange.logGreen(desk: desk.name, lines: fresh) }
    }
    func markSeen() { activityState.markSeen() }
    func notePeeked() { activityState.notePeeked() }
    func noteSignal(_ event: DoneSignal.Event, message: String? = nil, kind: String? = nil) {
        activityState.noteSignal(event)
        // Why it is waiting, kept only while it waits.
        reason = event == .notify ? DeskDetail.reason(message: message, kind: kind) : nil
    }
    /// You sent the agent a prompt: the moment to remember the folder as
    /// it was, for "what did this turn change".
    var onTurnStart: (() -> Void)?
    /// The folder at the start of the current turn, as a git tree.
    var turnBase: String?
    /// The agent's own words for why it stopped (hook or OSC 7501).
    private(set) var reason: String?
    /// What the agent's terminal title says it is doing, cleaned up.
    var title: String?
    /// The dim line for the desk list.
    var detailLine: String? { DeskDetail.line(blocked: isBlocked, reason: reason, title: title) }
    func markUnread() { activityState.markUnread() }

    /// What the rail should draw right now.
    var activity: DeskActivity { activityState.activity() }
    /// When this desk last wrote anything, for the rail's "2m".
    var lastOutput: Date? { activityState.lastOutput }
    /// When a key last went into the agent.
    var lastKey: Date? { activityState.keyAt }
    var focusedPane: Pane { panes[min(focused, panes.count - 1)] }
    var started: Bool { panes[0].started }

    /// Every pane's process id, for measuring the desk's memory.
    var pids: [Int32] { panes.compactMap { $0.started ? $0.shellPid : nil } }
    /// The agent runs through a holder and will outlive Coldfall.
    var isHeld: Bool { panes[0].held }

    /// End every pane's process. The session is finished after this.
    func terminateAll() {
        ended = true
        for p in panes where p.started { p.end() }
    }

    /// Finding the conversation to reopen reads session files, which can be
    /// many on a busy Mac, so it happens off the main thread. A desk stopped
    /// in the meantime is not started when the answer comes back.
    private(set) var resolving = false
    private var ended = false

    /// Waiting on the person: whether to resume or start fresh. Nothing
    /// starts while this is set, so a second click can't start it twice.
    var holding = false
    /// The agent pane exited while a shell pane stayed. What's left is a
    /// shell, not the agent, whatever agentTerm now points at.
    var agentGone = false { didSet { if agentGone, !oldValue { activityState.noteResumed(); reason = nil; title = nil } } }

    /// Settings' "Keep desks running when Coldfall quits" (off unless turned
    /// on); a desk's own keep_running wins. Mirrors UIState.keepDesksRunning.
    static var keepGlobal = false

    /// How the agent pane should start: back onto a holder that is still
    /// running, a new holder, or no holder at all.
    private var hold: Pane.Hold {
        guard Pane.holderPath != nil else { return .none }
        let sock = Holder.socketPath(desk: desk.name)
        guard Holder.fits(sock) else { return .none }
        if Holder.isAlive(sock) { return .reattach }
        // A Ghostty desk always has a holder: that is where its state comes from.
        return usesGhostty || desk.keepsRunning(global: DeskSession.keepGlobal) ? .fresh : .none
    }

    /// The holder's socket moves with a rename; the pane follows it.
    func followRename(to name: String) { panes[0].renamed(to: name) }


    /// The name the desk was started under. The agent's CLAUDE_DESK, and so
    /// its done signals, keep it through a rename until the desk restarts.
    private(set) var launchName: String?

    func startIfNeeded() {
        guard !started, !resolving, !holding else { return }
        let d = desk
        if hold == .reattach {
            // A replay of what it said while Coldfall was closed is not news,
            // but where it stands once the replay is over is: a question it
            // asked meanwhile is still waiting.
            activityState.mute(for: 3)
            startPanes(nil, hold: .reattach)
            let name = d.name
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                let logged = DoneSignal.last(desk: self?.launchName ?? name, since: Date().addingTimeInterval(-86_400))?.event
                self?.activityState.endMute(logged: logged)
            }
            return
        }
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

    private func startPanes(_ command: String?, hold: Pane.Hold? = nil) {
        // A held desk keeps the name it started under, even across a rename
        // and a relaunch: that's the name its hooks report.
        launchName = ((hold ?? self.hold) == .reattach ? Holder.launchName(desk: desk.name) : nil) ?? desk.name
        panes[0].start(desk: desk, command: command, hold: hold ?? self.hold)
        for p in panes.dropFirst() { p.start(desk: desk, command: nil) }
    }

    /// Add a pane. The first split picks the orientation for the desk; later
    /// ones join it, because a desk has one axis rather than a tree.
    @discardableResult
    func split(vertical: Bool) -> Pane? {
        // Four is where panes stop being useful and start being a mosaic.
        guard panes.count < 4 else { return nil }
        if panes.count == 1 { isVertical = vertical; container.isVertical = vertical }
        let p = Pane(isAgent: false, ghostty: usesGhostty)
        wire(p)
        panes.insert(p, at: focused + 1)
        focused += 1
        rebuild()
        p.start(desk: desk, command: nil)
        return p
    }

    /// A shell split beside the agent with `line` typed into it: for running
    /// the vendor's own fork command next to the conversation it forks.
    @discardableResult
    func splitRunning(_ line: String) -> Bool {
        guard let p = split(vertical: panes.count == 1 ? true : isVertical) else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak p] in p?.terminal.sendQuietly(line + "\n") }
        return true
    }

    /// For --snapshot --split: a second pane, its shell never started.
    func addPaneForPicture() {
        if panes.count == 1 { isVertical = true; container.isVertical = true }
        panes.append(Pane(isAgent: false))
        focused = 0
        rebuild()
    }

    /// Close a pane, killing its process. Refuses the last one — a desk with no
    /// terminal is managed from the desk list, not from here.
    @discardableResult
    func closeFocused() -> Bool {
        guard panes.count > 1 else { return false }
        let p = panes.remove(at: focused)
        // Closing the agent's own pane leaves only shells: nothing may be
        // sent "to the agent" from now on, or it would run as a command.
        if p.isAgent { agentGone = true }
        p.end()
        p.box.removeFromSuperview()
        focused = min(focused, panes.count - 1)
        rebuild()
        return true
    }

    func focus(_ i: Int) {
        guard panes.indices.contains(i) else { return }
        focused = i
        // Zoomed, moving focus moves the zoom.
        if zoomed { rebuild() } else { markFocus() }
    }

    /// One pane filling the desk, the others still running behind it.
    private(set) var zoomed = false
    func toggleZoom() {
        guard panes.count > 1 || zoomed else { return }
        zoomed.toggle()
        rebuild()
    }

    /// Move focus by one, wrapping. `cmd-[` and `cmd-]`.
    func cycleFocus(_ delta: Int) {
        guard panes.count > 1 else { return }
        focus((focused + delta + panes.count) % panes.count)
    }


    func drop(view: NSView) {
        guard let i = panes.firstIndex(where: { $0.terminal.view === view }) else { return }
        guard panes.count > 1 else { return }   // the desk itself dying is handled above
        panes[i].box.removeFromSuperview()
        panes.remove(at: i)
        focused = min(focused, panes.count - 1)
        rebuild()
    }

    /// Any pane writing counts as the desk writing — a shell pane finishing a
    /// build is as worth knowing about as the agent answering.
    private func wireOutput() {
        for p in panes { wire(p) }
        // Its title is its own word for what it is working on.
        agent.onTitle = { [weak self] t in
            guard let s = self, !s.agentGone else { return }
            s.title = DeskDetail.title(t, desk: s.desk.name, runtime: s.desk.runtime)
        }
        // The agent's own word about itself, as the done hook would say it.
        agent.onNotice = { [weak self] m in
            // The agent's own hook or 7501 says it better; this is for
            // agents with neither.
            guard let s = self, !s.isSignaled else { return }
            s.noteSignal(TerminalNotice.event(m), message: m)
        }
        agent.onStatus = { [weak self] r in
            guard let s = self else { return }
            if let e = ProgramStatus.event(r) { s.noteSignal(e, message: r.message, kind: r.kind) }
            else if r.id.isEmpty, r.state == "working" { s.activityState.noteResumed() }
            // The program's own title for what it is doing, when it sends one.
            if r.id.isEmpty, !r.title.isEmpty { s.title = DeskDetail.title(r.title, desk: s.desk.name, runtime: s.desk.runtime) }
        }
    }

    /// Any pane's output, input and exit, to this desk.
    private func wire(_ p: Pane) {
        p.terminal.exitDelegate = processDelegate
        p.terminal.onOutput = { [weak self] in self?.noteOutput() }
        p.terminal.onInput = { [weak self, weak t = p.terminal] b in self?.noteInput(b, from: t) }
        p.terminal.onExit = { [weak t = p.terminal] in if let v = t?.view { DeskSession.onPaneExit?(v) } }
    }

    private func rebuild() {
        for v in container.arrangedSubviews { container.removeArrangedSubview(v); v.removeFromSuperview() }
        if panes.count < 2 { zoomed = false }
        for (i, p) in panes.enumerated() {
            if !zoomed || i == focused { container.addArrangedSubview(p.box) }
            p.box.header.onAction = { [weak self, weak p] a in
                guard let self, let p, let i = self.panes.firstIndex(where: { $0 === p }) else { return }
                self.focus(i)
                DeskSession.onPaneAction?(self, a)
            }
        }
        markFocus()
        refreshHeaders()
        applyColor()
    }

    /// The pane headers' buttons go to the controller, which owns splitting
    /// and closing (and the window's first responder).
    static var onPaneAction: ((DeskSession, PaneAction) -> Void)?

    /// On screen next to another desk. Then the focus outline shows which
    /// of the two desks the keys go to, even with one pane each.
    private(set) var paired = false
    private(set) var isKey = true
    /// The second of the pair: its last pane's close button takes it off screen.
    private(set) var isBeside = false
    func setPair(_ paired: Bool, key: Bool, beside: Bool = false) {
        guard paired != self.paired || key != isKey || beside != isBeside else { return }
        self.paired = paired; isKey = key; isBeside = beside
        markFocus()
        refreshHeaders()
    }

    /// Name each pane: the agent pane by its desk and vendor, shells as shell.
    func refreshHeaders() {
        var path = (desk.resolvedCwd as NSString).abbreviatingWithTildeInPath
        // The branch, when it isn't main: which desks are off on their own.
        if let b = GitTail.branch(folder: desk.resolvedCwd) { path += "  \u{2387} " + b }
        let shellIcon = NSImage(systemSymbolName: "terminal", accessibilityDescription: "shell")
        for p in panes {
            if p.isAgent, desk.runtime != "shell" {
                p.box.header.set(icon: VendorIcon.image(runtime: desk.runtime, icon: desk.icon, size: 14),
                                 title: desk.name, detail: "\(desk.claudeAccount()?.vendor ?? AgentOffer.shortName(desk.runtime)) · \(path)", panes: panes.count, zoomed: zoomed,
                                 canClose: panes.count > 1 || isBeside)
                p.box.header.setContext(DeskState.load(desk.name)?.ctxPct)
            } else {
                p.box.header.set(icon: shellIcon, title: p.isAgent ? desk.name : "shell",
                                 detail: path, panes: panes.count, zoomed: zoomed, canClose: panes.count > 1 || isBeside)
                p.box.header.mark.mark = .none
            }
        }
    }

    /// The agent pane's state mark, from the same status as the desk list.
    func setMark(_ m: Mark) {
        guard let p = panes.first, p.isAgent, desk.runtime != "shell", !agentGone else { return }
        p.box.header.mark.mark = m
    }

    private func markFocus() {
        let many = panes.count > 1 || paired
        for (i, p) in panes.enumerated() {
            p.box.showsFocus = many
            p.box.focused = (i == focused) && (isKey || !paired)
        }
    }
}
