import Foundation

/// Drip, the little character in the notch, and what it is feeling.
///
/// It reacts to desks, and only to what the rail already knows: which are
/// stopped on a question, which just finished, which are mid-answer. One
/// thing at a time, most urgent first, so a glance at the notch says the
/// most important thing.
public enum CompanionMood: String, Equatable, CaseIterable {
    /// A desk is mid-answer.
    case working
    /// A desk just finished. Lasts a few seconds.
    case done
    /// A desk is stopped on a question for you.
    case needs
    /// Nothing is happening.
    case asleep
}

public struct Companion: Equatable {
    /// How long a finished desk is celebrated before Drip goes back to
    /// whatever the others are doing.
    public static let celebrateFor: TimeInterval = 5

    public private(set) var mood: CompanionMood = .asleep
    /// The desk Drip is reacting to, where clicking it should go: the one on
    /// a question, or the one that just finished. Nil when working or asleep.
    public private(set) var desk: String?

    private var last: [String: DeskActivity] = [:]
    private var doneDesk: String?
    private var doneUntil: Date = .distantPast

    public init() {}

    /// Feed it the running desks' activity, by name, once a tick.
    ///
    /// Finishing is the move out of working into anything but a question (a
    /// question outranks it anyway). A desk that stops running mid-answer has
    /// not finished, so it is not celebrated.
    public mutating func update(_ now: [String: DeskActivity], at t: Date) {
        let names = now.keys.sorted()
        if let f = names.first(where: { last[$0] == .working && now[$0] != .working && now[$0] != .blocked }) {
            doneDesk = f
            doneUntil = t.addingTimeInterval(Self.celebrateFor)
        }
        last = now
        if let b = names.first(where: { now[$0] == .blocked }) {
            mood = .needs; desk = b
        } else if t < doneUntil, let d = doneDesk, now[d] != nil {
            mood = .done; desk = d
        } else if names.contains(where: { now[$0] == .working }) {
            mood = .working; desk = nil
        } else {
            mood = .asleep; desk = nil
        }
    }

    /// What hovering over Drip says.
    public var tip: String {
        switch mood {
        case .needs: return "\(desk ?? "A desk") is waiting on a question. Click to go there."
        case .done: return "\(desk ?? "A desk") just finished. Click to see it."
        case .working: return "Desks are working."
        case .asleep: return "Nothing's running."
        }
    }
}

/// Where the notch is, from what macOS says about the screen: the gap between
/// the menu bar areas left and right of the camera, `inset` tall, at the top.
/// Nil on a screen with no notch. Plain numbers, so the core needs no
/// graphics framework: the screen's top edge, where the left area ends and
/// where the right one starts.
public struct Notch: Equatable {
    public let x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static func find(screenTop: Double, leftEnds: Double?, rightStarts: Double?, inset: Double) -> Notch? {
        guard inset > 0, let l = leftEnds, let r = rightStarts, r > l else { return nil }
        return Notch(x: l, y: screenTop - inset, width: r - l, height: inset)
    }
}
