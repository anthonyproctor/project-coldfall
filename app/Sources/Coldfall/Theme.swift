// How Coldfall looks — the terminal and the chrome around it.
//
// Coldfall exists because a terminal was not good enough, so looking right is
// not a cosmetic concern here; it is most of the product. Two rules follow.
//
// FIRST: the chrome and the terminal are one theme, not two. A Gruvbox
// terminal inside a stock-grey AppKit sidebar looks like two programs sharing
// a window, which is exactly what it is and exactly what it should not look
// like.
//
// SECOND: most of the UI already uses SEMANTIC colours — labelColor,
// windowBackgroundColor, controlAccentColor — which resolve correctly on their
// own once the window's NSAppearance is set. So the job is to set the
// appearance and then override the handful of named surfaces VS Code gives
// distinct colours to (sidebar, editor, status bar, borders), rather than to
// replace every colour in the app and lose the adaptivity that is already
// working.
//
// Configure in desks.toml:
//
//     [theme]
//     palette = "vscode"     # vscode | gruvbox | nord | solarized
//     mode    = "system"     # system (new setups) | dark (no mode set) | light
//     font    = "JetBrainsMono Nerd Font Mono"
//     size    = 14
//
// A family with no light variant stays dark in light mode rather than
// inventing one, and says so here instead of shipping something unreadable.

import AppKit
import SwiftTerm
import ColdfallCore

/// A split view whose divider is the theme's hairline. AppKit's own is a
/// hard line, near black in a light window and pale in a dark one, which cut
/// the window into boxes.
final class SoftSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.ui.border }
}

enum Theme {

    // MARK: - the two halves of a skin

    /// Terminal colours: background, foreground, cursor, selection, 16 ANSI.
    struct Palette {
        let background: NSColor
        let foreground: NSColor
        let cursor: NSColor
        let selection: NSColor
        let ansi: [NSColor]
    }

    /// Chrome colours. Named after what they paint, not after VS Code's own
    /// token names, so a non-VS-Code family can fill them honestly.
    struct UI {
        /// The rail: desk list and file tree.
        let sidebar: NSColor
        /// The reader, and anything that presents a document.
        let editor: NSColor
        /// The meter strip along the bottom.
        let status: NSColor
        /// Hairlines between regions.
        let border: NSColor
        /// The row under the pointer, and the selected one.
        let hover: NSColor
        let selected: NSColor
        /// Focus rings, the active desk, links.
        let accent: NSColor
        let text: NSColor
        let dimText: NSColor
    }

    struct Skin {
        let family: String
        let isDark: Bool
        let ui: UI
        let terminal: Palette
    }

    // MARK: - colours

    static func hex(_ s: String, alpha: CGFloat = 1) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: alpha)
    }

    private static func ansi(_ hexes: [String]) -> [NSColor] { hexes.map { hex($0) } }

    // --- VS Code Dark Modern ------------------------------------------------

    static let vscodeDark = Skin(
        family: "vscode", isDark: true,
        ui: UI(sidebar: hex("1b1b1a"), editor: hex("1f1f1f"), status: hex("1b1b1a"),
               border: hex("2c2c2a"), hover: hex("262625"), selected: hex("323230"),
               accent: hex("0078d4"), text: hex("dcdcd8"), dimText: hex("9c9c97")),
        terminal: Palette(
            background: hex("1f1f1f"), foreground: hex("cccccc"),
            cursor: hex("cccccc"), selection: hex("264f78"),
            ansi: ansi(["000000", "cd3131", "0dbc79", "e5e510", "2472c8", "bc3fbc", "11a8cd", "e5e5e5",
                        "666666", "f14c4c", "23d18b", "f5f543", "3b8eea", "d670d6", "29b8db", "e5e5e5"])))

    // --- VS Code Light Modern -----------------------------------------------

    static let vscodeLight = Skin(
        family: "vscode", isDark: false,
        ui: UI(sidebar: hex("fafaf8"), editor: hex("ffffff"), status: hex("fafaf8"),
               border: hex("ebebe7"), hover: hex("f1f1ee"), selected: hex("e9e9e5"),
               accent: hex("005fb8"), text: hex("2c2c2a"), dimText: hex("74746f")),
        terminal: Palette(
            background: hex("ffffff"), foreground: hex("3b3b3b"),
            cursor: hex("3b3b3b"), selection: hex("add6ff"),
            ansi: ansi(["000000", "cd3131", "00bc00", "949800", "0451a5", "bc05bc", "0598bc", "555555",
                        "666666", "cd3131", "14ce14", "b5ba00", "0451a5", "bc05bc", "0598bc", "a5a5a5"])))

    // --- Gruvbox ------------------------------------------------------------

    static let gruvboxDark = Skin(
        family: "gruvbox", isDark: true,
        ui: UI(sidebar: hex("1b1b1c"), editor: hex("1d2021"), status: hex("1b1b1c"),
               border: hex("32302f"), hover: hex("32302f"), selected: hex("3c3836"),
               accent: hex("83a598"), text: hex("ebdbb2"), dimText: hex("a89984")),
        terminal: Palette(
            background: hex("1d2021"), foreground: hex("ebdbb2"),
            cursor: hex("ebdbb2"), selection: hex("665c54"),
            ansi: ansi(["1d2021", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
                        "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2"])))

    static let gruvboxLight = Skin(
        family: "gruvbox", isDark: false,
        ui: UI(sidebar: hex("f2e5bc"), editor: hex("f9f5d7"), status: hex("f2e5bc"),
               border: hex("d5c4a1"), hover: hex("ebdbb2"), selected: hex("d5c4a1"),
               accent: hex("076678"), text: hex("3c3836"), dimText: hex("7c6f64")),
        terminal: Palette(
            background: hex("f9f5d7"), foreground: hex("3c3836"),
            cursor: hex("3c3836"), selection: hex("d5c4a1"),
            ansi: ansi(["fbf1c7", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "7c6f64",
                        "928374", "9d0006", "79740e", "b57614", "076678", "8f3f71", "427b58", "3c3836"])))

    // --- Dark-only families -------------------------------------------------

    static let nord = Skin(
        family: "nord", isDark: true,
        ui: UI(sidebar: hex("2b303b"), editor: hex("2e3440"), status: hex("2b303b"),
               border: hex("3b4252"), hover: hex("3b4252"), selected: hex("434c5e"),
               accent: hex("88c0d0"), text: hex("d8dee9"), dimText: hex("8fa1b3")),
        terminal: Palette(
            background: hex("2e3440"), foreground: hex("d8dee9"),
            cursor: hex("d8dee9"), selection: hex("434c5e"),
            ansi: ansi(["3b4252", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "88c0d0", "e5e9f0",
                        "4c566a", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "8fbcbb", "eceff4"])))

    static let solarizedDark = Skin(
        family: "solarized", isDark: true,
        ui: UI(sidebar: hex("00252e"), editor: hex("002b36"), status: hex("00252e"),
               border: hex("073642"), hover: hex("073642"), selected: hex("0a4453"),
               accent: hex("268bd2"), text: hex("93a1a1"), dimText: hex("657b83")),
        terminal: Palette(
            background: hex("002b36"), foreground: hex("839496"),
            cursor: hex("93a1a1"), selection: hex("073642"),
            ansi: ansi(["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                        "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"])))

    /// Every family, with its light variant where it has one. A family without
    /// a light skin stays dark rather than inventing one badly.
    static let families: [String: (dark: Skin, light: Skin?)] = [
        "vscode":    (vscodeDark, vscodeLight),
        "gruvbox":   (gruvboxDark, gruvboxLight),
        "nord":      (nord, nil),
        "solarized": (solarizedDark, nil),
    ]

    // MARK: - what is in force

    private static var cached: (Skin, NSFont)?

    /// True when the OS is in dark mode right now.
    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func current() -> (skin: Skin, font: NSFont) {
        if let c = cached { return c }
        let cfg = DeskConfig.themeSettings()

        let fam = families[(cfg.palette ?? "vscode").lowercased()] ?? (vscodeDark, vscodeLight)
        let wantDark: Bool
        switch (cfg.mode ?? "dark").lowercased() {
        case "light": wantDark = false
        case "dark":  wantDark = true
        default:      wantDark = systemIsDark
        }
        let skin = wantDark ? fam.dark : (fam.light ?? fam.dark)

        let size = CGFloat(cfg.size ?? 14)
        // A font that is not installed must fall back, never produce nothing.
        // JetBrains Mono is the default and is not on a stock Mac, so this is
        // the normal path rather than the exception.
        let font = NSFont(name: cfg.font ?? "JetBrainsMono Nerd Font Mono", size: size)
            ?? NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont(name: "SF Mono", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)

        cached = (skin, font)
        return (skin, font)
    }

    static var ui: UI { current().skin.ui }
    static var isDark: Bool { current().skin.isDark }

    /// Re-read after settings change, or when the OS flips light/dark.
    static func invalidate() { cached = nil }

    // MARK: - applying it

    /// Set the appearance for the WHOLE app, so every window inherits it.
    ///
    /// Theming window by window missed seven of them — Settings, Agent mail,
    /// Usage, Agents, the fan-out sheet, Update and Welcome each made their own
    /// NSWindow and kept a light system appearance over a dark theme. Setting it
    /// on NSApp covers them all, and any window added later, without anyone
    /// having to remember.
    ///
    /// "system" mode sets it to nil rather than to whatever the OS is now.
    /// Forcing it would pin the app to that answer: effectiveAppearance would
    /// then report the forced value, and the app could never see the OS switch
    /// to light at sunset. Nil means "follow the OS", which is what system is.
    static func applyGlobally() {
        let mode = (DeskConfig.themeSettings().mode ?? "dark").lowercased()
        if mode == "system" {
            NSApp.appearance = nil          // release it first, so isDark reads the OS
            invalidate()
        } else {
            invalidate()
            NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        }
    }

    /// Set the window's appearance so every SEMANTIC colour in the app —
    /// labelColor, control fills, scrollers, the titlebar — resolves to the
    /// right side of the theme without being touched individually.
    static func apply(to window: NSWindow) {
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.backgroundColor = ui.editor
    }

    static func apply(to term: TerminalView) {
        let (skin, font) = current()
        let pal = skin.terminal
        term.font = font
        term.nativeBackgroundColor = pal.background
        term.nativeForegroundColor = pal.foreground
        term.caretColor = pal.cursor
        term.caretTextColor = pal.background
        term.selectedTextBackgroundColor = pal.selection

        // SwiftTerm keeps its own colour type, on 0-65535 components rather
        // than 0-1, so the ANSI table is converted rather than assigned.
        term.installColors(pal.ansi.map { c in
            let rgb = c.usingColorSpace(.sRGB) ?? c
            return SwiftTerm.Color(red: UInt16(rgb.redComponent * 65535),
                                   green: UInt16(rgb.greenComponent * 65535),
                                   blue: UInt16(rgb.blueComponent * 65535))
        })
    }

    /// Paint a view as one of the named surfaces.
    static func paint(_ v: NSView, _ color: NSColor) {
        v.wantsLayer = true
        v.layer?.backgroundColor = color.cgColor
    }
}

extension Timer {
    /// A repeating or one-off timer that keeps firing while a menu is open
    /// or an alert is up. The plain scheduled kind stops in those modes, and
    /// with it the activity tick, status.json, and every remote request.
    @discardableResult
    static func inEveryMode(withTimeInterval i: TimeInterval, repeats: Bool, block: @escaping (Timer) -> Void) -> Timer {
        let t = Timer(timeInterval: i, repeats: repeats, block: block)
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}
