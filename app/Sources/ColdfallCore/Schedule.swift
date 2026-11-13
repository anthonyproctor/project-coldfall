import Foundation

/// A prompt sent to a desk on a schedule.
///
///   "every weekday at 9, ask the hub desk to plan the day, unless I'm
///    past 80% of the week's quota"
///
/// Local and plain: a JSON file you edit, a timer in the app, and the same
/// send every other send goes through (so it is refused while the desk is
/// asking something or you are typing there). Nothing runs when Coldfall
/// isn't open, and a time that passed while it was closed is recorded as
/// missed, not run late.
public struct Schedule: Codable, Equatable {
    public var name: String
    public var desk: String
    public var prompt: String
    /// "09:00", 24-hour, this Mac's time.
    public var at: String
    /// Days it runs: "mon".."sun". Empty or missing means every day.
    public var days: [String]?
    /// A shell command run in the desk's folder first; anything but exit 0
    /// skips the run ("only if there are new commits").
    public var precheck: String?
    /// Skip when the desk's vendor is at or past this much of its week.
    public var skipOverWeekPct: Double?
    public var enabled: Bool?

    public init(name: String, desk: String, prompt: String, at: String, days: [String]? = nil,
                precheck: String? = nil, skipOverWeekPct: Double? = nil, enabled: Bool? = nil) {
        self.name = name; self.desk = desk; self.prompt = prompt; self.at = at; self.days = days
        self.precheck = precheck; self.skipOverWeekPct = skipOverWeekPct; self.enabled = enabled
    }

    public var isOn: Bool { enabled ?? true }

    public enum Outcome: String, Codable, Equatable {
        case sent
        /// The precheck command said no.
        case skippedPrecheck = "skipped_precheck"
        /// The vendor is past the quota line you set.
        case skippedQuota = "skipped_quota"
        /// The desk wasn't running, was asking something, or you were typing in it.
        case skippedBusy = "skipped_busy"
        /// Its time passed while Coldfall was closed or asleep.
        case missed
        case failed

        public var words: String {
            switch self {
            case .sent: return "sent"
            case .skippedPrecheck: return "skipped: precheck said no"
            case .skippedQuota: return "skipped: over your quota line"
            case .skippedBusy: return "skipped: desk not ready"
            case .missed: return "missed (Coldfall wasn't running)"
            case .failed: return "failed"
            }
        }
    }

    public struct Run: Codable, Equatable {
        public var name: String
        public var at: Double
        public var outcome: Outcome
        public var note: String?
        public init(name: String, at: Double, outcome: Outcome, note: String? = nil) {
            self.name = name; self.at = at; self.outcome = outcome; self.note = note
        }
    }

    static let dayNumbers: [String: Int] = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]

    /// Hour and minute out of "09:00"; nil if it isn't a time.
    public var time: (hour: Int, minute: Int)? {
        let p = at.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// What's wrong with it, in words, or nil when it can run.
    public func problem(desks: [String]) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "It has no name." }
        if time == nil { return "\"\(at)\" isn't a time. Use 24-hour HH:MM, like 09:00." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "It has no prompt." }
        if let bad = (days ?? []).first(where: { Schedule.dayNumbers[$0.lowercased()] == nil }) {
            return "\"\(bad)\" isn't a day. Use mon, tue, wed, thu, fri, sat, sun."
        }
        if !desks.contains(desk) { return "There's no desk called \"\(desk)\"." }
        return nil
    }

    /// The latest moment at or before `now` it was due, looking back a week.
    public func lastDue(before now: Date, calendar: Calendar = .current) -> Date? {
        guard let t = time else { return nil }
        let wanted = Set((days ?? []).compactMap { Schedule.dayNumbers[$0.lowercased()] })
        for back in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now),
                  let at = calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day), at <= now else { continue }
            if wanted.isEmpty || wanted.contains(calendar.component(.weekday, from: at)) { return at }
        }
        return nil
    }

    /// How long after its time a run still counts as on time.
    public static let grace: TimeInterval = 15 * 60

    public enum Due: Equatable { case no, run(Date), missed(Date) }

    /// Whether it should run now. `handled` is the due time last dealt with
    /// (run, skipped or missed); `since` is when Coldfall started watching,
    /// so a schedule added today doesn't "miss" yesterday.
    public func due(now: Date, handled: Date?, since: Date, calendar: Calendar = .current) -> Due {
        guard isOn, let at = lastDue(before: now, calendar: calendar) else { return .no }
        if let h = handled, h >= at { return .no }
        if now.timeIntervalSince(at) <= Schedule.grace { return .run(at) }
        return at >= since ? .missed(at) : .no
    }

    public var when: String {
        let d = (days ?? []).map { $0.lowercased() }
        let which: String
        if d.isEmpty || Set(d) == Set(Schedule.dayNumbers.keys) { which = "every day" }
        else if Set(d) == ["mon", "tue", "wed", "thu", "fri"] { which = "weekdays" }
        else { which = d.joined(separator: ", ") }
        return "\(which) at \(at)"
    }

    // MARK: - the file and the log

    public static var path: String { (Limits.configDir as NSString).appendingPathComponent("schedules.json") }
    public static var logPath = NSString(string: "~/.local/share/coldfall/schedule-runs.jsonl").expandingTildeInPath

    public static func load(path: String = Schedule.path) -> [Schedule] {
        guard let d = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([Schedule].self, from: d)) ?? []
    }

    /// Whether the file is there but can't be read as schedules.
    public static func broken(path: String = Schedule.path) -> Bool {
        guard let d = FileManager.default.contents(atPath: path) else { return false }
        return (try? JSONDecoder().decode([Schedule].self, from: d)) == nil
    }

    /// What a new file starts as: one example, switched off.
    public static let template = """
    [
      {
        "name": "Morning plan",
        "desk": "hub",
        "at": "09:00",
        "days": ["mon", "tue", "wed", "thu", "fri"],
        "prompt": "Plan today from the notes in this folder.",
        "precheck": "",
        "skipOverWeekPct": 80,
        "enabled": false
      }
    ]

    """

    public static func record(_ run: Run, path: String = Schedule.logPath) {
        guard let d = try? JSONEncoder().encode(run), var line = String(data: d, encoding: .utf8) else { return }
        line += "\n"
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let fh = FileHandle(forWritingAtPath: path) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// The last `limit` runs, oldest first.
    public static func runs(path: String = Schedule.logPath, limit: Int = 200) -> [Run] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(limit).compactMap { try? JSONDecoder().decode(Run.self, from: Data($0.utf8)) }
    }

    /// The precheck, run in the desk's folder. True when there is none or it exits 0.
    public static func precheckPasses(_ command: String?, folder: String, timeout: TimeInterval = 60) -> Bool {
        guard let c = command?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", c]
        p.currentDirectoryURL = URL(fileURLWithPath: folder)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let r = Subprocess.drain(p, out: out, err: err, timeout: timeout)
        return !r.timedOut && p.terminationStatus == 0
    }
}
