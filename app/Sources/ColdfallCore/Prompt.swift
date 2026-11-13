import Foundation

/// The question an agent has stopped on, read off its screen, so it can be
/// answered from a list (the Needs You window, the phone inbox) without
/// opening the desk.
///
/// Agents draw a choice as numbered lines, the chosen one marked:
///
///     Do you want to proceed?
///     ❯ 1. Yes
///       2. Yes, and don't ask again for npm commands
///       3. No, and tell Claude what to do differently (esc)
///
/// Only what is on the screen is offered, and an answer is pressed only if
/// that same option is still there when the key goes in: a prompt that has
/// changed since it was drawn is never answered blind.
public struct Prompt: Equatable {
    public struct Option: Equatable {
        /// The digit that picks it.
        public let key: String
        public let label: String
        public init(key: String, label: String) { self.key = key; self.label = label }
    }
    public let question: String
    /// What the question is about: the command, the file. A few lines.
    public let context: [String]
    public let options: [Option]

    public static let maxContext = 6

    /// Box-drawing and the selection arrow, which frame a prompt but aren't it.
    static func bare(_ line: Substring) -> String {
        let frame: Set<Character> = ["│", "┃", "|", "╭", "╮", "╰", "╯", "─", "━", "┌", "┐", "└", "┘", "❯", "›", "▶", ">", "●", "◯"]
        var s = Substring(line)
        while let f = s.first, f == " " || f == "\t" || frame.contains(f) { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" || frame.contains(l) { s = s.dropLast() }
        return String(s)
    }

    /// "1. Yes" or "2) No": the key and the label.
    static func option(_ bare: String) -> Option? {
        guard let d = bare.first, ("1"..."9").contains(d) else { return nil }
        let rest = bare.dropFirst()
        guard let sep = rest.first, sep == "." || sep == ")" else { return nil }
        let label = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : Option(key: String(d), label: label)
    }

    /// The prompt at the bottom of a screen, or nil when there isn't one:
    /// the last run of two or more numbered lines counting up from 1.
    public static func parse(screen: String, within: Int = 40) -> Prompt? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).suffix(within).map { bare($0) }
        var end = lines.count - 1
        while end >= 0 {
            guard option(lines[end]) != nil else { end -= 1; continue }
            // A run ending here: walk up while lines are options. A long
            // label wraps, so a line that isn't an option but sits between
            // two that are joins the one above it.
            var opts: [Option] = []
            var i = end
            var carry = ""
            while i >= 0 {
                if let o = option(lines[i]) {
                    opts.insert(Option(key: o.key, label: carry.isEmpty ? o.label : o.label + " " + carry), at: 0)
                    carry = ""
                    if o.key == "1" { break }
                } else if !lines[i].isEmpty, carry.isEmpty, !opts.isEmpty {
                    carry = lines[i]
                } else { break }
                i -= 1
            }
            let counting = opts.enumerated().allSatisfy { $0.element.key == String($0.offset + 1) }
            if opts.count >= 2, counting, i >= 0, opts.first?.key == "1" {
                var above = Array(lines[..<i])
                while let l = above.last, l.isEmpty { above.removeLast() }
                let question = above.popLast() ?? ""
                while let l = above.last, l.isEmpty { above.removeLast() }
                var context: [String] = []
                while let l = above.popLast(), !l.isEmpty, context.count < maxContext { context.insert(l, at: 0) }
                return Prompt(question: question, context: context, options: opts)
            }
            end = i - 1
        }
        return nil
    }

    /// The key to press for an option, only if that option is still what the
    /// screen offers under that key.
    public static func key(for option: Option, on screen: String) -> [UInt8]? {
        guard let now = parse(screen: screen), now.options.contains(option) else { return nil }
        return Array(option.key.utf8)
    }

    /// A label short enough for a button: "Yes, and don't ask again…".
    public static func short(_ label: String, max: Int = 44) -> String {
        var l = label
        for tail in [" (esc)", " (shift+tab)", " (tab)"] where l.lowercased().hasSuffix(tail) { l = String(l.dropLast(tail.count)) }
        return l.count > max ? String(l.prefix(max - 1)) + "…" : l
    }
}
