import Foundation

/// Every theme Coldfall has, as hex strings: the window's surfaces, the
/// terminal's colours, and (from those) the phone page's. Foundation only,
/// so the phone inbox can follow the Mac and the values can be tested; the
/// app turns them into colours (Theme in the app target).
public enum Themes {
    /// The window around the terminal. Named after what each paints.
    public struct Chrome: Equatable {
        public let sidebar, editor, status, border, hover, selected, accent, text, dimText: String
    }
    /// The terminal: background, foreground, cursor, selection, 16 ANSI.
    public struct Terminal: Equatable {
        public let background, foreground, cursor, selection: String
        public let ansi: [String]
    }
    public struct Skin: Equatable {
        public let isDark: Bool
        public let chrome: Chrome
        public let terminal: Terminal
    }
    public struct Family: Equatable {
        /// What desks.toml says: `palette = "graphite"`.
        public let id: String
        public let title: String
        /// One line for the picker.
        public let blurb: String
        public let dark: Skin
        public let light: Skin?
        /// A typeface the theme is drawn for, used when it's installed and
        /// you haven't chosen one.
        public let font: String?
        /// Where the colours come from, when they aren't Coldfall's own.
        public let credit: String?
    }

    static func chrome(_ v: [String]) -> Chrome {
        Chrome(sidebar: v[0], editor: v[1], status: v[2], border: v[3], hover: v[4], selected: v[5], accent: v[6], text: v[7], dimText: v[8])
    }

    public static let all: [Family] = [
        Family(id: "vscode", title: "Coldfall", blurb: "The default: VS Code's Modern colours, neutral and calm.",
               dark: Skin(isDark: true,
                          chrome: chrome(["1b1b1a", "1f1f1f", "1b1b1a", "2c2c2a", "262625", "323230", "0078d4", "dcdcd8", "9c9c97"]),
                          terminal: Terminal(background: "1f1f1f", foreground: "cccccc", cursor: "cccccc", selection: "264f78",
                                             ansi: ["000000", "cd3131", "0dbc79", "e5e510", "2472c8", "bc3fbc", "11a8cd", "e5e5e5",
                                                    "666666", "f14c4c", "23d18b", "f5f543", "3b8eea", "d670d6", "29b8db", "e5e5e5"])),
               light: Skin(isDark: false,
                           chrome: chrome(["fafaf8", "ffffff", "fafaf8", "ebebe7", "f1f1ee", "e9e9e5", "005fb8", "2c2c2a", "74746f"]),
                           terminal: Terminal(background: "ffffff", foreground: "3b3b3b", cursor: "3b3b3b", selection: "add6ff",
                                              ansi: ["000000", "cd3131", "00bc00", "949800", "0451a5", "bc05bc", "0598bc", "555555",
                                                     "666666", "cd3131", "14ce14", "b5ba00", "0451a5", "bc05bc", "0598bc", "a5a5a5"])),
               font: nil, credit: nil),
        Family(id: "graphite", title: "Graphite", blurb: "Near-black graphite, no colour accent; white and cool grey by day.",
               dark: Skin(isDark: true,
                          chrome: chrome(["121013", "18151a", "121013", "29262b", "221f24", "2c292f", "e9e6ec", "eeebf0", "a6a3a8"]),
                          terminal: Terminal(background: "18151a", foreground: "e6e3e8", cursor: "e9e6ec", selection: "3a363d",
                                             ansi: ["1c191d", "e07a72", "8fbf9a", "e3bc79", "8ea4d2", "b7a6e0", "8cc3c1", "cfcbd2",
                                                    "6e6a70", "ec958e", "a8d2b1", "edcd96", "a9bbe0", "cbbdeb", "a6d3d1", "eeebf0"])),
               light: Skin(isDark: false,
                           chrome: chrome(["eef0f3", "f6f7f9", "eef0f3", "dcdfe4", "e6e9ed", "dde1e6", "1c1f28", "1c1f28", "5f626a"]),
                           terminal: Terminal(background: "f6f7f9", foreground: "1c1f28", cursor: "1c1f28", selection: "d5dae1",
                                              ansi: ["1c1f28", "b5483f", "4f7a5a", "9a6b1f", "3e5a8e", "6b5a94", "2f6f6e", "8a8d94",
                                                     "5f626a", "c85a50", "5e8c69", "ae7c2a", "4c6ba3", "7c6aa8", "3a8180", "4a4d55"])),
               font: nil, credit: "After the Carbone theme for Claude by Julien Design Craft (MIT)."),
        Family(id: "carbon", title: "Carbon", blurb: "IBM's Carbon: Gray 100 at night, Gray 10 by day, blue for what you can press.",
               dark: Skin(isDark: true,
                          chrome: chrome(["161616", "161616", "161616", "393939", "262626", "393939", "4589ff", "f4f4f4", "c6c6c6"]),
                          terminal: Terminal(background: "161616", foreground: "f4f4f4", cursor: "f4f4f4", selection: "393939",
                                             ansi: ["262626", "fa4d56", "42be65", "f1c21b", "4589ff", "be95ff", "33b1ff", "c6c6c6",
                                                    "6f6f6f", "ff8389", "6fdc8c", "fddc69", "78a9ff", "d4bbff", "82cfff", "f4f4f4"])),
               light: Skin(isDark: false,
                           chrome: chrome(["f4f4f4", "ffffff", "f4f4f4", "e0e0e0", "e8e8e8", "e0e0e0", "0f62fe", "161616", "525252"]),
                           terminal: Terminal(background: "ffffff", foreground: "161616", cursor: "161616", selection: "d0e2ff",
                                              ansi: ["161616", "da1e28", "198038", "8e6a00", "0f62fe", "8a3ffc", "0072c3", "8d8d8d",
                                                     "525252", "fa4d56", "24a148", "b28600", "4589ff", "a56eff", "1192e8", "c6c6c6"])),
               font: "IBM Plex Mono", credit: "IBM's Carbon Design System colours (Apache 2.0)."),
        Family(id: "gruvbox", title: "Gruvbox", blurb: "Warm, retro and easy on the eyes.",
               dark: Skin(isDark: true,
                          chrome: chrome(["1b1b1c", "1d2021", "1b1b1c", "32302f", "32302f", "3c3836", "83a598", "ebdbb2", "a89984"]),
                          terminal: Terminal(background: "1d2021", foreground: "ebdbb2", cursor: "ebdbb2", selection: "665c54",
                                             ansi: ["1d2021", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
                                                    "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2"])),
               light: Skin(isDark: false,
                           chrome: chrome(["f2e5bc", "f9f5d7", "f2e5bc", "d5c4a1", "ebdbb2", "d5c4a1", "076678", "3c3836", "7c6f64"]),
                           terminal: Terminal(background: "f9f5d7", foreground: "3c3836", cursor: "3c3836", selection: "d5c4a1",
                                              ansi: ["fbf1c7", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "7c6f64",
                                                     "928374", "9d0006", "79740e", "b57614", "076678", "8f3f71", "427b58", "3c3836"])),
               font: nil, credit: nil),
        Family(id: "nord", title: "Nord", blurb: "Arctic blue-grey. Dark only.",
               dark: Skin(isDark: true,
                          chrome: chrome(["2b303b", "2e3440", "2b303b", "3b4252", "3b4252", "434c5e", "88c0d0", "d8dee9", "8fa1b3"]),
                          terminal: Terminal(background: "2e3440", foreground: "d8dee9", cursor: "d8dee9", selection: "434c5e",
                                             ansi: ["3b4252", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "88c0d0", "e5e9f0",
                                                    "4c566a", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "8fbcbb", "eceff4"])),
               light: nil, font: nil, credit: nil),
        Family(id: "solarized", title: "Solarized", blurb: "Ethan Schoonover's teal-blue classic. Dark only.",
               dark: Skin(isDark: true,
                          chrome: chrome(["00252e", "002b36", "00252e", "073642", "073642", "0a4453", "268bd2", "93a1a1", "657b83"]),
                          terminal: Terminal(background: "002b36", foreground: "839496", cursor: "93a1a1", selection: "073642",
                                             ansi: ["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                                                    "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"])),
               light: nil, font: nil, credit: nil),
    ]

    /// The family a palette name means; an unknown name is the default.
    public static func family(_ id: String?) -> Family {
        let k = (id ?? "vscode").lowercased()
        return all.first { $0.id == k } ?? all[0]
    }

    public static func skin(_ f: Family, dark: Bool) -> Skin { dark ? f.dark : (f.light ?? f.dark) }

    // MARK: - colour arithmetic

    static func rgb(_ hex: String) -> (Double, Double, Double) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }
    static func hex(_ c: (Double, Double, Double)) -> String {
        func b(_ x: Double) -> Int { max(0, min(255, Int((x * 255).rounded()))) }
        return String(format: "%02x%02x%02x", b(c.0), b(c.1), b(c.2))
    }
    /// `a` laid over `b` at `t` (0 is all b, 1 is all a).
    public static func mix(_ a: String, _ b: String, _ t: Double) -> String {
        let x = rgb(a), y = rgb(b)
        return hex((x.0 * t + y.0 * (1 - t), x.1 * t + y.1 * (1 - t), x.2 * t + y.2 * (1 - t)))
    }
    /// WCAG relative luminance.
    public static func luminance(_ h: String) -> Double {
        func l(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let c = rgb(h)
        return 0.2126 * l(c.0) + 0.7152 * l(c.1) + 0.0722 * l(c.2)
    }
    public static func contrast(_ a: String, _ b: String) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    /// Black or white, whichever reads on this colour.
    public static func ink(on h: String) -> String { contrast(h, "000000") >= contrast(h, "ffffff") ? "111111" : "ffffff" }

    /// The phone page's colours for a skin, as its CSS variables (without
    /// "--"), each a hex colour without "#".
    public static func phone(_ s: Skin) -> [String: String] {
        let c = s.chrome, t = s.terminal
        return [
            "bg": c.sidebar, "side": c.sidebar, "surface": c.editor, "raised": c.hover, "bubble": c.selected,
            "text": c.text, "dim": c.dimText, "faint": mix(c.dimText, c.sidebar, 0.62), "line": c.border,
            "accent": c.accent, "onaccent": ink(on: c.accent), "term": t.background,
            "green": t.ansi[s.isDark ? 10 : 2], "amber": t.ansi[s.isDark ? 11 : 3], "red": t.ansi[s.isDark ? 9 : 1],
            "sel": c.selected,
        ]
    }
}
