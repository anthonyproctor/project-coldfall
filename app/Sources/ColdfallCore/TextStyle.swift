// How a section label reads.
//
// Small capitals made every settings heading shout at the same volume, and
// they are the hardest letters to read at that size. A label is written once
// in the code and shown in sentence case, with acronyms kept.

import Foundation

public enum TextStyle {
    static let acronyms: Set<String> = ["SSH", "MCP", "CLI", "API", "MB"]

    /// "SSH HOSTS" -> "SSH hosts", "THIS WEEK, SINCE Sep 21" -> "This week,
    /// since Sep 21". Words already in mixed or lower case are left alone.
    public static func sentence(_ s: String) -> String {
        var first = true
        let parts = s.components(separatedBy: " ").map { word -> String in
            guard !word.isEmpty else { return word }
            let letters = word.filter(\.isLetter)
            defer { if !letters.isEmpty { first = false } }
            guard !letters.isEmpty, letters == letters.uppercased(), !acronyms.contains(letters) else { return word }
            let low = word.lowercased()
            return first ? low.prefix(1).uppercased() + low.dropFirst() : low
        }
        return parts.joined(separator: " ")
    }
}
