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
    /// The agent is stopped on a question for you: a permission, a choice.
    /// More urgent than ready, and it stays until you answer, not just look.
    case blocked
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
    /// This desk's agent reports when it is done (see DoneSignal). From then
    /// on output only shows it working; only the agent's word turns it green.
    public private(set) var signaled = false

    public init() {}

    /// The agent said it finished, or that it needs you. Green if you
    /// weren't looking; nothing if you were, because you saw it.
    ///
    /// A finished turn counts only if you asked for it. An agent with a timer
    /// inside its conversation really does finish a turn every few minutes,
    /// and a desk that turned green for each one was green all day with
    /// nothing to say to you. Needing you always counts, whoever started it.
    public mutating func noteSignal(_ event: DoneSignal.Event = .stop, at now: Date = Date()) {
        // A reattach replays the screen, status reports and all. The last
        // one replayed is kept: it is the program's state as it stands, and
        // applied once the replay is over (see endMute).
        if let m = mutedUntil, now < m { pendingSignal = event; return }
        signaled = true
        switch event {
        case .notify:
            needsYou = true
            needsYouAt = now
            if !visible { unseen = true }
        case .stop:
            needsYou = false
            turnEndedAt = now
            if visible { asked = false }           // you watched it finish
            else if asked { unseen = true }
        }
    }

    /// The agent asked you something and nothing has answered it yet. Looking
    /// doesn't clear it; a keystroke into the desk, the turn finishing, or the
    /// agent getting going again (answered from your phone) does.
    public private(set) var needsYou = false
    private var needsYouAt: Date?
    /// When the agent last said its turn was over.
    public private(set) var turnEndedAt: Date?

    /// Keys typed into the agent since the last Enter: a message half written.
    public private(set) var draftOpen = false
    /// When you last typed a key (not a terminal report).
    public private(set) var keyAt: Date?

    /// Bytes that are the terminal answering the program, not you typing:
    /// focus in and out (every desk switch), cursor position, device
    /// attributes and status, window size, colour queries (OSC) and DCS
    /// replies. A program asks; the terminal answers on the same road as
    /// keystrokes, and none of it is a person.
    public static func isReport(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 3, bytes[0] == 27 else { return false }
        switch bytes[1] {
        case 93, 80: return true                                 // OSC ESC], DCS ESCP
        case 91:                                                 // CSI ESC[
            guard let final = bytes.last else { return false }
            if bytes == [27, 91, 73] || bytes == [27, 91, 79] { return true }   // focus in/out
            // Replies end in R (cursor), c (attributes), n (status), t
            // (window), y (mode) or carry a ? or > parameter. Keys don't:
            // arrows end A-D, function keys ~, kitty keys u.
            if [82, 99, 110, 116, 121].contains(final) { return true }
            return bytes.count > 3 && (bytes[2] == 63 || bytes[2] == 62) && final != 117
        default: return false
        }
    }

    /// You typed into the agent's pane. Enter sends what was there.
    public mutating func noteTyping(_ bytes: [UInt8], at now: Date = Date()) {
        guard !ActivityState.isReport(bytes) else { return }
        keyAt = now
        // Only an answer answers: Return, Esc, or a choice's number. Moving
        // through the choices with the arrows is still the question open.
        if ActivityState.answers(bytes) { needsYou = false }
        draftOpen = !ActivityState.isSubmit(bytes)
    }

    /// Keys that answer a question: Return, Esc on its own, or one digit.
    public static func answers(_ bytes: [UInt8]) -> Bool {
        if isSubmit(bytes) || bytes == [27] { return true }
        return bytes.count == 1 && (48...57).contains(bytes[0])
    }

    /// The agent says it's working again (OSC 7501): whatever it asked was
    /// answered, here or somewhere else.
    public mutating func noteResumed() { needsYou = false }

    /// Whether something sent on your behalf would land in the middle of a
    /// message you are writing. A draft counts for a minute after your last
    /// key, then it's taken as abandoned.
    public static let draftHold: TimeInterval = 60
    public func holdsDraft(at now: Date = Date()) -> Bool {
        guard draftOpen, let k = keyAt else { return false }
        return now.timeIntervalSince(k) < ActivityState.draftHold
    }

    /// You sent this desk something and haven't yet seen the answer.
    public private(set) var asked = false

    /// You pressed Enter in the agent's pane, or something was sent on your behalf.
    public mutating func noteAsked() { asked = true }

    /// Whether bytes sent to a terminal submit something. Keys alone don't,
    /// and the terminal's own reports (focus in and out, on every desk switch)
    /// travel the same road, so only Enter counts: a return, or Enter in the
    /// kitty keyboard encoding, not as part of a paste.
    public static func isSubmit(_ bytes: [UInt8]) -> Bool {
        var rest = bytes
        let endPaste: [UInt8] = [27, 91, 50, 48, 49, 126]      // ESC[201~
        let startPaste: [UInt8] = [27, 91, 50, 48, 48, 126]    // ESC[200~
        func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
            guard hay.count >= needle.count else { return nil }
            return (0...(hay.count - needle.count)).last { Array(hay[$0..<($0 + needle.count)]) == needle }
        }
        if let e = find(endPaste, in: rest) { rest = Array(rest[(e + endPaste.count)...]) }
        else if find(startPaste, in: rest) != nil { return false }
        if rest.contains(13) || rest.contains(10) { return true }
        let text = String(decoding: rest, as: UTF8.self)
        return text.contains("\u{1b}[13u") || text.contains("\u{1b}[13;1u")
    }

    /// Output before this time is a replay, not news: a desk reattached to
    /// its holder repaints everything it said while Coldfall was closed.
    public private(set) var mutedUntil: Date?

    /// Ignore output for a moment, then treat the desk as read.
    public mutating func mute(for seconds: TimeInterval, at now: Date = Date()) {
        mutedUntil = now.addingTimeInterval(seconds)
        pendingSignal = nil
        unseen = false
    }

    /// The last status reported during a mute.
    public private(set) var pendingSignal: DoneSignal.Event?

    /// The replay is over: whatever the desk last said about itself stands.
    /// `logged` is its last word in the done-hook log, for an agent that
    /// reports that way (a question asked while Coldfall was closed).
    public mutating func endMute(logged: DoneSignal.Event?, at now: Date = Date()) {
        mutedUntil = nil
        let last = pendingSignal ?? logged
        pendingSignal = nil
        if last == .notify { noteSignal(.notify, at: now) }
        else if last == .stop { signaled = true }
    }

    public mutating func noteOutput(at now: Date = Date()) {
        if let m = mutedUntil {
            if now < m { lastOutput = now; return }
            mutedUntil = nil
        }
        if !visible, let h = hiddenAt, now.timeIntervalSince(h) < ActivityState.leaveGrace { return }
        // Output never answers a question: a repaint, a status line ticking
        // or a focus redraw all look like work. Only an answering key, the
        // turn ending, or the agent saying it's working again (7501) does.
        lastOutput = now
        if !visible, !signaled { unseen = true }
        if !visible || typedAt.map({ now.timeIntervalSince($0) >= ActivityState.echoGrace }) ?? true {
            lastWork = now
        }
    }

    /// A keystroke, or anything else sent into the desk.
    public mutating func noteInput(at now: Date = Date()) { typedAt = now }

    public mutating func setVisible(_ v: Bool, at now: Date = Date()) {
        if visible, !v { hiddenAt = now }
        visible = v
        if v {
            // Looking at an answer settles the question. A glance while it is
            // still working doesn't: its finish is still news.
            if unseen { asked = false }
            unseen = false
        }
    }

    /// A peek at the desk: you've read its answer, so it isn't news, but a
    /// question it's waiting on still is.
    public mutating func notePeeked() {
        if unseen { asked = false }
        unseen = false
    }

    /// "Clear" on the needs-you line: counts as having looked, without
    /// opening the desk.
    public mutating func markSeen() {
        if unseen { asked = false }
        unseen = false
        needsYou = false
    }

    public func activity(now: Date = Date()) -> DeskActivity {
        // A desk you are looking at never badges: you can see it. It can
        // still be working, and says so, or the row reads "idle" while the
        // agent is mid-answer in front of you.
        if visible {
            if let w = lastWork, now.timeIntervalSince(w) < ActivityState.quietFor { return .working }
            return .quiet
        }
        if needsYou { return .blocked }
        if let last = lastOutput, now.timeIntervalSince(last) < ActivityState.quietFor { return .working }
        guard lastOutput != nil || signaled else { return .quiet }
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

    /// The lines above the footer that weren't anywhere on the screen when
    /// you left. Empty means nothing new.
    ///
    /// Comparing the two screens row by row cried wolf. A notice appearing
    /// under the input box, Claude Code's "update installed" line for one,
    /// pushes every row up by one, so every row differed though nothing had
    /// been said, and desks you had read turned green after sitting idle. So a
    /// line counts as new only if it wasn't on the old screen at all, in any
    /// row, and numbers are ignored when matching, so a timer or a percentage
    /// ticking in the text isn't news either.
    public static func newLines(before: [String], after: [String], footer: Int = footerRows) -> [String] {
        func clean(_ line: String) -> String {
            var s = Substring(line)
            while let last = s.last, last.isWhitespace { s = s.dropLast() }
            return String(s)
        }
        func key(_ line: String) -> String {
            var out = ""; var inDigits = false
            for ch in line {
                if ch.isNumber { if !inDigits { out.append("#") }; inDigits = true }
                else { out.append(ch); inDigits = false }
            }
            return out.trimmingCharacters(in: .whitespaces)
        }
        let seen = Set(before.map { key(clean($0)) })
        let rows = after.map(clean)
        // Blank rows at the foot are the unused part of the screen.
        var end = rows.count
        while end > 0, rows[end - 1].isEmpty { end -= 1 }
        let body = rows[0..<max(0, end - footer)]
        return body.filter { !key($0).isEmpty && !seen.contains(key($0)) }
    }

    /// Why a desk turned green, kept on this Mac so a false one can be traced:
    /// the time, the desk, and the start of the first new line. The last 100.
    /// Overridable so tests write to a temp folder.
    public static var logPath = NSString(string: "~/.local/share/coldfall/logs/green.log").expandingTildeInPath

    public static func logGreen(desk: String, lines: [String], at now: Date = Date()) {
        guard let first = lines.first else { return }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let entry = "\(f.string(from: now))  \(desk)  \(lines.count) new  \(String(first.prefix(80)))"
        let dir = (logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var kept = ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        kept.append(entry)
        try? (kept.suffix(100).joined(separator: "\n") + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
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

    /// Waiting desks: those stopped on a question first, then the rest,
    /// each oldest wait first. Ties go by name so the order holds still
    /// between ticks.
    public static func queue(_ entries: [Entry]) -> [String] {
        entries.filter { $0.activity == .ready || $0.activity == .blocked }
            .sorted {
                let qa = $0.activity == .blocked, qb = $1.activity == .blocked
                if qa != qb { return qa }
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

    /// The line at the top of the rail, in the rail's own words: a desk
    /// stopped on a question "needs you", a finished one is "done".
    /// "api needs you", "2 done: golf, hub", "api needs you · 2 done".
    /// `blocked` says which of the queue are questions. Nil when nothing waits.
    public static func summary(_ queue: [String], blocked: Set<String> = [], limit: Int = 3) -> String? {
        guard !queue.isEmpty else { return nil }
        let asks = queue.filter { blocked.contains($0) }, done = queue.filter { !blocked.contains($0) }
        func named(_ xs: [String]) -> String { xs.prefix(limit).joined(separator: ", ") + (xs.count > limit ? ", …" : "") }
        func needs(_ withNames: Bool) -> String {
            asks.count == 1 ? "\(asks[0]) needs you" : "\(asks.count) need you" + (withNames ? ": " + named(asks) : "")
        }
        func dones(_ withNames: Bool) -> String {
            done.count == 1 && withNames ? "\(done[0]) is done" : "\(done.count) done" + (withNames ? ": " + named(done) : "")
        }
        if done.isEmpty { return needs(true) }
        if asks.isEmpty { return dones(true) }
        return needs(asks.count <= 2) + " · " + dones(false)
    }
}

/// When a desk's change is worth interrupting you for.
///
/// Only on the agent's own word (the done hook), never on a guess from output:
/// a notification that cries wolf gets turned off, and then the real one is
/// missed. Only for a desk you aren't looking at. A banner when Coldfall is
/// in the background; a sound alone when it's in front, since the rail
/// already shows which desk it was.
public enum NotifyRule {
    public enum Alert: Equatable { case silent, sound, banner }

    public static func decide(from old: DeskActivity, to new: DeskActivity, signaled: Bool,
                              appActive: Bool, deskVisible: Bool) -> Alert {
        guard signaled, !(appActive && deskVisible) else { return .silent }
        let rises: Bool
        switch new {
        case .blocked: rises = old != .blocked
        case .ready: rises = old != .ready && old != .blocked
        default: rises = false
        }
        guard rises else { return .silent }
        return appActive ? .sound : .banner
    }

    /// Title and body. Nothing from the conversation itself: a banner can
    /// show on a locked screen.
    public static func text(desk: String, _ a: DeskActivity) -> (title: String, body: String) {
        a == .blocked ? ("\(desk) needs you", "It's waiting for your answer.")
                      : ("\(desk) is done", "It finished while you were away.")
    }
}
