// Ghostty's terminal as a Coldfall pane.
//
// Only compiled in a build made with COLDFALL_GHOSTTY=1 (see Package.swift);
// otherwise this file is empty and Coldfall is exactly the SwiftTerm app.
// Nothing in the app uses this view yet except `--ghostty-demo`, which opens
// one in a window so it can be tried by hand. It becomes a pane once the
// holder's tap (see Holder.Kind.tap) is feeding activity, because libghostty
// owns its own pty and gives no hook on what the program writes.
//
// The key and input-method handling follows Ghostty's own macOS app
// (macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift, MIT, Mitchell
// Hashimoto and contributors), cut down to what a pane needs.

#if COLDFALL_GHOSTTY
import AppKit
import GhosttyKit
import SwiftTerm
import ColdfallCore

/// The one libghostty app: its config and its callbacks.
final class GhosttyRuntime {
    static let shared: GhosttyRuntime? = GhosttyRuntime()

    let app: ghostty_app_t

    private init?() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else { return nil }
        guard let cfg = ghostty_config_new() else { return nil }
        // Coldfall's own look, not the person's Ghostty config: a desk
        // should look the same whichever terminal draws it.
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("coldfall-ghostty-\(getpid()).conf")
        try? GhosttyRuntime.config().write(toFile: path, atomically: true, encoding: .utf8)
        ghostty_config_load_file(cfg, path)
        ghostty_config_finalize(cfg)
        try? FileManager.default.removeItem(atPath: path)

        var rt = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in DispatchQueue.main.async { GhosttyRuntime.shared.map { ghostty_app_tick($0.app) } } },
            action_cb: { _, target, action in GhosttyRuntime.act(target, action) },
            // Pasting goes through the view's own paste (which also turns a
            // clipboard image into a file path), so the library never needs
            // to read the clipboard itself.
            read_clipboard_cb: { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNSUPPORTED },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, content, count, _ in
                guard count > 0 else { return }
                for i in 0..<count {
                    let c = content[i]
                    guard String(cString: c.mime).hasPrefix("text/plain") else { continue }
                    let s = String(decoding: UnsafeRawBufferPointer(start: c.data, count: c.len), as: UTF8.self)
                    DispatchQueue.main.async {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(s, forType: .string)
                    }
                    return
                }
            },
            close_surface_cb: { ud, _ in
                guard let ud else { return }
                let v = Unmanaged<GhosttyTermView>.fromOpaque(ud).takeUnretainedValue()
                DispatchQueue.main.async { v.onExit?() }
            }
        )
        guard let app = ghostty_app_new(&rt, cfg) else { return nil }
        self.app = app
    }

    /// What the library asks of its host. Only the title is taken; windows,
    /// tabs and splits are Coldfall's own and stay that way.
    private static func act(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let s = target.target.surface,
              let ud = ghostty_surface_userdata(s) else { return false }
        let v = Unmanaged<GhosttyTermView>.fromOpaque(ud).takeUnretainedValue()
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            let title = String(cString: action.action.set_title.title)
            DispatchQueue.main.async { v.onTitle?(title) }
            return true
        default:
            return false
        }
    }

    /// A config object from Coldfall's theme, with a desk's colour washed
    /// into the background. The caller owns it (ghostty_config_free).
    static func makeConfig(wash: String?) -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("coldfall-ghostty-\(getpid())-\(UUID().uuidString.prefix(8)).conf")
        try? config(wash: wash).write(toFile: path, atomically: true, encoding: .utf8)
        ghostty_config_load_file(cfg, path)
        ghostty_config_finalize(cfg)
        try? FileManager.default.removeItem(atPath: path)
        return cfg
    }

    /// Ghostty config text from Coldfall's theme.
    static func config(wash: String? = nil) -> String {
        let pal = Theme.current().skin.terminal
        func hex(_ c: NSColor) -> String {
            let r = c.usingColorSpace(.sRGB) ?? c
            return String(format: "%02x%02x%02x", Int(r.redComponent * 255), Int(r.greenComponent * 255), Int(r.blueComponent * 255))
        }
        let t = DeskConfig.themeSettings()
        var lines = [
            "background = \(hex(DeskTint.wash(pal.background, wash)))",
            "foreground = \(hex(pal.foreground))",
            "cursor-color = \(hex(pal.cursor))",
            "selection-background = \(hex(pal.selection))",
            // The card owns the gap around the text.
            "window-padding-x = 0",
            "window-padding-y = 0",
            "confirm-close-surface = false",
            "shell-integration = none",
        ]
        // The font Coldfall resolved (the one asked for, or its fallback).
        let font = Theme.current().1
        lines.append("font-size = \(Int(font.pointSize.rounded()))")
        if let family = font.familyName, !family.isEmpty { lines.append("font-family = \"\(family)\"") }
        for (i, c) in pal.ansi.prefix(16).enumerated() { lines.append("palette = \(i)=#\(hex(c))") }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// One Ghostty terminal in a view.
final class GhosttyTermView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    var onTitle: ((String) -> Void)?
    var onExit: (() -> Void)?

    private var markedText = NSMutableAttributedString()
    /// Text the input method committed during the key being handled.
    private var keyText: [String]?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    deinit {
        if let s = surface { ghostty_surface_free(s) }
        if let c = ownConfig { ghostty_config_free(c) }
    }

    /// Start `command` (a shell command line) in `cwd` with extra `env`.
    /// False if the library couldn't make a surface.
    @discardableResult
    func start(command: String, cwd: String?, env: [(String, String)] = []) -> Bool {
        guard surface == nil, let rt = GhosttyRuntime.shared else { return false }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        // C strings that must outlive the call.
        let keys = env.map { strdup($0.0) }, vals = env.map { strdup($0.1) }
        defer { (keys + vals).forEach { free($0) } }
        var vars = zip(keys, vals).compactMap { k, v -> ghostty_env_var_s? in
            guard let k, let v else { return nil }
            return ghostty_env_var_s(key: UnsafePointer(k), value: UnsafePointer(v))
        }
        let made: ghostty_surface_t? = command.withCString { cmd in
            (cwd ?? NSHomeDirectory()).withCString { dir in
                vars.withUnsafeMutableBufferPointer { buf in
                    cfg.command = cmd
                    cfg.working_directory = dir
                    cfg.env_vars = buf.baseAddress
                    cfg.env_var_count = buf.count
                    return ghostty_surface_new(rt.app, &cfg)
                }
            }
        }
        guard let made else { return false }
        surface = made
        syncSize()
        registerForDraggedTypes([.fileURL])
        if wash != nil { applyTheme(wash: wash) }
        return true
    }

    func terminate() {
        guard let s = surface else { return }
        surface = nil
        ghostty_surface_free(s)
    }

    /// Type into the program what Coldfall would have written to a pty.
    ///
    /// Ghostty takes text as a paste, and a paste never presses a key: a
    /// newline inside one doesn't run a command, and a "1" inside one isn't
    /// the 1 key to a prompt. So what is sent is read the way a terminal's
    /// input is: Return, Esc, Tab, the arrows, Ctrl-C and single characters
    /// go as key presses; a longer run of text goes as one paste.
    func send(text: String) {
        guard surface != nil, !text.isEmpty else { return }
        var bytes = Array(text.utf8)
        // Coldfall wraps multi-line sends in paste brackets itself; Ghostty
        // adds its own when the program asked for them.
        for marker in ["\u{1b}[200~", "\u{1b}[201~"] {
            let m = Array(marker.utf8)
            while let r = bytes.firstRange(of: m) { bytes.removeSubrange(r) }
        }
        var run: [UInt8] = []
        func flush() {
            guard !run.isEmpty else { return }
            let t = String(decoding: run, as: UTF8.self)
            run = []
            // One character is a key; more is a paste.
            if t.count == 1 { key(text: t) } else { paste(t) }
        }
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1b, i + 2 < bytes.count, bytes[i + 1] == 0x5b, let code = [0x41: 126, 0x42: 125, 0x43: 124, 0x44: 123][Int(bytes[i + 2])] {
                flush(); key(code: UInt32(code)); i += 3; continue      // arrows: up, down, right, left
            }
            switch b {
            case 0x0d, 0x0a: flush(); key(code: 36, text: "\r")           // Return
            case 0x1b: flush(); key(code: 53)                             // Esc
            case 0x09: flush(); key(code: 48, text: "\t")                 // Tab
            case 0x7f: flush(); key(code: 51)                             // Delete
            case 0x03: flush(); key(code: 8, mods: GHOSTTY_MODS_CTRL)     // Ctrl-C
            default: run.append(b)
            }
            i += 1
        }
        flush()
    }

    private func paste(_ t: String) {
        guard let s = surface else { return }
        t.withCString { ghostty_surface_text(s, $0, UInt(strlen($0))) }
    }

    /// Mac key codes for the characters an answer is made of.
    private static let keyCodes: [Character: UInt32] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "y": 16, "n": 45, "a": 0, "q": 12, " ": 49,
    ]

    /// One key, pressed and released.
    private func key(code: UInt32? = nil, text: String? = nil, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) {
        guard let s = surface else { return }
        var k = ghostty_input_key_s()
        k.mods = mods
        k.consumed_mods = GHOSTTY_MODS_NONE
        k.composing = false
        k.keycode = code ?? text.flatMap { $0.lowercased().first }.flatMap { Self.keyCodes[$0] } ?? 0
        k.unshifted_codepoint = text?.lowercased().unicodeScalars.first?.value ?? 0
        func fire(_ action: ghostty_input_action_e) {
            k.action = action
            if action == GHOSTTY_ACTION_PRESS, let t = text, let first = t.unicodeScalars.first, first.value >= 0x20 {
                _ = t.withCString { p -> Bool in k.text = p; return ghostty_surface_key(s, k) }
                k.text = nil
            } else {
                k.text = nil
                _ = ghostty_surface_key(s, k)
            }
        }
        fire(GHOSTTY_ACTION_PRESS)
        fire(GHOSTTY_ACTION_RELEASE)
    }

    /// The screen and scrollback as text, the last `lines` rows.
    func screenText(lines: Int) -> String {
        guard let s = surface else { return "" }
        var t = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(s, sel, &t), let p = t.text else { return "" }
        defer { ghostty_surface_free_text(s, &t) }
        let all = String(decoding: UnsafeRawBufferPointer(start: p, count: Int(t.text_len)), as: UTF8.self)
        return RemoteOpen.lastLines(all, lines: lines)
    }

    /// Everything on it, scrollback included.
    func allText() -> String { read(GHOSTTY_POINT_SCREEN) }
    /// The rows on screen now.
    func viewportRows() -> [String] {
        read(GHOSTTY_POINT_VIEWPORT).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
    private func read(_ tag: ghostty_point_tag_e) -> String {
        guard let s = surface else { return "" }
        var t = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(s, sel, &t), let p = t.text else { return "" }
        defer { ghostty_surface_free_text(s, &t) }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(t.text_len)), as: UTF8.self)
    }

    /// This surface's own look: Coldfall's theme with a desk's colour in it.
    private var ownConfig: ghostty_config_t?
    func applyTheme(wash: String?) {
        self.wash = wash
        guard let s = surface, let cfg = GhosttyRuntime.makeConfig(wash: wash) else { return }
        ghostty_surface_update_config(s, cfg)
        if let old = ownConfig { ghostty_config_free(old) }
        ownConfig = cfg
    }
    /// The colour asked for before the surface existed, applied once it does.
    private var wash: String?

    // MARK: - dropping files

    private func dropped(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropped(sender).isEmpty ? [] : .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !dropped(sender).isEmpty }
    /// A dropped file's path is typed, as in the SwiftTerm pane.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = dropped(sender).map { ShellPath.escape(DeskTerminalView.stable($0).path) }
        guard !paths.isEmpty else { return false }
        send(text: paths.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }

    /// The process in front in this terminal, for "is the agent still there".
    var foregroundPid: Int32? {
        guard let s = surface else { return nil }
        let p = ghostty_surface_foreground_pid(s)
        return p > 0 ? Int32(p) : nil
    }

    // MARK: - size, scale, focus

    private var lastPixels = NSSize.zero
    private func syncSize() {
        guard let s = surface else { return }
        let scale = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        ghostty_surface_set_content_scale(s, scale, scale)
        let px = convertToBacking(bounds).size
        guard px.width > 0, px.height > 0, px != lastPixels else { return }
        lastPixels = px
        ghostty_surface_set_size(s, UInt32(px.width), UInt32(px.height))
        if ProcessInfo.processInfo.environment["COLDFALL_SNAPSHOT_DEBUG"] != nil {
            let z = ghostty_surface_size(s)
            print("ghostty size: view \(bounds.size) px \(px) scale \(scale) window \(window != nil) -> cols \(z.columns) rows \(z.rows) cell \(z.cell_width_px)x\(z.cell_height_px) layer \(String(describing: layer?.contentsScale)) sublayers \(layer?.sublayers?.map { "\($0.frame.size)@\($0.contentsScale)" } ?? [])")
            fflush(stdout)
        }
    }
    override func setFrameSize(_ n: NSSize) { super.setFrameSize(n); syncSize() }
    // Auto Layout moves a view without always going through setFrameSize.
    override func layout() { super.layout(); syncSize() }
    override func resize(withOldSuperviewSize old: NSSize) { super.resize(withOldSuperviewSize: old); syncSize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); syncSize() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncSize()
        if let s = surface { ghostty_surface_set_occlusion(s, window != nil) }
    }
    override func becomeFirstResponder() -> Bool {
        if let s = surface { ghostty_surface_set_focus(s, true) }
        return true
    }
    override func resignFirstResponder() -> Bool {
        if let s = surface { ghostty_surface_set_focus(s, false) }
        return true
    }

    // MARK: - keys

    private static func mods(_ f: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if f.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if f.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if f.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if f.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if f.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(m)
    }

    private func keyEvent(_ action: ghostty_input_action_e, _ e: NSEvent) -> ghostty_input_key_s {
        var k = ghostty_input_key_s()
        k.action = action
        k.keycode = UInt32(e.keyCode)
        k.mods = Self.mods(e.modifierFlags)
        // Control and command never take part in producing text.
        k.consumed_mods = Self.mods(e.modifierFlags.subtracting([.control, .command]))
        k.text = nil
        k.composing = false
        k.unshifted_codepoint = 0
        if e.type == .keyDown || e.type == .keyUp,
           let c = e.characters(byApplyingModifiers: [])?.unicodeScalars.first { k.unshifted_codepoint = c.value }
        return k
    }

    /// Text for a key, without control characters (the library encodes
    /// those itself) or function-key private-use values.
    private static func text(for e: NSEvent) -> String? {
        guard let chars = e.characters else { return nil }
        if chars.count == 1, let sc = chars.unicodeScalars.first {
            if sc.value < 0x20 { return e.characters(byApplyingModifiers: e.modifierFlags.subtracting(.control)) }
            if sc.value >= 0xF700 && sc.value <= 0xF8FF { return nil }
        }
        return chars
    }

    @discardableResult
    private func press(_ action: ghostty_input_action_e, _ e: NSEvent, text: String? = nil, composing: Bool = false) -> Bool {
        guard let s = surface else { return false }
        var k = keyEvent(action, e)
        k.composing = composing
        if let t = text, !t.isEmpty, let first = t.unicodeScalars.first, first.value >= 0x20 {
            return t.withCString { k.text = $0; return ghostty_surface_key(s, k) }
        }
        return ghostty_surface_key(s, k)
    }

    override func keyDown(with e: NSEvent) {
        guard surface != nil else { return }
        let action = e.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let hadMarked = markedText.length > 0
        keyText = []
        defer { keyText = nil }
        // Through the input system, so dead keys and input methods compose.
        interpretKeyEvents([e])
        syncPreedit(clearIfNeeded: hadMarked)
        let composing = markedText.length > 0 || hadMarked
        if let list = keyText, !list.isEmpty {
            for t in list { press(action, e, text: t, composing: false) }
        } else {
            press(action, e, text: Self.text(for: e), composing: composing)
        }
    }

    override func keyUp(with e: NSEvent) { press(GHOSTTY_ACTION_RELEASE, e) }

    override func flagsChanged(with e: NSEvent) {
        let mod: UInt32
        switch e.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let down = Self.mods(e.modifierFlags).rawValue & mod != 0
        press(down ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, e)
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let s = surface else { return }
        if markedText.length > 0 {
            markedText.string.withCString { ghostty_surface_preedit(s, $0, UInt(strlen($0))) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(s, nil, 0)
        }
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        // During a key: collected, and sent with that key. Otherwise (the
        // emoji picker, dictation): typed straight in.
        if keyText != nil { keyText?.append(chars) } else { send(text: chars) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let a = string as? NSAttributedString { markedText = NSMutableAttributedString(attributedString: a) }
        else if let s = string as? String { markedText = NSMutableAttributedString(string: s) }
        if keyText == nil { syncPreedit() }
    }
    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let s = surface, let w = window else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(s, &x, &y, &width, &height)
        let r = convert(NSRect(x: x, y: bounds.height - y, width: width, height: height), to: nil)
        return w.convertToScreen(r)
    }
    // Keys the input system has no text for (arrows, Return) end up here;
    // keyDown sends them as keys, so nothing more to do.
    override func doCommand(by selector: Selector) {}

    // MARK: - copy and paste

    @objc func copy(_ sender: Any?) {
        guard let s = surface else { return }
        let a = "copy_to_clipboard"
        a.withCString { _ = ghostty_surface_binding_action(s, $0, UInt(strlen($0))) }
    }

    /// Paste; an image on the clipboard becomes a file and its path is
    /// pasted, as in the SwiftTerm pane.
    @objc func paste(_ sender: Any?) {
        guard let s = surface else { return }
        let text = DeskTerminalView.imageFileFromClipboard().map { ShellPath.escape($0) + " " }
            ?? NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.isEmpty else { return }
        text.withCString { ghostty_surface_paste_text(s, $0, UInt(strlen($0))) }
    }

    // MARK: - mouse

    private func point(_ e: NSEvent) -> NSPoint {
        let p = convert(e.locationInWindow, from: nil)
        return NSPoint(x: p.x, y: bounds.height - p.y)
    }
    private func button(_ state: ghostty_input_mouse_state_e, _ b: ghostty_input_mouse_button_e, _ e: NSEvent) {
        guard let s = surface else { return }
        let p = point(e)
        ghostty_surface_mouse_pos(s, p.x, p.y, Self.mods(e.modifierFlags))
        _ = ghostty_surface_mouse_button(s, state, b, Self.mods(e.modifierFlags))
    }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, e) }
    override func mouseUp(with e: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, e) }
    override func rightMouseDown(with e: NSEvent) { button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, e) }
    override func rightMouseUp(with e: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, e) }
    override func otherMouseDown(with e: NSEvent) { button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, e) }
    override func otherMouseUp(with e: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, e) }
    private func moved(_ e: NSEvent) {
        guard let s = surface else { return }
        let p = point(e)
        ghostty_surface_mouse_pos(s, p.x, p.y, Self.mods(e.modifierFlags))
    }
    override func mouseMoved(with e: NSEvent) { moved(e) }
    override func mouseDragged(with e: NSEvent) { moved(e) }
    override func rightMouseDragged(with e: NSEvent) { moved(e) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func scrollWheel(with e: NSEvent) {
        guard let s = surface else { return }
        var x = e.scrollingDeltaX, y = e.scrollingDeltaY
        let precise = e.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        // Bit 0: precise deltas. Bits 1-3: the momentum phase.
        var mods: Int32 = precise ? 1 : 0
        let phase: Int32
        switch e.momentumPhase {
        case .began: phase = 1
        case .stationary: phase = 2
        case .changed: phase = 3
        case .ended: phase = 4
        case .cancelled: phase = 5
        case .mayBegin: phase = 6
        default: phase = 0
        }
        mods |= phase << 1
        ghostty_surface_mouse_scroll(s, x, y, mods)
    }
}

/// Ghostty's terminal as a pane's terminal (see PaneTerminal).
///
/// The agent pane attaches to the desk's holder, and a tap on that holder
/// supplies what SwiftTerm supplied directly: that the program wrote, what
/// was typed, and its status reports. A shell pane has no holder, so it
/// draws and takes keys but reports no activity.
final class GhosttyPaneTerminal: PaneTerminal {
    private let gview = GhosttyTermView(frame: .zero)
    var view: NSView { gview }
    var onOutput: (() -> Void)?
    var onInput: (([UInt8]) -> Void)?
    var onStatus: ((ProgramStatus.Report) -> Void)?
    var onNotice: ((String) -> Void)?
    var onTitle: ((String) -> Void)?
    var onExit: (() -> Void)?
    /// SwiftTerm's delegate has no meaning here; exits come through onExit.
    weak var exitDelegate: LocalProcessTerminalViewDelegate?

    private var tap: HolderTap?
    private var scanner = OscScanner()
    private var standing: ProgramStatus.Report?
    /// Keys Coldfall typed itself (a launch line) come back through the tap
    /// like any others; for this long after one, they aren't "you typing".
    private var quietUntil = Date.distantPast
    private var ended = false

    init() {
        gview.translatesAutoresizingMaskIntoConstraints = false
        gview.onTitle = { [weak self] t in self?.onTitle?(t) }
        gview.onExit = { [weak self] in
            guard let self, !self.ended else { return }
            self.ended = true
            self.tap?.stop()
            self.onExit?()
        }
    }

    func start(executable: String, args: [String], desk: Desk, extraEnv: [String], held: String?) {
        // Ghostty's child inherits Coldfall's environment; what must not
        // reach a desk is taken out by env(1) on the way.
        let unset = Pane.poison.flatMap { ["-u", $0] }
        let cmd = (["/usr/bin/env"] + unset + [executable] + args).map(Shell.quote).joined(separator: " ")
        var env: [(String, String)] = [("TERM", "xterm-256color")]
        for e in Pane.additions(for: desk) + extraEnv {
            guard let eq = e.firstIndex(of: "=") else { continue }
            env.append((String(e[..<eq]), String(e[e.index(after: eq)...])))
        }
        guard gview.start(command: cmd, cwd: desk.resolvedCwd, env: env) else {
            // No surface: say so where the terminal would have been.
            DispatchQueue.main.async { [weak self] in self?.onExit?() }
            return
        }
        if let held { listen(desk: held, tries: 0) }
    }

    /// The holder takes a moment to come up; keep knocking for a few seconds.
    private func listen(desk: String, tries: Int) {
        guard !ended else { return }
        let t = HolderTap(desk: desk)
        t.onReplay = { [weak self] b in DispatchQueue.main.async { self?.replayed(b) } }
        t.onLive = { [weak self] in DispatchQueue.main.async { self?.replayOver() } }
        t.onOutput = { [weak self] b in DispatchQueue.main.async { self?.output(b) } }
        t.onInput = { [weak self] b in DispatchQueue.main.async { self?.input(b) } }
        if t.start() { tap = t; return }
        guard tries < 60 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.listen(desk: desk, tries: tries + 1) }
    }

    private func output(_ bytes: [UInt8]) {
        onOutput?()
        for s in scanner.feed(bytes) {
            switch s.code {
            case 7501: if let r = ProgramStatus.parse(s.payload) { onStatus?(r) }
            case 9, 99, 777: if let m = TerminalNotice.message(code: s.code, payload: s.payload) { onNotice?(m) }
            default: break      // titles reach us from Ghostty itself
            }
        }
    }
    /// What it said before we were listening: only its last word about itself counts.
    private func replayed(_ bytes: [UInt8]) {
        for s in scanner.feed(bytes) where s.code == 7501 {
            if let r = ProgramStatus.parse(s.payload), r.id.isEmpty { standing = r }
        }
    }
    private func replayOver() {
        if let r = standing { onStatus?(r) }
        standing = nil
    }
    private func input(_ bytes: [UInt8]) {
        guard Date() >= quietUntil else { return }
        onInput?(bytes)
    }

    func send(text: String) { gview.send(text: text) }
    func sendQuietly(_ text: String) {
        quietUntil = Date().addingTimeInterval(0.8)
        gview.send(text: text)
    }
    func send(bytes: [UInt8]) { gview.send(text: String(decoding: bytes, as: UTF8.self)) }
    /// Ghostty draws only what its program writes.
    func feed(text: String) {}
    func screenText() -> String { gview.allText() }
    func liveRows() -> [String] { gview.viewportRows() }
    func applyTheme(wash: String?) { gview.applyTheme(wash: wash) }
    func terminate() {
        ended = true
        tap?.stop()
        gview.terminate()
    }
    var shellPid: Int32? { gview.foregroundPid }
}

/// A held desk in a Ghostty terminal, with its state read off the holder.
///
/// Ghostty runs `coldfall-holder attach`, so the agent lives in the holder
/// as any held desk does; a tap on the same holder gives Coldfall the
/// output and the keys, and from those the same ActivityState that drives
/// every other desk's mark. `--ghostty-held` shows one, to prove the chain.
final class GhosttyHeldDesk {
    let view: GhosttyTermView
    private let desk: String
    private var tap: HolderTap?
    private var scanner = OscScanner()
    private(set) var activity = ActivityState()
    private(set) var title: String?
    private(set) var reason: String?
    private var timer: Timer?
    private var last: String = ""
    /// The state in words, each time it changes.
    var onState: ((String) -> Void)?

    init(desk: String, frame: NSRect) {
        self.desk = desk
        view = GhosttyTermView(frame: frame)
    }

    /// Start `program` (a shell command line) held, drawn by Ghostty.
    func start(program: String, cwd: String, holder: String) -> Bool {
        let cmd = [holder, "attach", desk, "--", "/bin/sh", "-c", program].map(Shell.quote).joined(separator: " ")
        guard view.start(command: cmd, cwd: cwd, env: [("COLDFALL", "1"), ("CLAUDE_DESK", desk), ("COLDFALL_HOLDER_DIR", Holder.root)]) else { return false }
        listen(tries: 0)
        timer = Timer.inEveryMode(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.report() }
        return true
    }

    /// The holder takes a moment to come up; keep knocking for a few seconds.
    private func listen(tries: Int) {
        let t = HolderTap(desk: desk)
        // What it said before we were listening: read for its standing
        // state and title only, applied once the replay is over.
        t.onReplay = { [weak self] b in DispatchQueue.main.async { self?.replayed(b) } }
        t.onLive = { [weak self] in DispatchQueue.main.async { self?.replayOver() } }
        t.onOutput = { [weak self] b in DispatchQueue.main.async { self?.output(b) } }
        t.onInput = { [weak self] b in DispatchQueue.main.async { self?.input(b) } }
        if t.start() { tap = t; return }
        guard tries < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.listen(tries: tries + 1) }
    }

    private func output(_ bytes: [UInt8]) {
        activity.noteOutput()
        for s in scanner.feed(bytes) {
            switch s.code {
            case 7501:
                guard let r = ProgramStatus.parse(s.payload) else { continue }
                if let e = ProgramStatus.event(r) {
                    activity.noteSignal(e)
                    reason = e == .notify ? DeskDetail.reason(message: r.message, kind: r.kind) : nil
                } else if r.id.isEmpty, r.state == "working" { activity.noteResumed() }
            case 9, 99, 777:
                guard !activity.signaled, let m = TerminalNotice.message(code: s.code, payload: s.payload) else { continue }
                let e = TerminalNotice.event(m)
                activity.noteSignal(e)
                reason = e == .notify ? DeskDetail.reason(message: m) : nil
            case 0, 2:
                title = DeskDetail.title(s.payload, desk: desk)
            default: break
            }
        }
    }

    /// The last status and title in the replay are the desk as it stands.
    private var standing: OscScanner.Sequence?
    private func replayed(_ bytes: [UInt8]) {
        for s in scanner.feed(bytes) {
            switch s.code {
            case 7501: if let r = ProgramStatus.parse(s.payload), r.id.isEmpty { standing = s }
            case 0, 2: title = DeskDetail.title(s.payload, desk: desk)
            default: break
            }
        }
    }
    private func replayOver() {
        defer { standing = nil }
        guard let s = standing, let r = ProgramStatus.parse(s.payload) else { return }
        if let e = ProgramStatus.event(r) {
            activity.noteSignal(e)
            reason = e == .notify ? DeskDetail.reason(message: r.message, kind: r.kind) : nil
        } else if r.state == "working" {
            activity.noteOutput()
        }
    }

    private func input(_ bytes: [UInt8]) {
        activity.noteInput()
        activity.noteTyping(bytes)
        if ActivityState.isSubmit(bytes) { activity.noteAsked() }
    }

    private func report() {
        let word: String
        switch activity.activity() {
        case .blocked: word = "needs you" + (reason.map { " (\($0))" } ?? "")
        case .working: word = "working"
        case .ready: word = "done"
        case .quiet: word = "idle"
        }
        let line = word + (title.map { " · " + $0 } ?? "")
        if line != last { last = line; onState?(line) }
    }

    func stop() { timer?.invalidate(); tap?.stop() }
}

/// `--ghostty-demo`: one Ghostty terminal in a window, to try by hand.
enum GhosttyDemo {
    static var window: NSWindow?
    static func open(command: String) -> GhosttyTermView? {
        let w = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 820, height: 480),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Coldfall · Ghostty terminal (demo)"
        w.isReleasedWhenClosed = false
        let v = GhosttyTermView(frame: w.contentView!.bounds)
        v.autoresizingMask = [.width, .height]
        w.contentView!.addSubview(v)
        v.onTitle = { [weak w] t in w?.title = "Coldfall · Ghostty (demo) · " + t }
        guard v.start(command: command, cwd: NSHomeDirectory(), env: [("COLDFALL", "1")]) else { return nil }
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        window = w
        return v
    }

    /// `--ghostty-held <program>`: that program as a held desk in Ghostty,
    /// its state (from the holder's tap) in the window's title.
    static var held: GhosttyHeldDesk?
    static func openHeld(program: String, holder: String) -> GhosttyHeldDesk? {
        let w = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 820, height: 480),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Coldfall · held desk in Ghostty (demo)"
        w.isReleasedWhenClosed = false
        let d = GhosttyHeldDesk(desk: "ghostty-demo", frame: w.contentView!.bounds)
        d.view.autoresizingMask = [.width, .height]
        w.contentView!.addSubview(d.view)
        d.onState = { [weak w] s in
            w?.title = "Coldfall · held desk in Ghostty (demo) · " + s
            print("state: " + s); fflush(stdout)
        }
        guard d.start(program: program, cwd: NSHomeDirectory(), holder: holder) else { return nil }
        // Not on screen as far as the marks go, so every state shows.
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(d.view)
        window = w
        held = d
        return d
    }
}
#endif
