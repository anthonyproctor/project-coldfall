// Ghostty's terminal as a Coldfall pane.
//
// Only compiled when scripts/ghostty-kit.sh has put GhosttyKit in Vendor/;
// without it this file is empty and Coldfall is exactly the SwiftTerm app.
// Nothing in the app uses this view yet except `--ghostty-demo`, which opens
// one in a window so it can be tried by hand. It becomes a pane once the
// holder's tap (see Holder.Kind.tap) is feeding activity, because libghostty
// owns its own pty and gives no hook on what the program writes.
//
// The key and input-method handling follows Ghostty's own macOS app
// (macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift, MIT, Mitchell
// Hashimoto and contributors), cut down to what a pane needs.

#if canImport(GhosttyKit)
import AppKit
import GhosttyKit
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

    /// Ghostty config text from Coldfall's theme.
    static func config() -> String {
        let pal = Theme.current().skin.terminal
        func hex(_ c: NSColor) -> String {
            let r = c.usingColorSpace(.sRGB) ?? c
            return String(format: "%02x%02x%02x", Int(r.redComponent * 255), Int(r.greenComponent * 255), Int(r.blueComponent * 255))
        }
        let t = DeskConfig.themeSettings()
        var lines = [
            "background = \(hex(pal.background))",
            "foreground = \(hex(pal.foreground))",
            "cursor-color = \(hex(pal.cursor))",
            "selection-background = \(hex(pal.selection))",
            // The card owns the gap around the text.
            "window-padding-x = 0",
            "window-padding-y = 0",
            "confirm-close-surface = false",
            "shell-integration = none",
        ]
        for (i, c) in pal.ansi.prefix(16).enumerated() { lines.append("palette = \(i)=#\(hex(c))") }
        _ = t
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

    deinit { if let s = surface { ghostty_surface_free(s) } }

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
        return true
    }

    func terminate() {
        guard let s = surface else { return }
        surface = nil
        ghostty_surface_free(s)
    }

    /// Type text into the program, as a paste would.
    func send(text: String) {
        guard let s = surface, !text.isEmpty else { return }
        text.withCString { ghostty_surface_text(s, $0, UInt(strlen($0))) }
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

    /// The process in front in this terminal, for "is the agent still there".
    var foregroundPid: Int32? {
        guard let s = surface else { return nil }
        let p = ghostty_surface_foreground_pid(s)
        return p > 0 ? Int32(p) : nil
    }

    // MARK: - size, scale, focus

    private func syncSize() {
        guard let s = surface else { return }
        let scale = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        ghostty_surface_set_content_scale(s, scale, scale)
        let px = convertToBacking(bounds).size
        guard px.width > 0, px.height > 0 else { return }
        ghostty_surface_set_size(s, UInt32(px.width), UInt32(px.height))
    }
    override func setFrameSize(_ n: NSSize) { super.setFrameSize(n); syncSize() }
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
}
#endif
