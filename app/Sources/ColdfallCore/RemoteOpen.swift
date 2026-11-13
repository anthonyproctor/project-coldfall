import Foundation

/// Starting desks from outside the app: `coldfall-cli open <desk>`.
///
/// The point is a phone. Someone driving an agent from their phone (Claude's
/// Remote Control, an SSH session) can ask that agent to open another desk,
/// and the desk opens in Coldfall the way a click opens it: in the rail, with
/// its usual launch line, resuming its conversation, with its own settings.
/// Starting the agent some other way (a detached `screen`) works, but the
/// desk never shows in Coldfall, misses its per-desk settings, and can end up
/// running twice once Coldfall opens it too.
///
/// It is a folder of small files, not a socket or Apple events. Apple events
/// to another app need an Automation permission prompt that nobody can click
/// from a phone; files need nothing.
///
///   requests/<id>.json   the CLI asks: open this desk
///   requests/<id>.answer the app answers: started, already running, or why not
///   status.json          the app, every few seconds: which desks are running
///
/// The app only ever opens desks already in desks.toml, by exact name, so a
/// request can start nothing that a click on the rail could not.
public enum RemoteOpen {
    public static var root: String = ProcessInfo.processInfo.environment["COLDFALL_REMOTE_DIR"]
        ?? NSString(string: "~/.local/share/coldfall/remote").expandingTildeInPath
    static var requests: String { (root as NSString).appendingPathComponent("requests") }
    public static var statusPath: String { (root as NSString).appendingPathComponent("status.json") }

    /// A request older than this is dropped unanswered: whoever asked has
    /// given up, and opening a desk minutes later would surprise them.
    public static let requestTTL: TimeInterval = 120
    /// A status older than this means Coldfall isn't running (or is hung).
    public static let statusTTL: TimeInterval = 15

    public struct Request: Codable, Equatable {
        public var id: String
        public var desk: String
        /// Bring it on screen too, rather than starting it in the background.
        public var show: Bool
        public var time: Double
        /// "open" when absent, "read" or "send".
        public var action: String?
        /// For send: what to type into the desk.
        public var text: String?
        /// For read: how many lines from the bottom.
        public var lines: Int?
        public init(id: String = UUID().uuidString, desk: String, show: Bool = false, time: Double = Date().timeIntervalSince1970,
                    action: String? = nil, text: String? = nil, lines: Int? = nil) {
            self.id = id; self.desk = desk; self.show = show; self.time = time
            self.action = action; self.text = text; self.lines = lines
        }
    }

    public enum Outcome: String, Codable, Equatable {
        case started, alreadyRunning, unknownDesk, hiddenDesk
        case read, sent, notRunning, notAnAgent, blocked, draft
    }

    public struct Answer: Codable, Equatable {
        public var outcome: Outcome
        public var message: String
        /// For read: the desk's screen as text.
        public var text: String?
        public init(_ outcome: Outcome, _ message: String) { self.outcome = outcome; self.message = message }
    }

    public struct DeskState: Codable, Equatable {
        public var name: String
        public var running: Bool
        /// "working", "ready" (an answer waiting), "blocked" or "quiet".
        public var activity: String
        /// When the agent last said its turn was over (done hook or 7501).
        public var turnEndedAt: Double?
        /// Stopped on a question for you.
        public var needsYou: Bool?
        /// When the desk last wrote anything.
        public var outputAt: Double?
        /// Whether the agent reports for itself; without it, "done" is a
        /// guess from output stopping.
        public var signaled: Bool?
        public init(name: String, running: Bool, activity: String, turnEndedAt: Double? = nil,
                    needsYou: Bool? = nil, outputAt: Double? = nil, signaled: Bool? = nil) {
            self.name = name; self.running = running; self.activity = activity
            self.turnEndedAt = turnEndedAt; self.needsYou = needsYou; self.outputAt = outputAt; self.signaled = signaled
        }
    }

    /// What a desk added to its screen between two reads: everything after
    /// the old screen's last real line, without the agent's input box and
    /// status rows at the foot. Paragraph breaks are kept. Falls back to the
    /// lines that weren't there before when the old screen can't be found
    /// (the agent cleared or redrew it).
    public static func reply(before: String, after: String) -> String {
        func rows(_ s: String) -> [String] {
            var r = s.components(separatedBy: "\n").map { l -> String in var t = l; while t.last == " " { t.removeLast() }; return t }
            while r.last?.isEmpty == true { r.removeLast() }
            return r
        }
        let b = rows(before), a = rows(after)
        // The foot both screens share is the agent's input box and status
        // rows, the same but for numbers ticking in them. An agent without
        // one shares nothing there, and keeps every row.
        func masked(_ l: String) -> String { String(l.map { $0.isNumber ? "#" : $0 }) }
        var footer = 0
        while footer < min(a.count, b.count, 12),
              masked(a[a.count - 1 - footer]) == masked(b[b.count - 1 - footer]) { footer += 1 }
        // Only an input box is a footer: a prompt row or a box border. Two
        // replies that happen to end alike are not one.
        func isBox(_ l: String) -> Bool {
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("❯") || t.hasPrefix("›") || t.filter({ $0 == "─" }).count >= 8
        }
        if footer == b.count || !a.suffix(footer).contains(where: isBox) { footer = 0 }
        let bBody = Array(b.dropLast(min(footer, b.count)))
        let aBody = Array(a.dropLast(min(footer, a.count)))
        // The old screen's last few real lines, found together in the new one.
        let anchor = Array(bBody.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(3))
        var start: Int?
        if !anchor.isEmpty, let lastLine = anchor.last {
            for i in stride(from: aBody.count - 1, through: 0, by: -1) where aBody[i] == lastLine {
                // Check the lines before it match too, ignoring blanks.
                let prior = aBody[..<i].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(anchor.count - 1)
                if Array(prior) == Array(anchor.dropLast()) { start = i + 1; break }
            }
        }
        var out: [String]
        if let s = start { out = Array(aBody[s...]) }
        else { out = ScreenChange.newLines(before: b, after: a, footer: 0).filter { !aBody.isEmpty && aBody.contains($0) } }
        while out.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeFirst() }
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// `coldfall-cli wait`: whether a desk has finished what it was asked
    /// since `since`.
    public enum WaitResult: Equatable {
        /// Its turn ended. `guessed` when the agent doesn't report and the
        /// output simply stopped.
        case done(guessed: Bool)
        case needsYou
        case stopped
    }

    /// Output stopping this long is taken as done for an agent that doesn't
    /// say so itself.
    public static let quietMeansDone: TimeInterval = 10

    public static func waitResult(_ d: DeskState, since: Double, now: Double) -> WaitResult? {
        guard d.running else { return .stopped }
        if d.needsYou == true { return .needsYou }
        if let t = d.turnEndedAt, t > since { return .done(guessed: false) }
        if d.signaled != true, let o = d.outputAt, o > since, now - o >= quietMeansDone {
            return .done(guessed: true)
        }
        return nil
    }

    public struct Status: Codable, Equatable {
        public var time: Double
        public var pid: Int32
        public var desks: [DeskState]
        public init(time: Double = Date().timeIntervalSince1970, pid: Int32 = ProcessInfo.processInfo.processIdentifier, desks: [DeskState]) {
            self.time = time; self.pid = pid; self.desks = desks
        }
    }

    // MARK: the app's side

    /// What to do with a request, given the desks there are. Pure, so the
    /// rules are tested rather than trusted.
    public static func decide(_ desk: String, names: [String], hidden: Set<String>, running: Set<String>) -> Answer {
        guard names.contains(desk) else {
            let near = names.filter { $0.lowercased() == desk.lowercased() || $0.lowercased().hasPrefix(desk.lowercased()) }
            let hint = near.isEmpty ? "" : " Did you mean \(near.map { "\"\($0)\"" }.joined(separator: " or "))?"
            return Answer(.unknownDesk, "There's no desk called \"\(desk)\".\(hint)")
        }
        if running.contains(desk) { return Answer(.alreadyRunning, "\(desk) is already running.") }
        if hidden.contains(desk) {
            return Answer(.hiddenDesk, "\(desk) is hidden in Coldfall. Show it there first, then open it.")
        }
        return Answer(.started, "Started \(desk) in Coldfall.")
    }

    /// What one desk looks like to a read or a send, from the app's side.
    public struct Target: Equatable {
        public var running: Bool
        /// The agent is still in its pane (it hasn't exited to a shell).
        public var agent: Bool
        public var blocked: Bool
        /// You're partway through typing a message into it.
        public var draft: Bool
        public init(running: Bool, agent: Bool, blocked: Bool = false, draft: Bool = false) {
            self.running = running; self.agent = agent; self.blocked = blocked; self.draft = draft
        }
    }

    /// Whether a read can go ahead. Nil means yes.
    public static func refuseRead(_ desk: String, names: [String], hidden: Set<String>, target: Target?) -> Answer? {
        if let no = unknownOrHidden(desk, names: names, hidden: hidden) { return no }
        guard let t = target, t.running else {
            return Answer(.notRunning, "\(desk) isn't running. `coldfall-cli open \(desk)` starts it.")
        }
        return nil
    }

    /// Whether a send can go ahead now. Nil means yes. `.draft` means not
    /// yet: ask again shortly.
    ///
    /// A send types into the desk and presses Enter. On a desk stopped on a
    /// question that Enter would answer it, so a blocked desk is refused
    /// outright: answering is the person's call. A plain shell would run the
    /// text as a command, so only an agent takes a send.
    public static func refuseSend(_ desk: String, names: [String], hidden: Set<String>, target: Target?, text: String) -> Answer? {
        if let no = unknownOrHidden(desk, names: names, hidden: hidden) { return no }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Answer(.notAnAgent, "Nothing to send.")
        }
        guard let t = target, t.running else {
            return Answer(.notRunning, "\(desk) isn't running. `coldfall-cli open \(desk)` starts it, then send again.")
        }
        guard t.agent else { return Answer(.notAnAgent, "\(desk) is a shell, not an agent, so nothing was typed into it.") }
        if t.blocked {
            return Answer(.blocked, "\(desk) is waiting on a question, and Enter would answer it. Nothing was sent; answer it first.")
        }
        if t.draft { return Answer(.draft, "Someone is typing into \(desk); waiting for that message first.") }
        return nil
    }

    static func unknownOrHidden(_ desk: String, names: [String], hidden: Set<String>) -> Answer? {
        guard names.contains(desk) else {
            let near = names.filter { $0.lowercased() == desk.lowercased() || $0.lowercased().hasPrefix(desk.lowercased()) }
            let hint = near.isEmpty ? "" : " Did you mean \(near.map { "\"\($0)\"" }.joined(separator: " or "))?"
            return Answer(.unknownDesk, "There's no desk called \"\(desk)\".\(hint)")
        }
        if hidden.contains(desk) { return Answer(.hiddenDesk, "\(desk) is hidden in Coldfall. Show it there first.") }
        return nil
    }

    /// The bytes a send types: the text as one paste when it has more than
    /// one line, so a line break doesn't send half of it, then Enter.
    public static func keystrokes(_ text: String) -> [UInt8] {
        let t = text.trimmingCharacters(in: .newlines)
        let body = t.contains("\n") ? "\u{1b}[200~" + t + "\u{1b}[201~" : t
        return Array(body.utf8) + [13]
    }

    /// The last `lines` rows of a terminal buffer, without the blank rows a
    /// terminal keeps below the cursor.
    public static func lastLines(_ buffer: String, lines: Int) -> String {
        var rows = buffer.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\u{0}", with: " ") }
            .map { s -> String in var t = s; while t.last == " " { t.removeLast() }; return t }
        while rows.last?.isEmpty == true { rows.removeLast() }
        let n = max(1, min(lines, 5000))
        return rows.suffix(n).joined(separator: "\n")
    }

    /// Requests waiting, oldest first. Stale and unreadable ones are deleted.
    public static func pending(now: Date = Date()) -> [Request] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: requests) else { return [] }
        var out: [Request] = []
        for n in names where n.hasSuffix(".json") {
            let p = (requests as NSString).appendingPathComponent(n)
            guard let data = fm.contents(atPath: p), let r = try? JSONDecoder().decode(Request.self, from: data) else {
                try? fm.removeItem(atPath: p); continue
            }
            if now.timeIntervalSince1970 - r.time > requestTTL || r.id + ".json" != n {
                try? fm.removeItem(atPath: p); continue
            }
            out.append(r)
        }
        // Answers nobody collected.
        for n in names where n.hasSuffix(".answer") {
            let p = (requests as NSString).appendingPathComponent(n)
            if let a = try? fm.attributesOfItem(atPath: p), let m = a[.modificationDate] as? Date,
               now.timeIntervalSince(m) > requestTTL { try? fm.removeItem(atPath: p) }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Answer a request and take it off the queue.
    public static func answer(_ r: Request, _ a: Answer) {
        let p = (requests as NSString).appendingPathComponent(r.id + ".answer")
        if let data = try? JSONEncoder().encode(a) { try? data.write(to: URL(fileURLWithPath: p), options: .atomic) }
        try? FileManager.default.removeItem(atPath: (requests as NSString).appendingPathComponent(r.id + ".json"))
    }

    public static func writeStatus(_ s: Status) {
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: URL(fileURLWithPath: statusPath), options: .atomic) }
    }

    // MARK: the CLI's side

    /// Coldfall's last word on its desks, or nil when it isn't running.
    public static func status(now: Date = Date(), alive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Status? {
        guard let data = FileManager.default.contents(atPath: statusPath),
              let s = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        return fresh(s, now: now, alive: alive) ? s : nil
    }

    public static func fresh(_ s: Status, now: Date, alive: (Int32) -> Bool) -> Bool {
        now.timeIntervalSince1970 - s.time <= statusTTL && alive(s.pid)
    }

    public static func submit(_ r: Request) throws {
        try FileManager.default.createDirectory(atPath: requests, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(r)
        // Written under another name and moved in, so the app never reads half a file.
        let tmp = (requests as NSString).appendingPathComponent(r.id + ".tmp")
        try data.write(to: URL(fileURLWithPath: tmp))
        try FileManager.default.moveItem(atPath: tmp, toPath: (requests as NSString).appendingPathComponent(r.id + ".json"))
    }

    /// The app's answer, waiting up to `timeout`. Nil if none came; the
    /// request is withdrawn then, so it can't fire after the caller gave up.
    public static func wait(for r: Request, timeout: TimeInterval) -> Answer? {
        let p = (requests as NSString).appendingPathComponent(r.id + ".answer")
        let until = Date().addingTimeInterval(timeout)
        repeat {
            if let data = FileManager.default.contents(atPath: p), let a = try? JSONDecoder().decode(Answer.self, from: data) {
                try? FileManager.default.removeItem(atPath: p)
                return a
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < until
        try? FileManager.default.removeItem(atPath: (requests as NSString).appendingPathComponent(r.id + ".json"))
        return nil
    }
}
