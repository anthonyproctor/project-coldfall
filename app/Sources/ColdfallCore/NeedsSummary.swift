import Foundation

/// What is waiting on you, in a sentence or two, for Siri and Shortcuts:
/// which desks and what about, never what is on their screens.
public enum NeedsSummary {
    public struct Item: Equatable {
        public let desk: String
        public let why: String
        public init(desk: String, why: String) { self.desk = desk; self.why = why }
    }

    public static func text(_ items: [Item], max: Int = 5) -> String {
        guard !items.isEmpty else { return "Nothing is waiting on you." }
        let lines = items.prefix(max).map { "\($0.desk): " + Prompt.short($0.why, max: 90) }
        let more = items.count > max ? "\nAnd \(items.count - max) more in Needs You." : ""
        let head = items.count == 1 ? "One thing is waiting on you." : "\(items.count) things are waiting on you."
        return head + "\n" + lines.joined(separator: "\n") + more
    }
}
