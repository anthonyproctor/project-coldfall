import Foundation

/// Remaining quota, per vendor.
///
/// Consumption is easy — both CLIs write token records to disk. Quota is the
/// hard half, and each vendor exposes it differently:
///
///   Codex   writes it straight into the session rollout: an `event_msg` whose
///           payload carries `rate_limits` with a `primary` and `secondary`
///           window. Classified by `window_minutes` (300 = 5h, 10080 = week)
///           rather than by position, because position is not a contract.
///
///   Claude  tells only its statusline. So Coldfall offers to BE that
///           statusline: a recorder captures the numbers and then chains to
///           whatever statusline you already had, printing its output unchanged.
///
///   Anyone  drop `~/.local/share/coldfall/limits/<vendor>.json` with the same
///           shape and it appears. That is the extension point — a vendor
///           Coldfall has never heard of needs no code change here.
public struct VendorLimits: Codable {
    public var vendor: String
    public var weekPct: Double?
    public var weekResetsAt: Double?
    public var fiveHourPct: Double?
    public var fiveHourResetsAt: Double?
    public var planType: String?
    public var at: Double = 0

    public init(vendor: String, weekPct: Double? = nil, weekResetsAt: Double? = nil,
                fiveHourPct: Double? = nil, fiveHourResetsAt: Double? = nil,
                planType: String? = nil, at: Double = 0) {
        self.vendor = vendor; self.weekPct = weekPct; self.weekResetsAt = weekResetsAt
        self.fiveHourPct = fiveHourPct; self.fiveHourResetsAt = fiveHourResetsAt
        self.planType = planType; self.at = at
    }

    public var age: TimeInterval { Date().timeIntervalSince1970 - at }

    /// A vendor you have not touched in hours is precisely the one with room,
    /// so an old reading is still worth showing — the weekly number barely
    /// moves while you are idle. A day is the point where it stops being
    /// trustworthy. Show the age instead of hiding the number.
    public var isUsable: Bool { age < 86_400 }
    public var isStale: Bool { age > 1_200 }

    /// A window whose reset time has passed has rolled over; its percentage is
    /// meaningless now. Drop those rather than report a number from last cycle.
    public var liveWeekPct: Double? {
        guard let r = weekResetsAt, r > Date().timeIntervalSince1970 else { return nil }
        return weekPct
    }
    public var liveFiveHourPct: Double? {
        guard let r = fiveHourResetsAt, r > Date().timeIntervalSince1970 else { return nil }
        return fiveHourPct
    }

    public var ageLabel: String? {
        guard isStale else { return nil }
        let m = Int(age / 60)
        return m < 120 ? "\(m)m ago" : "\(m / 60)h ago"
    }
}

public enum Limits {
    public static var dir: String { NSString(string: "~/.local/share/coldfall/limits").expandingTildeInPath }
    /// Where the recorder scripts live. Overridable so tests never write to
    /// the real config directory.
    public static var configDir: String = NSString(string: "~/.config/coldfall").expandingTildeInPath
    public static var recorderPath: String {
        (configDir as NSString).appendingPathComponent("statusline-recorder.sh")
    }

    /// Every vendor we can currently see, freshest wins, stale dropped.
    /// A number that has moved is worse than no number.
    public static func all() -> [VendorLimits] {
        var out: [VendorLimits] = []
        if let c = fromDroppedFile("claude") ?? legacyClaudeFile() { out.append(c) }
        if let x = fromCodexRollouts() { out.append(x) }
        for v in ["antigravity", "copilot"] {
            if let g = fromDroppedFile(v) { out.append(g) }
        }
        // Anything else someone dropped in.
        if let extra = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for f in extra where f.hasSuffix(".json") {
                let name = String(f.dropLast(5))
                if out.contains(where: { $0.vendor == name }) { continue }
                if let v = fromDroppedFile(name) { out.append(v) }
            }
        }
        return out.filter(\.isUsable)
    }

    private static func fromDroppedFile(_ vendor: String) -> VendorLimits? {
        let p = (dir as NSString).appendingPathComponent("\(vendor).json")
        guard let d = FileManager.default.contents(atPath: p),
              var v = try? JSONDecoder().decode(VendorLimits.self, from: d) else { return nil }
        v.vendor = vendor
        return v
    }

    /// Earlier builds wrote a single flat file; keep reading it.
    private static func legacyClaudeFile() -> VendorLimits? {
        let p = NSString(string: "~/.local/share/coldfall/limits.json").expandingTildeInPath
        guard let d = FileManager.default.contents(atPath: p),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return VendorLimits(vendor: "claude",
                            weekPct: (o["weekPct"] as? NSNumber)?.doubleValue,
                            weekResetsAt: (o["weekResetsAt"] as? NSNumber)?.doubleValue,
                            fiveHourPct: (o["fiveHourPct"] as? NSNumber)?.doubleValue,
                            fiveHourResetsAt: (o["fiveHourResetsAt"] as? NSNumber)?.doubleValue,
                            planType: nil,
                            at: (o["at"] as? NSNumber)?.doubleValue ?? 0)
    }

    /// Codex writes quota into its own session log, so nothing needs installing.
    private static func fromCodexRollouts() -> VendorLimits? {
        let root = NSString(string: "~/.codex/sessions").expandingTildeInPath
        guard let e = FileManager.default.enumerator(atPath: root) else { return nil }
        var newest: (Date, String)? = nil
        var candidates: [(Date, String)] = []
        // Match isUsable (24h). A 6h file cutoff silently discarded readings
        // that the freshness rule would have accepted, so an idle vendor
        // vanished for the wrong reason.
        let cutoff = Date().addingTimeInterval(-86_400)
        for case let rel as String in e where rel.hasSuffix(".jsonl") {
            let p = (root as NSString).appendingPathComponent(rel)
            guard let a = try? FileManager.default.attributesOfItem(atPath: p),
                  let m = a[.modificationDate] as? Date, m > cutoff else { continue }
            candidates.append((m, p))
            if newest == nil || m > newest!.0 { newest = (m, p) }
        }
        _ = newest
        // Try rollouts NEWEST FIRST and stop at the first one that actually
        // carries rate_limits.
        //
        // Reading only the single newest file was wrong in a way that bit
        // immediately: a `codex exec` run that is killed, or that ends before
        // the server reports quota, writes a rollout with NO rate_limits in it.
        // That file is the newest, so the whole vendor silently disappeared
        // from the meter — and the fan-out feature in this same app produces
        // exactly those files. Verified live: the 13:05 rollout had zero
        // rate_limits records while the 12:50 one had seven.
        for (_, path) in candidates.sorted(by: { $0.0 > $1.0 }) {
            if let v = limits(fromRollout: path) { return v }
        }
        return nil
    }

    /// Pull the last rate_limits record out of one rollout.
    ///
    /// Scanned BACKWARDS: the newest record wins anyway, so stopping at the
    /// first hit from the end avoids JSON-parsing an entire multi-megabyte
    /// file to throw away all but its final match.
    private static func limits(fromRollout path: String) -> VendorLimits? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let p = o["payload"] as? [String: Any],
                  let rl = p["rate_limits"] as? [String: Any] else { continue }

            var v = VendorLimits(vendor: "codex")
            v.planType = rl["plan_type"] as? String
            // Classify by window length, not by which key it happened to be in.
            for key in ["primary", "secondary"] {
                guard let w = rl[key] as? [String: Any],
                      let mins = (w["window_minutes"] as? NSNumber)?.intValue else { continue }
                let pct = (w["used_percent"] as? NSNumber)?.doubleValue
                let reset = (w["resets_at"] as? NSNumber)?.doubleValue
                if mins >= 7 * 24 * 60 - 60 { v.weekPct = pct; v.weekResetsAt = reset }
                else { v.fiveHourPct = pct; v.fiveHourResetsAt = reset }
            }
            if let ts = o["timestamp"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                v.at = (f.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) ?? Date()).timeIntervalSince1970
            }
            return v             // scanning from the end, so the first hit IS the newest
        }
        return nil
    }

    // MARK: - the Claude recorder

    public static var recorderInstalled: Bool { recorderInstalled(for: nil) }

    /// The settings file the recorder goes in: the account's own, for an
    /// account other than the default.
    static func settingsPath(_ account: ClaudeAccount?) -> String {
        account.map { ($0.path() as NSString).appendingPathComponent("settings.json") }
            ?? NSString(string: "~/.claude/settings.json").expandingTildeInPath
    }

    /// One script per account: each chains to that account's own statusline,
    /// and writes its limits under that account's name.
    static func recorderPath(_ account: ClaudeAccount?) -> String {
        account.map { (configDir as NSString).appendingPathComponent("statusline-recorder-\($0.label).sh") }
            ?? recorderPath
    }

    public static func recorderInstalled(for account: ClaudeAccount?) -> Bool {
        recorderInstalledAt(settingsPath(account))
    }

    /// Whether this settings file points at Coldfall's recorder.
    public static func recorderInstalledAt(_ settings: String) -> Bool {
        guard let d = FileManager.default.contents(atPath: settings),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sl = j["statusLine"] as? [String: Any],
              let c = sl["command"] as? String else { return false }
        return c.contains("statusline-recorder")
    }

    @discardableResult
    public static func installRecorder(for account: ClaudeAccount? = nil) -> String {
        let settings = settingsPath(account)
        let vendor = account?.vendor ?? "claude"
        let recorderPath = recorderPath(account)
        // A new account's folder may have no settings yet.
        var json: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: settings) {
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Could not read \(settings)"
            }
            json = j
        } else if account == nil {
            return "Could not read ~/.claude/settings.json"
        }
        var wrapped = ""
        if let sl = json["statusLine"] as? [String: Any], let cmd = sl["command"] as? String {
            if cmd.contains("statusline-recorder") {
                // Already ours: keep wrapping what the first install wrapped.
                // Rewriting with nothing here silently dropped the person's
                // own statusline the second time the button was pressed.
                wrapped = Uninstall.wrappedStatusline(recorder: cmd) ?? ""
            } else {
                wrapped = cmd
            }
        }
        let script = """
        #!/bin/bash
        # Installed by Project Coldfall. Captures Claude Code's live rate limits so the
        # meter can show remaining quota, then hands stdin to your own statusline
        # unchanged. To undo, point statusLine in \(settings) back at
        # your own script.
        input=$(cat)
        out="$HOME/.local/share/coldfall/limits/\(vendor).json"
        mkdir -p "$(dirname "$out")"
        printf '%s' "$input" | jq -c '{
          vendor: "\(vendor)",
          weekPct:          (.rate_limits.seven_day.used_percentage // null),
          weekResetsAt:     (.rate_limits.seven_day.resets_at       // null),
          fiveHourPct:      (.rate_limits.five_hour.used_percentage // null),
          fiveHourResetsAt: (.rate_limits.five_hour.resets_at       // null),
          at: now
        }' > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" 2>/dev/null

        # Context window is per SESSION, not per vendor, so it is keyed by the
        # desk name Claude Code reports. Each desk writes its own file and they
        # stop overwriting one another.
        name=$(printf '%s' "$input" | jq -r '.session_name // .agent.name // empty' 2>/dev/null)
        # The name comes from Claude's JSON and becomes a file name: keep it
        # to plain characters, and never a path. "../../.claude/settings"
        # would otherwise have been written over.
        # (a name starting with "._" would be an invisible file on macOS)
        name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._ -' '_' | tr -s '_' | sed -e 's/\\.\\.*/./g' -e 's/^[._ ]*//')
        case "$name" in .|"") name="";; esac
        if [ -n "$name" ]; then
          sdir="$HOME/.local/share/coldfall/sessions"
          mkdir -p "$sdir"
          printf '%s' "$input" | jq -c '{
            desk:   (.session_name // .agent.name),
            ctxPct: (.context_window.used_percentage // null),
            model:  (.model.display_name // null),
            effort: (.effort.level // null),
            usd:    (.cost.total_cost_usd // null),
            at: now
          }' > "$sdir/$name.json.tmp" 2>/dev/null && mv "$sdir/$name.json.tmp" "$sdir/$name.json" 2>/dev/null
        fi

        WRAPPED=\(Uninstall.quoteForRecorder(wrapped))
        if [ -n "$WRAPPED" ]; then
          printf '%s' "$input" | eval "$WRAPPED"
        fi
        """
        try? FileManager.default.createDirectory(
            atPath: (recorderPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do { try script.write(toFile: recorderPath, atomically: true, encoding: .utf8) }
        catch { return "Could not write the recorder: \(error)" }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorderPath)

        json["statusLine"] = ["type": "command", "command": recorderPath, "padding": 0]
        try? FileManager.default.createDirectory(
            atPath: (settings as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              (try? out.write(to: URL(fileURLWithPath: settings))) != nil else {
            return "Could not write \(settings)"
        }
        return wrapped.isEmpty
            ? "Installed. Limits appear after your next Claude message."
            : "Installed, chaining to your existing statusline. Limits appear after your next Claude message."
    }
}


/// Per-desk state, written by the same recorder. Context is a property of a
/// session, so it is keyed by desk rather than by vendor.
public struct DeskState: Codable {
    public var desk: String
    public var ctxPct: Double?
    public var model: String?
    public var effort: String?
    public var usd: Double?
    public var at: Double = 0

    public static var dir: String { NSString(string: "~/.local/share/coldfall/sessions").expandingTildeInPath }

    public static func load(_ desk: String) -> DeskState? {
        guard !desk.contains("/"), !desk.contains(".."), !desk.isEmpty else { return nil }
        let p = (dir as NSString).appendingPathComponent("\(desk).json")
        guard let d = FileManager.default.contents(atPath: p),
              let s = try? JSONDecoder().decode(DeskState.self, from: d) else { return nil }
        // Context moves fast and only while the desk is working, so an old
        // reading is genuinely misleading here — unlike weekly quota.
        return Date().timeIntervalSince1970 - s.at < 900 ? s : nil
    }
}

/// How fast the week's quota is going, against how much of the week is gone.
///
/// "57%" alone doesn't say whether that's fine on a Tuesday. What changes
/// behaviour is whether, at the rate so far, the quota runs out before it
/// resets. Only then is there something to say.
public enum WeekPace {
    public static let window: TimeInterval = 7 * 86_400
    /// Too early in the week, one busy morning looks like a crisis.
    public static let minElapsed = 0.08

    public struct Reading: Equatable {
        /// When the quota runs out at the rate so far.
        public let runsOutAt: Date
        /// How long before the reset that is.
        public let early: TimeInterval
    }

    /// Nil when there's nothing to say: on pace, too early, or no data.
    public static func assess(usedPct: Double, resetsAt: Date, now: Date = Date()) -> Reading? {
        let start = resetsAt.addingTimeInterval(-window)
        let elapsed = now.timeIntervalSince(start)
        guard usedPct > 0, usedPct < 100, elapsed > 0, now < resetsAt,
              elapsed / window >= minElapsed else { return nil }
        let perSecond = usedPct / elapsed
        let out = now.addingTimeInterval((100 - usedPct) / perSecond)
        let early = resetsAt.timeIntervalSince(out)
        // Within the last hour or two is noise, not news.
        guard early > 3 * 3600 else { return nil }
        return Reading(runsOutAt: out, early: early)
    }

    /// "claude: at this pace you run out Fri 3 pm, 22h before the week resets."
    public static func line(vendor: String, _ r: Reading, calendar: Calendar = .current) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = "EEE h a"
        let when = f.string(from: r.runsOutAt).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
        let h = Int(r.early / 3600)
        let gap = h >= 48 ? "\(h / 24) days" : "\(h)h"
        return "\(vendor): at this pace you run out \(when), \(gap) before the week resets."
    }
}
