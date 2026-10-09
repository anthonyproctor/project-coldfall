// Knowing a desk answered while you were looking somewhere else.
//
// The point of desks is running several agents at once, which means you are
// never watching more than one of them. Without a signal you find out an agent
// answered by remembering to go and look — which is the failure the whole
// arrangement exists to remove.
//
// The hard part is that no CLI announces "I have finished answering". All that
// reaches Coldfall is bytes on a pty, so "finished" has to be inferred from
// bytes STOPPING. That inference has two failure modes and they pull in
// opposite directions:
//
//   * Too short a quiet window and an agent that pauses mid-answer is reported
//     as done, so the badge flickers during a single reply and stops meaning
//     anything.
//   * Too long and the badge lags far enough behind the work to be useless.
//
// Two seconds is the compromise. It lives here, in the Foundation-only core,
// because it is pure logic with a real failure mode and belongs under test
// rather than buried in a view.

import Foundation

/// What a desk is doing, for the badge in the rail.
public enum DeskActivity: Equatable {
    /// Nothing to report: idle, or you are looking at it right now.
    case quiet
    /// Output is arriving. The agent is mid-thought.
    case working
    /// Output arrived and then stopped while you were elsewhere. This is the
    /// state worth a badge: an answer is sitting there waiting.
    case ready
}

/// The state machine behind one desk's badge.
public struct ActivityState {

    /// How long output must stop for before a desk counts as finished.
    public static let quietFor: TimeInterval = 2.0

    /// Output this soon after leaving a desk is the desk reacting to being
    /// left, not saying anything. Leaving takes keyboard focus away, the
    /// terminal tells the program (focus reporting), and a TUI like Claude
    /// Code redraws. Those bytes arrived while the desk was out of view, so
    /// the desk turned green again moments after it had been read.
    public static let leaveGrace: TimeInterval = 1.5

    public private(set) var lastOutput: Date?
    /// Output arrived while the desk was not on screen.
    public private(set) var unseen = false
    /// Looking at a desk is the ONLY thing that clears it. Not hovering, not
    /// the app coming forward — a badge that clears itself is worse than none,
    /// because you stop trusting that it was ever set.
    public private(set) var visible = false
    /// When the desk last went out of view.
    public private(set) var hiddenAt: Date?

    /// Output this soon after a keystroke is the program echoing what you
    /// typed (Claude Code redraws its input box on every key), not the agent
    /// at work. It doesn't make the desk on screen read as working.
    public static let echoGrace: TimeInterval = 0.5

    /// When you last typed into this desk.
    public private(set) var typedAt: Date?
    /// The last output on screen that wasn't an echo of typing. The desk you
    /// are looking at reads as working from this, so it says "working" while
    /// its agent answers instead of "idle".
    public private(set) var lastWork: Date?

    public init() {}

    public mutating func noteOutput(at now: Date = Date()) {
        if !visible, let h = hiddenAt, now.timeIntervalSince(h) < ActivityState.leaveGrace { return }
        lastOutput = now
        if !visible { unseen = true }
        if !visible || typedAt.map({ now.timeIntervalSince($0) >= ActivityState.echoGrace }) ?? true {
            lastWork = now
        }
    }

    /// A keystroke, or anything else sent into the desk.
    public mutating func noteInput(at now: Date = Date()) { typedAt = now }

    public mutating func setVisible(_ v: Bool, at now: Date = Date()) {
        if visible, !v { hiddenAt = now }
        visible = v
        if v { unseen = false }
    }

    /// "Clear" on the needs-you line: counts as having looked, without
    /// opening the desk.
    public mutating func markSeen() { unseen = false }

    public func activity(now: Date = Date()) -> DeskActivity {
        // A desk you are looking at never badges: you can see it. It can
        // still be working, and says so, or the row reads "idle" while the
        // agent is mid-answer in front of you.
        if visible {
            if let w = lastWork, now.timeIntervalSince(w) < ActivityState.quietFor { return .working }
            return .quiet
        }
        guard let last = lastOutput else { return .quiet }
        if now.timeIntervalSince(last) < ActivityState.quietFor { return .working }
        return unseen ? .ready : .quiet
    }
}

/// Whether a hidden desk's output changed anything worth coming back for.
///
/// Output alone was the signal, and it cried wolf: an agent's full-screen
/// display repaints itself when it loses focus, when its status line ticks,
/// when a hook prints a notice. Each repaint is output while hidden, so a desk
/// you had just read turned green again. What matters is the screen: if what
/// the desk shows, above its input box and status line, is what it showed when
/// you left, nothing happened.
public enum ScreenChange {

    /// Rows at the bottom that change without anything happening: the input
    /// box, the status line, the hint under it.
    public static let footerRows = 5

    /// The live screen: the last `rows` lines of the whole buffer, one line
    /// per row as the terminal returns it.
    ///
    /// Not the rows on view. Those follow the scroll, and reading a long
    /// answer means scrolling up, so the screen recorded when you left was a
    /// page of history. The next repaint, at the bottom, never matched it, and
    /// a desk you had just read turned green again.
    public static func liveRows(buffer: String, rows: Int) -> [String] {
        var lines = buffer.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }      // the final line's own newline
        return Array(lines.suffix(max(0, rows)))
    }

    public static func meaningful(before: [String], after: [String], footer: Int = footerRows) -> Bool {
        func body(_ lines: [String]) -> [String] {
            let trimmed = lines.map { line -> String in
                var s = Substring(line)
                while let last = s.last, last.isWhitespace { s = s.dropLast() }
                return String(s)
            }
            // Blank rows at the foot are the unused part of the screen.
            var end = trimmed.count
            while end > 0, trimmed[end - 1].isEmpty { end -= 1 }
            return Array(trimmed[0..<max(0, end - footer)])
        }
        return body(before) != body(after)
    }
}

/// The desks waiting on you, gathered in one place.
///
/// A green check on each row is not enough once there are a dozen desks: a
/// waiting desk can sit inside a folded group or below the scroll. So the
/// rail lists them at the top and cmd-0 walks them, oldest wait first — the
/// desk that has been waiting longest is the one most likely forgotten.
public enum NeedsYou {

    public struct Entry: Equatable {
        public let name: String
        public let activity: DeskActivity
        public let lastOutput: Date?
        public init(name: String, activity: DeskActivity, lastOutput: Date?) {
            self.name = name; self.activity = activity; self.lastOutput = lastOutput
        }
    }

    /// Waiting desks, oldest wait first. Ties go by name so the order holds
    /// still between ticks.
    public static func queue(_ entries: [Entry]) -> [String] {
        entries.filter { $0.activity == .ready }
            .sorted {
                let a = $0.lastOutput ?? .distantPast, b = $1.lastOutput ?? .distantPast
                return a != b ? a < b : $0.name < $1.name
            }
            .map(\.name)
    }

    /// Where cmd-0 goes from `current`: the oldest waiting desk. The desk on
    /// screen never waits (looking at it clears it), so there is nothing to
    /// skip and pressing again moves on as each one is seen.
    public static func next(in queue: [String], current: String?) -> String? {
        queue.first { $0 != current }
    }

    /// The line at the top of the rail: "career needs you", "3 need you:
    /// career, hub, money". Nil when nothing is waiting.
    public static func summary(_ queue: [String], limit: Int = 3) -> String? {
        guard !queue.isEmpty else { return nil }
        if queue.count == 1 { return "\(queue[0]) needs you" }
        let shown = queue.prefix(limit).joined(separator: ", ")
        return "\(queue.count) need you: \(shown)" + (queue.count > limit ? ", …" : "")
    }
}
