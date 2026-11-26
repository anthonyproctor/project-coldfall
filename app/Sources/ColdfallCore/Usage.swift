import Foundation

/// Cross-vendor usage, read from what the CLIs already write to disk.
///
/// No API, no scraping, no credentials. Both vendors keep per-turn token records
/// locally, which is enough to answer the question that matters: where is the
/// week going, and who still has room.
///
///   Claude  ~/.claude/projects/<proj>/<session>.jsonl   message.usage
///   Codex   ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl  type=token_usage_record
///   Copilot ~/.copilot/session-store.db  assistant_usage_events (SQLite, read
///           with the system sqlite3 so the core stays Foundation only)
///
/// Two traps, both learned the hard way:
///
///  1. DEDUPE Claude on `message.id`. A streamed reply is written to the
///     transcript more than once; counting every record roughly doubled a real
///     30-day total.
///  2. Report TOKENS, not invented dollars. Claude's per-model prices are known
///     and worth showing. Frontier model pricing on the other side is not
///     something this tool should guess at, so it does not.
public enum Usage {

    public struct Bucket {
        public init() {}
        public var tokens: Int = 0
        public var usd: Double? = nil        // nil where pricing is not known
        public var calls: Int = 0
    }

    public struct Report {
        public init() {}
        public var byVendor: [String: Bucket] = [:]
        public var byDesk: [String: Bucket] = [:]      // Claude only: desks come from session titles
        public var byDay: [String: [String: Int]] = [:] // day -> vendor -> tokens
        /// Copilot premium requests since the start of the month, which is
        /// what a Copilot plan meters. Nil when there is no Copilot record.
        public var copilotPremium: Double? = nil
        public var generated = Date()
    }

    // Prices are in Pricing: one dated table, per-model cache rates.

    // Made once: building a formatter per line was a large share of a scan's
    // time (each one sets up an ICU locale). Formatters are safe to share
    // across threads for reading and writing dates.
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    static func iso(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

    static func dayKey(_ d: Date) -> String { dayFormat.string(from: d) }

    /// Anthropic's weekly window resets Saturday. Codex has its own cadence, but
    /// one shared boundary keeps the comparison honest.
    public static func weekStart() -> Date {
        let now = Date()
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day, .weekday], from: now)
        let back = ((c.weekday ?? 1) - 7 + 7) % 7      // Saturday == 7
        var start = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: now))!
        start = cal.date(byAdding: .hour, value: 11, to: start)!
        if start > now { start = cal.date(byAdding: .day, value: -7, to: start)! }
        c = DateComponents()
        return start
    }

    /// Every file seen in ONE pass, so the cache can drop entries for files
    /// that no longer exist instead of growing forever. Passed through the
    /// scan rather than held in a static: the meter strip and the usage panel
    /// each scan on their own background queue, and when two passes overlapped
    /// they both wrote to the one shared set and crashed the app inside
    /// Set.insert. Nothing here is shared between passes now.

    /// `accounts`: Claude accounts besides the default one, each counted
    /// under its own name ("claude-second") so two plans can be compared.
    /// `claudeRoot` is overridable for tests.
    private static let scanning = NSLock()

    public static func scan(since: Date, accounts: [ClaudeAccount] = [],
                            claudeRoot: String = NSString(string: "~/.claude/projects").expandingTildeInPath) -> Report {
        // One pass at a time. The meter strip, the usage panel and the desk
        // budgets each ask on their own queue; passes that overlapped stacked
        // up (each one slower for the others) until a Mac ran out of memory.
        // A caller that waits here gets a quick pass: the one before it has
        // just cached everything.
        scanning.lock(); defer { scanning.unlock() }
        var r = Report()
        var live = Set<String>()
        scanClaude(since: since, into: &r, live: &live, root: claudeRoot)
        for a in accounts {
            scanClaude(since: since, into: &r, live: &live, root: a.projectsRoot(), vendor: a.vendor)
        }
        scanCodex(since: since, into: &r, live: &live)
        scanCopilot(since: since, into: &r)
        UsageCache.flush(keeping: live)
        ClaudeTail.keep(live)
        return r
    }

    private static func add(_ r: inout Report, vendor: String, desk: String?,
                            tokens: Int, usd: Double?, when: Date) {
        var v = r.byVendor[vendor] ?? Bucket()
        v.tokens += tokens; v.calls += 1
        if let usd { v.usd = (v.usd ?? 0) + usd }
        r.byVendor[vendor] = v

        if let desk {
            var d = r.byDesk[desk] ?? Bucket()
            d.tokens += tokens; d.calls += 1
            if let usd { d.usd = (d.usd ?? 0) + usd }
            r.byDesk[desk] = d
        }
        let k = dayKey(when)
        r.byDay[k, default: [:]][vendor, default: 0] += tokens
    }

    private static func scanClaude(since: Date, into r: inout Report, live: inout Set<String>,
                                   root: String = NSString(string: "~/.claude/projects").expandingTildeInPath,
                                   vendor: String = "claude") {
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        var titles: [String: String?] = [:]
        for proj in projects {
            let dir = (root as NSString).appendingPathComponent(proj)
            for (path, parent) in transcripts(in: dir) {
                live.insert(path)
                // A subagent's transcript has no title of its own; its spend
                // belongs to the desk that ran it.

                // A file untouched since before the window opened cannot
                // contribute to it. This gate was missing entirely, and on a
                // real machine it meant 262MB of 823MB was opened and parsed
                // for nothing on every single refresh.
                guard let fp = UsageCache.fingerprint(path), fp.modified >= since else { continue }

                // Unchanged since last time means the same numbers as last
                // time. Reuse them rather than re-deriving them.
                if let cached = UsageCache.slices(for: path, key: fp.key, since: since) {
                    for sl in cached { addSlice(&r, sl) }
                    continue
                }

                // Read only what was added since the last pass (see ClaudeTail).
                // The parent's title is looked up only when reading starts from
                // the top; searching a big parent each pass was most of the work.
                guard let slices = ClaudeTail.read(path, since: since, vendor: vendor,
                                                   desk: parent.flatMap { title(ofTranscript: $0, cache: &titles) }) else { continue }
                UsageCache.store(slices, for: path, key: fp.key, since: since)
                for sl in slices { addSlice(&r, sl) }
            }
        }
    }

    /// Every transcript in a project folder: the sessions at the top, and
    /// each session's subagents under <session>/subagents/. Claude bills a
    /// subagent's turns like any other, so a scan that stopped at the top
    /// level missed them: 241 files on one Mac. Each subagent file comes
    /// with its parent session's transcript, for the desk it belongs to.
    public static func transcripts(in dir: String) -> [(path: String, parent: String?)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [(String, String?)] = []
        for e in entries.sorted() {
            let p = (dir as NSString).appendingPathComponent(e)
            if e.hasSuffix(".jsonl") { out.append((p, nil)); continue }
            let sub = (p as NSString).appendingPathComponent("subagents")
            guard let agents = try? fm.contentsOfDirectory(atPath: sub) else { continue }
            let parent = p + ".jsonl"
            for a in agents.sorted() where a.hasSuffix(".jsonl") {
                out.append(((sub as NSString).appendingPathComponent(a), parent))
            }
        }
        return out
    }

    /// The title a session's transcript carries, read without parsing the
    /// whole file (one mapped search for the record), cached per scan.
    public static func title(ofTranscript path: String, cache: inout [String: String?]) -> String? {
        if let hit = cache[path] { return hit }
        var found: String? = nil
        let needle = Data("{\"type\":\"custom-title\",\"customTitle\":\"".utf8)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) {
            var from = data.startIndex
            while let r = data.range(of: needle, in: from..<data.endIndex) {
                if r.lowerBound == data.startIndex || data[r.lowerBound - 1] == 0x0A {
                    var end = r.upperBound
                    while end < data.endIndex, data[end] != 0x22, data[end] != 0x0A { end += 1 }
                    found = String(decoding: data[r.upperBound..<end], as: UTF8.self)
                    break
                }
                from = r.upperBound
            }
        }
        cache[path] = found
        return found
    }

    /// Accumulate one message into a per-file bundle, keyed so a whole
    /// transcript collapses to a handful of rows before it is cached.
    static func collect(_ into: inout [String: UsageSlice], vendor: String,
                                desk: String?, tokens: Int, usd: Double?, when: Date) {
        let day = dayKey(when)
        let k = "\(vendor)|\(desk ?? "")|\(day)"
        var sl = into[k] ?? UsageSlice(vendor: vendor, desk: desk, day: day,
                                       tokens: 0, calls: 0, usd: nil)
        sl.tokens += tokens
        sl.calls += 1
        if let usd { sl.usd = (sl.usd ?? 0) + usd }
        into[k] = sl
    }

    /// Fold a cached or freshly-computed slice into the report. The only path
    /// that writes to the report, so cached and uncached files cannot drift.
    private static func addSlice(_ r: inout Report, _ sl: UsageSlice) {
        var v = r.byVendor[sl.vendor] ?? Bucket()
        v.tokens += sl.tokens; v.calls += sl.calls
        if let u = sl.usd { v.usd = (v.usd ?? 0) + u }
        r.byVendor[sl.vendor] = v

        if let d = sl.desk, !d.isEmpty {
            var b = r.byDesk[d] ?? Bucket()
            b.tokens += sl.tokens; b.calls += sl.calls
            if let u = sl.usd { b.usd = (b.usd ?? 0) + u }
            r.byDesk[d] = b
        }
        r.byDay[sl.day, default: [:]][sl.vendor, default: 0] += sl.tokens
    }

    /// Where reading each Codex session stopped, between passes.
    static let codexTail = LineTail<[String: UsageSlice]>()
    private static let codexMark = Data("token_usage_record".utf8)

    private static func scanCodex(since: Date, into r: inout Report, live: inout Set<String>,
                                  root: String = NSString(string: "~/.codex/sessions").expandingTildeInPath) {
        guard let e = FileManager.default.enumerator(atPath: root) else { return }
        var seen = Set<String>()
        defer { codexTail.keep(seen) }
        for case let rel as String in e where rel.hasSuffix(".jsonl") {
            let path = (root as NSString).appendingPathComponent(rel)
            live.insert(path); seen.insert(path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let m = attrs[.modificationDate] as? Date, m >= since else { continue }
            // Only what the session gained since the last pass (see LineTail).
            let got = codexTail.read(path, tag: "\(since.timeIntervalSince1970)", fresh: { [:] }) { line, mine in
                guard line.range(of: codexMark) != nil,
                      let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      o["type"] as? String == "token_usage_record",
                      let p = o["payload"] as? [String: Any],
                      let u = p["usage"] as? [String: Any],
                      let ts = o["timestamp"] as? String, let when = iso(ts), when >= since else { return }
                // Pricing for these models is not something this tool should guess.
                collect(&mine, vendor: "codex", desk: nil, tokens: u["total_tokens"] as? Int ?? 0, usd: nil, when: when)
            }
            for sl in (got ?? [:]).values { addSlice(&r, sl) }
        }
    }

    /// Overridable so tests read a fixture instead of the real database.
    public static var copilotDB = NSString(string: "~/.copilot/session-store.db").expandingTildeInPath

    /// The first moment of this calendar month. Copilot plans reset monthly.
    public static func monthStart(_ now: Date = Date()) -> Date {
        // GitHub's cycle turns over at midnight UTC, not local midnight.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.dateInterval(of: .month, for: now)?.start ?? now
    }

    private static func scanCopilot(since: Date, into r: inout Report) {
        guard FileManager.default.fileExists(atPath: copilotDB) else { return }
        let month = monthStart()
        let from = min(since, month)
        let f = ISO8601DateFormatter()
        // created_at is ISO 8601 in UTC, so a string compare is a time compare.
        let q = "select created_at, input_tokens, output_tokens, initiator, request_multiplier "
              + "from assistant_usage_events where created_at >= '\(f.string(from: from))'"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-separator", "\t", copilotDB, q]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return }
        let rows = copilotRows(String(decoding: data, as: UTF8.self))
        var premium = 0.0
        for row in rows {
            if row.when >= month { premium += row.premium }
            if row.when >= since {
                add(&r, vendor: "copilot", desk: nil, tokens: row.tokens, usd: nil, when: row.when)
            }
        }
        r.copilotPremium = premium
    }

    public struct CopilotRow: Equatable {
        public let when: Date
        public let tokens: Int
        /// Premium requests this call used: the model's multiplier for a turn
        /// the person started, nothing for the agent's own follow-up calls.
        public let premium: Double
    }

    /// Tab-separated rows of created_at, input, output, initiator, multiplier.
    /// Input already includes cached tokens, so input plus output is the total.
    public static func copilotRows(_ text: String) -> [CopilotRow] {
        text.split(separator: "\n").compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 5, let when = iso(c[0]) else { return nil }
            let tokens = (Int(c[1]) ?? 0) + (Int(c[2]) ?? 0)
            let premium = c[3] == "user" ? (Double(c[4]) ?? 1) : 0
            return CopilotRow(when: when, tokens: tokens, premium: premium)
        }
    }

    /// The router call: who has room, stated only when the gap is real.
    public static func routerHint(_ r: Report) -> String? {
        let v = r.byVendor.filter { $0.value.tokens > 0 }
        guard v.count >= 2 else { return nil }
        let sorted = v.sorted { $0.value.tokens > $1.value.tokens }
        guard let hot = sorted.first, let cold = sorted.last, hot.key != cold.key else { return nil }
        let total = v.values.reduce(0) { $0 + $1.tokens }
        guard total > 0 else { return nil }
        let hotShare = Double(hot.value.tokens) / Double(total)
        guard hotShare > 0.70 else { return nil }
        return "\(Int((hotShare * 100).rounded()))% of this week is on \(hot.key). \(cold.key) is barely touched."
    }
}
