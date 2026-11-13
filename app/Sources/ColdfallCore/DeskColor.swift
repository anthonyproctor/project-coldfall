import Foundation

/// A desk's own colour.
///
/// With a dozen agents open, the commonest expensive mistake is typing a
/// message into the wrong one. A colour per desk, on its pane, its tab and
/// its row, makes "which one am I in" something you see without reading.
public enum DeskColor {
    /// Names offered in the desk's menu, picked to stay apart from each
    /// other and to read on both a dark and a light terminal.
    public static let palette: [(name: String, rgb: UInt32)] = [
        ("red", 0xE5534B), ("orange", 0xE0823D), ("yellow", 0xD4A72C), ("green", 0x57AB5A),
        ("teal", 0x39C5BB), ("blue", 0x539BF5), ("purple", 0x986EE2), ("pink", 0xE275AD),
    ]

    /// A palette name or "#rrggbb" (the # optional), as 0xRRGGBB.
    public static func rgb(_ value: String?) -> UInt32? {
        guard let v = value?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else { return nil }
        if let p = palette.first(where: { $0.name == v }) { return p.rgb }
        let hex = v.hasPrefix("#") ? String(v.dropFirst()) : v
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(hex, radix: 16)
    }

    /// `colour` mixed into `base`, `amount` of the way (0 none, 1 all).
    /// For the faint wash a desk's colour puts on its terminal.
    public static func mix(_ base: UInt32, _ colour: UInt32, amount: Double) -> UInt32 {
        let a = min(1, max(0, amount))
        func ch(_ shift: UInt32) -> UInt32 {
            let b = Double((base >> shift) & 0xff), c = Double((colour >> shift) & 0xff)
            return UInt32((b + (c - b) * a).rounded())
        }
        return ch(16) << 16 | ch(8) << 8 | ch(0)
    }

    /// How much of the colour goes into the terminal's background: enough
    /// to tell desks apart, never enough to hurt the text's contrast.
    public static let wash = 0.07
}
