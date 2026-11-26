// Where a week's tokens actually went, and what to change.
//
// The meter answers "how much". This answers "why", from the same records,
// because a week that ran out is rarely explained by the total. Four things
// explain most of it:
//
//   1. WHAT EVERY TURN CARRIES. Each request re-sends the conversation so
//      far, the system prompt, the tool definitions of every MCP server the
//      desk started, the memory files, and whatever hooks printed. Measured
//      as the smallest input any turn sent all week: nothing was sent for
//      less, so that is what the desk pays to say anything.
//   2. CACHE. A cache READ costs a small fraction of fresh input (a tenth,
//      or less on the newest models); a cache WRITE costs double, since Claude
//      Code writes the one-hour cache. A warm turn is a cache read, so
//      rebuilding the same conversation after a break costs 20 to 40 TIMES
//      that turn. Reused context is nearly free, rebuilt context is not,
//      so the split between them is the difference between a cheap week and
//      an expensive one.
//   3. MODEL. The same work on a smaller model costs a fraction. What the
//      week would have cost on Sonnet is arithmetic, not an opinion.
//   4. THE DESK. Cost per turn varies enormously between desks doing
//      different work, and the outlier is the one worth looking at.
//
// Everything here is read from files the CLIs already write. Nothing is sent
// anywhere, and anything that is an estimate says so where it is shown.

import Foundation

public struct Tokenomics {

    /// One desk's week.
    public struct DeskStats: Equatable, Codable {
        public var turns = 0
        /// Input that was not served from cache: the expensive kind.
        public var fresh = 0
        public var cacheRead = 0
        public var cacheWrite = 0
        public var output = 0
        public var usd: Double = 0
        /// Tokens per model, to see the mix.
        public var byModel: [String: Int] = [:]
        /// The smallest input any turn sent this week. Nothing can be sent
        /// for less than the system prompt, the memory files, hook output and
        /// the tool definitions of every MCP server the desk starts, so the
        /// cheapest turn of the week is what the desk pays to say anything.
        ///
        /// The first record of a transcript looked like the obvious place for
        /// this and was wrong: reopening a conversation re-sends the whole
        /// history, so it read as 800K tokens of "overhead" that was really
        /// the conversation itself.
        public var floor: Int = 0
        /// Turns that rebuilt a big conversation's cache: coming back to it
        /// after the cache had expired. Most of that turn is written to cache
        /// at twice the normal price (the one-hour cache Claude Code uses).
        public var rebuilds = 0
        /// What those rebuilds cost, at list prices.
        public var rebuildUsd: Double = 0
        /// Tool output that landed in the conversation, by kind ("command
        /// output", "file reads"...), estimated in tokens. It is paid again on
        /// every later turn, which is why a desk's conversation grows.
        public var toolTokens: [String: Int] = [:]
        /// Images among it: screenshots, and pictures a desk read.
        public var images = 0
        /// Jobs handed to a subagent, whose raw output never reached this
        /// conversation: only the answer did.
        public var subagents = 0
        public var toolTotal: Int { toolTokens.values.reduce(0, +) }
        public var input: Int { fresh + cacheRead + cacheWrite }
        public var total: Int { input + output }
        public var perTurn: Double { turns > 0 ? Double(total) / Double(turns) : 0 }
        public var usdPerTurn: Double { turns > 0 ? usd / Double(turns) : 0 }

        public init() {}
    }

    public var byDesk: [String: DeskStats] = [:]
    /// Everything, including turns that belong to no named desk.
    public var all = DeskStats()
    public var generated = Date()
    public init() {}

    public var freshShare: Double { all.input > 0 ? Double(all.fresh) / Double(all.input) : 0 }
    public var cacheReadShare: Double { all.input > 0 ? Double(all.cacheRead) / Double(all.input) : 0 }
    /// Input that was NOT a cache read: fresh, or written to cache (which
    /// costs double, the most expensive kind).
    public var uncachedShare: Double { all.input > 0 ? Double(all.fresh + all.cacheWrite) / Double(all.input) : 0 }

    /// Share of tokens per model, biggest first.
    public var modelMix: [(model: String, share: Double)] {
        let total = all.byModel.values.reduce(0, +)
        guard total > 0 else { return [] }
        return all.byModel.map { ($0.key, Double($0.value) / Double(total)) }
            .sorted { $0.1 > $1.1 }
    }

    // MARK: - reading

    /// A model's (input, output) prices: see Pricing.
    public static func price(_ model: String) -> (Double, Double) {
        let m = Pricing.model(model); return (m.input, m.output)
    }

    /// A model id as a person says it: "claude-opus-5" is "opus".
    public static func family(_ model: String) -> String {
        for f in ["fable", "opus", "sonnet", "haiku"] where model.contains(f) { return f }
        return model.isEmpty ? "unknown" : model
    }

    /// Read Claude's transcripts for the window. `root` and the file list are
    /// injectable so tests read a fixture rather than a real home.
    public static func scan(since: Date,
                            root: String = NSString(string: "~/.claude/projects").expandingTildeInPath,
                            accounts: [ClaudeAccount] = []) -> Tokenomics {
        var t = Tokenomics()
        for r in [root] + accounts.map({ $0.projectsRoot() }) {
            scan(root: r, since: since, into: &t)
        }
        return t
    }

    static func scan(root: String, since: Date, into t: inout Tokenomics) {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: root) else { return }
        var titles: [String: String?] = [:]
        var live = Set<String>()
        defer { tail.keep(live) }
        for proj in projects {
            let dir = (root as NSString).appendingPathComponent(proj)
            // Sessions and their subagents' transcripts, see Usage.transcripts.
            for (path, parent) in Usage.transcripts(in: dir) {
                live.insert(path)
                guard let fp = UsageCache.fingerprint(path), fp.modified >= since else { continue }
                // A transcript that has not changed gives the same answer as
                // last time. Without this the panel re-parsed 800MB on every
                // open, which took ten seconds.
                if let hit = TokenomicsCache.stats(for: path, key: fp.key, since: since) {
                    t.merge(hit)
                    continue
                }
                // Only what the file gained since the last look (see LineTail).
                guard let got = tail.read(path, tag: "\(since.timeIntervalSince1970)|\(Pricing.checked)",
                                          fresh: { Reading(desk: parent.flatMap { Usage.title(ofTranscript: $0, cache: &titles) }) },
                                          line: { take($0, into: &$1, since: since) }) else { continue }
                TokenomicsCache.store(got.t, for: path, key: fp.key, since: since)
                t.merge(got.t)
            }
        }
    }

    /// Fold one transcript's numbers in.
    mutating func merge(_ other: Tokenomics) {
        Tokenomics.add(other.all, to: &all)
        for (name, s) in other.byDesk {
            var mine = byDesk[name] ?? DeskStats()
            Tokenomics.add(s, to: &mine)
            byDesk[name] = mine
        }
    }

    static func add(_ s: DeskStats, to out: inout DeskStats) {
        out.turns += s.turns
        out.fresh += s.fresh; out.cacheRead += s.cacheRead; out.cacheWrite += s.cacheWrite
        out.output += s.output; out.usd += s.usd
        for (m, n) in s.byModel { out.byModel[m, default: 0] += n }
        if s.floor > 0, out.floor == 0 || s.floor < out.floor { out.floor = s.floor }
        out.rebuilds += s.rebuilds; out.rebuildUsd += s.rebuildUsd
        for (k, v) in s.toolTokens { out.toolTokens[k, default: 0] += v }
        out.images += s.images; out.subagents += s.subagents
    }

    /// Roughly what one image costs in a conversation, whatever its size on
    /// disk. Counting a screenshot by its encoded bytes made one look like
    /// hundreds of thousands of tokens.
    public static let imageTokens = 1600
    public static let subagentKind = "subagent answers"
    /// Tool output worth a word, for one desk in a week.
    public static let contentsTokens = 300_000
    /// Images worth a word, across a week.
    public static let manyImages = 100

    /// A tool, as a person would name what it put into the conversation.
    public static func toolKind(_ name: String) -> String {
        switch name {
        case "Bash": return "command output"
        case "Read": return "file reads"
        case "Grep", "Glob", "LS": return "searches"
        case "WebSearch", "WebFetch": return "web pages"
        case "Task", "Agent": return subagentKind
        default:
            let n = name.lowercased()
            if n.hasPrefix("mcp__") && (n.contains("chrome") || n.contains("browser") || n.contains("playwright")) {
                return "browser automation"
            }
            if n.hasPrefix("mcp__") { return "MCP tools" }
            return "other tools"
        }
    }

    /// A tool result's size in tokens, estimated at four characters a token,
    /// with images counted as images.
    public static func measure(_ content: Any?) -> (tokens: Int, images: Int) {
        // UTF-16 length, not Character count: the same for plain text, and
        // known without walking a large result character by character.
        if let s = content as? String { return (s.utf16.count / 4, 0) }
        guard let items = content as? [[String: Any]] else { return (0, 0) }
        var tok = 0, imgs = 0
        for it in items {
            if it["type"] as? String == "image" { imgs += 1; tok += imageTokens }
            else if let s = it["text"] as? String { tok += s.utf16.count / 4 }
        }
        return (tok, imgs)
    }

    /// A cache write this big is a conversation being rebuilt, not one
    /// growing by a message.
    public static let rebuildTokens = 50_000
    /// How long Claude Code's cache lives after the last message (it writes
    /// the one-hour cache).
    public static let cacheLifetime: TimeInterval = 3600

    /// One transcript. Records are deduplicated on message id, as in Usage: a
    /// streamed reply is written more than once and counting each would
    /// roughly double everything here too.
    /// `desk` is the desk to attribute to when the transcript names none
    /// (a subagent's), from its parent session.
    public static func read(_ text: String, since: Date, into t: inout Tokenomics, desk hint: String? = nil) {
        var r = Reading(desk: hint)
        r.t = t
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            take(Data(line.utf8), into: &r, since: since)
        }
        t = r.t
    }

    /// Reading one transcript: what it has added up to, and what a later line
    /// needs from earlier ones.
    struct Reading {
        var t = Tokenomics()
        var desk: String?
        var seen = Set<String>()
        // When the previous turn in THIS transcript happened: a rebuild is a
        // big write after the cache had time to lapse, not any big write.
        var lastTurn: Date? = nil
        // Which tool each call was, so its result can be sized by kind.
        var tools: [String: String] = [:]
        init(desk: String?) { self.desk = desk }
    }

    /// Where reading each transcript stopped, between passes.
    static let tail = LineTail<Reading>()

    private static let marks = ["\"usage\"", "\"tool_use\"", "\"tool_result\"", "\"custom-title\""].map { Data($0.utf8) }

    /// One line of a transcript.
    static func take(_ line: Data, into r: inout Reading, since: Date) {
        // Only a reply, a tool call or result, or the title says anything here.
        guard marks.contains(where: { line.range(of: $0) != nil }),
              let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if r.desk == nil, o["type"] as? String == "custom-title" { r.desk = o["customTitle"] as? String }
        let desk = r.desk
        // Tool calls and their results: what fills a conversation up.
        if let msg = o["message"] as? [String: Any], let blocks = msg["content"] as? [[String: Any]],
           let ts = o["timestamp"] as? String, let when = Usage.iso(ts), when >= since {
            for b in blocks {
                switch b["type"] as? String {
                case "tool_use":
                    guard let id = b["id"] as? String, let name = b["name"] as? String,
                          r.tools[id] == nil else { continue }
                    r.tools[id] = name
                    if Tokenomics.toolKind(name) == Tokenomics.subagentKind {
                        r.t.all.subagents += 1
                        if let n = desk, !n.isEmpty { r.t.byDesk[n, default: DeskStats()].subagents += 1 }
                    }
                case "tool_result":
                    guard let id = b["tool_use_id"] as? String, let name = r.tools[id] else { continue }
                    let (tok, imgs) = Tokenomics.measure(b["content"])
                    let kind = Tokenomics.toolKind(name)
                    r.t.all.toolTokens[kind, default: 0] += tok
                    r.t.all.images += imgs
                    if let n = desk, !n.isEmpty {
                        r.t.byDesk[n, default: DeskStats()].toolTokens[kind, default: 0] += tok
                        r.t.byDesk[n, default: DeskStats()].images += imgs
                    }
                default: break
                }
            }
        }
        guard let msg = o["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any] else { return }
        if let id = msg["id"] as? String {
            if r.seen.contains(id) { return }
            r.seen.insert(id)
        }
        guard let ts = o["timestamp"] as? String, let when = Usage.iso(ts), when >= since else { return }

        let fresh = u["input_tokens"] as? Int ?? 0
        let write = u["cache_creation_input_tokens"] as? Int ?? 0
        let read = u["cache_read_input_tokens"] as? Int ?? 0
        let out = u["output_tokens"] as? Int ?? 0
        let model = msg["model"] as? String ?? ""
        let (w5, w1) = Pricing.writeSplit(u)
        let usd = Pricing.cost(model: model, fresh: fresh, read: read, write: write,
                               write5m: w5, write1h: w1, output: out)
        let rebuildCost = Pricing.writeCost(model: model, write: write, write5m: w5, write1h: w1)
        let lastTurn = r.lastTurn

        func add(_ s: inout DeskStats) {
            s.turns += 1
            s.fresh += fresh; s.cacheWrite += write; s.cacheRead += read; s.output += out
            s.usd += usd
            s.byModel[family(model), default: 0] += fresh + write + read + out
            let sent = fresh + write + read
            if sent > 0, s.floor == 0 || sent < s.floor { s.floor = sent }
            // A rebuild: most of a big turn written to cache rather than
            // read from it, an hour or more after the previous turn of
            // the same conversation. A new conversation's first turn, a
            // compaction and a big file read mid-flow all write a lot too,
            // and used to be counted; none of them is a break.
            if write >= Tokenomics.rebuildTokens, write > read,
               let prev = lastTurn, when.timeIntervalSince(prev) >= Tokenomics.cacheLifetime {
                s.rebuilds += 1
                s.rebuildUsd += rebuildCost
            }
        }
        add(&r.t.all)
        if let name = desk, !name.isEmpty {
            var s = r.t.byDesk[name] ?? DeskStats()
            add(&s)
            r.t.byDesk[name] = s
        }
        r.lastTurn = when
    }
}

// MARK: - what to change

extension Tokenomics {

    public struct Note: Equatable {
        /// What it is about, so the app can order and colour them.
        public enum Kind: String, Equatable { case cache, start, model, desk, rebuild, contents, images }
        public let kind: Kind
        /// The finding, in numbers from this week.
        public let finding: String
        /// What to do about it.
        public let advice: String
        /// True when the number is arithmetic on what was recorded, false
        /// when it is a projection. Shown, never blurred.
        public let measured: Bool
        public init(_ kind: Kind, _ finding: String, _ advice: String, measured: Bool = true) {
            self.kind = kind; self.finding = finding; self.advice = advice; self.measured = measured
        }
    }

    /// Reading the week back as things to change. `servers` is how many MCP
    /// servers each desk starts, which the app reads from the vendors' files;
    /// without it the advice simply says less.
    public func notes(servers: [String: Int] = [:], minTurns: Int = 20) -> [Note] {
        var out: [Note] = []
        guard all.turns >= minTurns else { return out }

        // 1. Reuse. A cache read costs a small fraction of fresh input; rebuilding
        // context instead of reusing it is the quietest way to burn a week.
        if uncachedShare > 0.30 {
            out.append(Note(.cache,
                String(format: "%.0f%% of what you sent was not read from cache: fresh context, or context being written to cache at double price.", uncachedShare * 100),
                "Cache is reused while a conversation keeps going and expires in the gaps. "
                + "Fewer, longer sittings at one desk cost less than the same work spread out."))
        } else if cacheReadShare > 0.70, uncachedShare < 0.15 {
            out.append(Note(.cache,
                String(format: "%.0f%% of your input was read from cache, at a small fraction of the price.", cacheReadShare * 100),
                "Nothing to change here. This is the cheap way to work."))
        }

        // 1b. Coming back to big conversations after a break.
        if all.rebuilds >= 3, all.rebuildUsd >= 10 {
            let worst = byDesk.max { $0.value.rebuildUsd < $1.value.rebuildUsd }
            var finding = String(format: "Coming back to big conversations after a break rebuilt their cache "
                                 + "%d times this week, about $%.0f.", all.rebuilds, all.rebuildUsd)
            if let (name, s) = worst, s.rebuildUsd >= all.rebuildUsd * 0.4 {
                finding += String(format: " %@ was about $%.0f of it.", name, s.rebuildUsd)
            }
            out.append(Note(.rebuild, finding,
                "The break causes this, not stopping the desk: Claude's cache lasts an hour after "
                + "the last message either way. When you reopen a big desk you haven't used in a while, Coldfall offers "
                + "to start fresh. Take it when the topic has moved on and what matters is saved."))
        }

        // 1c. What is filling the conversations, and the one habit that
        // keeps a big desk small: handing messy jobs to a subagent, whose
        // raw output never enters the desk's own conversation.
        if let (name, s) = byDesk.max(by: { $0.value.toolTotal < $1.value.toolTotal }),
           s.toolTotal >= Tokenomics.contentsTokens {
            let top = s.toolTokens.filter { $0.key != Tokenomics.subagentKind }
                .sorted { $0.value > $1.value }.prefix(2)
            let parts = top.map { "\($0.key) (~\(Tokenomics.short($0.value)))" }.joined(separator: " and ")
            var advice: String
            switch top.first?.key {
            case "command output":
                advice = "Ask for the part of a command's output you need, like the last lines or a count, "
                       + "rather than the whole log. For a broad search or a long investigation, ask it to "
                       + "use a subagent: only the answer comes back into the conversation."
            case "browser automation":
                advice = "Browser tools send page snapshots and screenshots back each time. For a long "
                       + "browsing job, ask it to use a subagent to do the clicking and report back."
            default:
                advice = "For broad searches or reading many files, ask it to use a subagent: it does "
                       + "the reading in its own conversation, and only the answer comes back into this one."
            }
            advice += s.subagents > 0
                ? " It handed \(s.subagents) job\(s.subagents == 1 ? "" : "s") to subagents this week."
                : " It didn't use a subagent once this week."
            out.append(Note(.contents,
                "\(name)'s conversation took in about \(Tokenomics.short(s.toolTotal)) tokens of tool output "
                + "this week, mostly \(parts). Each of those is sent again on every later turn.",
                advice, measured: false))
        }
        if all.images >= Tokenomics.manyImages {
            out.append(Note(.images,
                "\(all.images) images went into conversations this week, about "
                + "\(Tokenomics.short(all.images * Tokenomics.imageTokens)) tokens, each sent again on every "
                + "later turn of its conversation.",
                "Ask for a screenshot when you need to see something. A page's text, or one element of "
                + "it, usually answers the question for far less.",
                measured: false))
        }

        // 2. What a desk pays before you type anything.
        let starters = byDesk.filter { $0.value.turns >= 5 }
            .sorted { $0.value.floor > $1.value.floor }
        if let (name, s) = starters.first, s.floor >= 20_000 {
            // Two things make a floor: the conversation so far, and what is
            // loaded before you type. Both are re-sent every turn, and the
            // advice names both rather than guessing which one it is.
            var advice = "Every turn re-sends the conversation so far, plus what's loaded before you "
                       + "type: your memory files, hook output, and the tool definitions of every MCP "
                       + "server the desk starts. If the topic has moved on, a new conversation drops "
                       + "the first part."
            if let n = servers[name], n > 0 {
                advice += " For the second, \(name) starts \(n) MCP server\(n == 1 ? "" : "s"): "
                        + "right-click the desk, MCP Servers, and switch off the ones it doesn't need."
            }
            out.append(Note(.start,
                "Every turn on \(name) sent at least \(Tokenomics.short(s.floor)) tokens.", advice))
        }

        // 3. Model mix, with the arithmetic for a smaller one.
        if let top = modelMix.first, top.model == "opus" || top.model == "fable", top.share > 0.5 {
            let saved = savingsOnSonnet()
            out.append(Note(.model,
                String(format: "%.0f%% of this week ran on %@.", top.share * 100, top.model),
                saved > 1
                    ? String(format: "The same tokens on Sonnet would have cost about $%.0f instead of $%.0f. "
                             + "Set `model` on the desks doing routine work.", saved, all.usd)
                    : "Set `model` on the desks doing routine work and keep the big model for the hard ones.",
                measured: false))
        }

        // 4. The desk that costs most per turn, when it is well clear of the rest.
        let busy = byDesk.filter { $0.value.turns >= 10 }
        if busy.count >= 3 {
            let perTurns = busy.map(\.value.perTurn).sorted()
            let median = perTurns[perTurns.count / 2]
            if let (name, s) = busy.max(by: { $0.value.perTurn < $1.value.perTurn }),
               median > 0, s.perTurn > median * 2.5 {
                out.append(Note(.desk,
                    "\(name) costs \(Tokenomics.short(Int(s.perTurn))) tokens a turn, "
                    + "\(String(format: "%.1f", s.perTurn / median))x the middle desk.",
                    "Look at what it loads and what it's asked to read. A desk that reads whole "
                    + "folders to answer small questions is the usual reason."))
            }
        }
        return out
    }

    /// What this week's tokens would have cost on Sonnet, model for model.
    /// A projection: the same work on a smaller model is not the same work.
    public func savingsOnSonnet() -> Double {
        Pricing.cost(model: "claude-sonnet-5", fresh: all.fresh, read: all.cacheRead,
                     write: all.cacheWrite, output: all.output)
    }

    public static func short(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return "\(n / 1000)K" }
        return "\(n)"
    }
}

/// One transcript's numbers, kept so the panel does not re-parse the lot on
/// every open. Derived data: deleting it costs one slow read.
public enum TokenomicsCache {
    struct Entry: Codable {
        var key: String
        var since: Double
        var all: Tokenomics.DeskStats
        var byDesk: [String: Tokenomics.DeskStats]
    }

    /// Overridable so tests never touch a real home.
    public static var root: String =
        NSString(string: "~/.local/share/coldfall/cache").expandingTildeInPath
    public static var path: String { (root as NSString).appendingPathComponent("tokenomics.json") }

    private static var loaded: [String: Entry]?
    private static var dirty = false
    private static let lock = NSLock()

    static func all() -> [String: Entry] {
        if let l = loaded { return l }
        let l = (try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        loaded = l
        return l
    }

    /// Bumped when what a slice records changes, so old slices are re-read.
    public static let rules = "2"

    public static func stats(for path: String, key: String, since: Date) -> Tokenomics? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = all()[path], hit.key == key + ":" + rules,
              abs(hit.since - since.timeIntervalSince1970) < 1 else { return nil }
        var t = Tokenomics()
        t.all = hit.all
        t.byDesk = hit.byDesk
        return t
    }

    public static func store(_ t: Tokenomics, for path: String, key: String, since: Date) {
        lock.lock(); defer { lock.unlock() }
        var l = all()
        l[path] = Entry(key: key + ":" + rules, since: since.timeIntervalSince1970, all: t.all, byDesk: t.byDesk)
        loaded = l
        dirty = true
        flushLocked()
    }

    /// Written as it goes rather than at the end: this cache is read by the
    /// panel and by the CLI, and neither owns the end of the other's scan.
    private static func flushLocked() {
        guard dirty, let l = loaded else { return }
        dirty = false
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(l) else { return }
        try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func clear() {
        lock.lock(); defer { lock.unlock() }
        loaded = [:]
        dirty = false
        try? FileManager.default.removeItem(atPath: path)
    }
}
