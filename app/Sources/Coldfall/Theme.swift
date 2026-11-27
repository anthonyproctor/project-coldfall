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
//     palette = "graphite"   # vscode | graphite | carbon | gruvbox | nord | solarized (Themes in the core)
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

    /// A skin from the catalogue in the core (see Themes).
    static func skin(_ f: Themes.Family, _ s: Themes.Skin) -> Skin {
        let c = s.chrome, t = s.terminal
        return Skin(family: f.id, isDark: s.isDark,
                    ui: UI(sidebar: hex(c.sidebar), editor: hex(c.editor), status: hex(c.status), border: hex(c.border),
                           hover: hex(c.hover), selected: hex(c.selected), accent: hex(c.accent), text: hex(c.text), dimText: hex(c.dimText)),
                    terminal: Palette(background: hex(t.background), foreground: hex(t.foreground), cursor: hex(t.cursor),
                                      selection: hex(t.selection), ansi: t.ansi.map { hex($0) }))
    }

    // MARK: - what is in force

    private static var cached: (Skin, NSFont)?

    /// True when the OS is in dark mode right now.
    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func current() -> (skin: Skin, font: NSFont) {
        if let c = cached { return c }
        let cfg = DeskConfig.themeSettings()

        let fam = Themes.family(cfg.palette)
        let wantDark: Bool
        switch (cfg.mode ?? "dark").lowercased() {
        case "light": wantDark = false
        case "dark":  wantDark = true
        default:      wantDark = systemIsDark
        }
        let skin = Theme.skin(fam, Themes.skin(fam, dark: wantDark))

        let size = CGFloat(cfg.size ?? 14)
        // A font that is not installed must fall back, never produce nothing.
        // JetBrains Mono is the default and is not on a stock Mac, so this is
        // the normal path rather than the exception.
        // A theme drawn for a typeface uses it when it's installed and the
        // font is still the default.
        let chosen = cfg.font.flatMap { $0.isEmpty || $0 == Theme.defaultFont ? nil : $0 }
        let font = chosen.flatMap { NSFont(name: $0, size: size) }
            ?? fam.font.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont(name: Theme.defaultFont, size: size)
            ?? NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont(name: "SF Mono", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)

        cached = (skin, font)
        return (skin, font)
    }

    static let defaultFont = "JetBrainsMono Nerd Font Mono"

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

    /// `wash`: a desk's own colour (see DeskColor), mixed faintly into the
    /// background so each desk's terminal is its own shade.
    static func apply(to term: TerminalView, wash: String? = nil) {
        let (skin, font) = current()
        let pal = skin.terminal
        term.font = font
        term.nativeBackgroundColor = DeskTint.wash(pal.background, wash)
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
