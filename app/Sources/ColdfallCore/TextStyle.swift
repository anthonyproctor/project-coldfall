// How a section label reads.
//
// Small capitals made every settings heading shout at the same volume, and
// they are the hardest letters to read at that size. A label is written once
// in the code and shown in sentence case, with acronyms kept.

import Foundation

public enum TextStyle {
    static let acronyms: Set<String> = ["SSH", "MCP", "CLI", "API", "MB"]
    /// Names keep their capital wherever they fall.
    static let names: [String: String] = ["COLDFALL": "Coldfall", "MAC": "Mac"]

    /// "a", "a and b", "a, b and c". Long lists end "and N more".
    public static func list(_ items: [String], max: Int = 6) -> String {
        guard items.count > max else {
            if items.count <= 2 { return items.joined(separator: " and ") }
            return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
        return items.prefix(max).joined(separator: ", ") + " and \(items.count - max) more"
    }

    /// "SSH HOSTS" -> "SSH hosts", "THIS WEEK, SINCE Sep 21" -> "This week,
    /// since Sep 21". Words already in mixed or lower case are left alone.
    public static func sentence(_ s: String) -> String {
        var first = true
        // The product's full name is one name; mixed case is left as it is.
        let s = s.replacingOccurrences(of: "PROJECT COLDFALL", with: "Project Coldfall")
        let parts = s.components(separatedBy: " ").map { word -> String in
            guard !word.isEmpty else { return word }
            let letters = word.filter(\.isLetter)
            defer { if !letters.isEmpty { first = false } }
            guard !letters.isEmpty, letters == letters.uppercased(), !acronyms.contains(letters) else { return word }
            if let n = names[letters] { return word.replacingOccurrences(of: letters, with: n) }
            let low = word.lowercased()
            return first ? low.prefix(1).uppercased() + low.dropFirst() : low
        }
        return parts.joined(separator: " ")
    }
}

/// The small badge beside a desk's name: which agent runs it, at a glance.
///
/// A letter on the vendor's colour rather than the vendor's logo: the logos
/// are trademarks, and a letter reads as well at 14 points. A desk can set its
/// own (`icon` in desks.toml), one character or an emoji.
public enum VendorBadge {
    public struct Badge: Equatable {
        public let text: String
        /// 0xRRGGBB, or nil for no fill (an emoji, a shell).
        public let fill: UInt32?
        public init(text: String, fill: UInt32?) { self.text = text; self.fill = fill }
    }

    /// Where vendor icons live: a picture per runtime (claude.png, codex.png…),
    /// chosen by the person, never shipped in the app.
    public static var iconDir: String {
        (Limits.configDir as NSString).appendingPathComponent("icons")
    }

    /// The picture to show for a desk, if there is one: the desk's own
    /// `icon` when it names an image file, else the runtime's picture in
    /// `dir`. Nil means draw the letter badge.
    public static func iconFile(runtime: String, icon: String?, dir: String = VendorBadge.iconDir,
                                exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        let pictures = ["png", "svg", "jpg", "jpeg", "icns", "pdf"]
        if let i = icon, !i.isEmpty {
            let path = NSString(string: i).expandingTildeInPath
            if pictures.contains((path as NSString).pathExtension.lowercased()) {
                let full = path.hasPrefix("/") ? path : (dir as NSString).appendingPathComponent(path)
                return exists(full) ? full : nil
            }
            return nil          // a letter or an emoji: drawn, not loaded
        }
        let base = runtime.hasPrefix("claude") ? "claude" : runtime
        for ext in pictures {
            let p = (dir as NSString).appendingPathComponent("\(base).\(ext)")
            if exists(p) { return p }
        }
        return nil
    }

    public static func badge(runtime: String, icon: String?) -> Badge {
        if let i = icon, !i.isEmpty {
            let letter = i.unicodeScalars.allSatisfy { $0.isASCII }
            return Badge(text: letter ? i.uppercased() : i, fill: letter ? 0x6B6B6B : nil)
        }
        switch runtime {
        case "claude": return Badge(text: "C", fill: 0xC96442)
        case "codex": return Badge(text: "X", fill: 0x10A37F)
        case "antigravity": return Badge(text: "A", fill: 0x4285F4)
        case "copilot": return Badge(text: "G", fill: 0x8957E5)
        case "grok": return Badge(text: "K", fill: 0x3A3A3A)
        case "ollama": return Badge(text: "O", fill: 0x5A5A5A)
        case "shell": return Badge(text: "›", fill: nil)
        default: return Badge(text: String(runtime.prefix(1)).uppercased(), fill: 0x6B6B6B)
        }
    }
}
