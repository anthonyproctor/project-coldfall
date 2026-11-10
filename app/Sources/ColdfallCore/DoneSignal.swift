// Knowing a desk is done because its agent says so.
//
// The rail's green check was a guess: output stopped for two seconds, so the
// agent must have finished. Guessing from bytes went wrong in every way bytes
// can: a repaint when focus left, a status line ticking, a notice pushing the
// screen up a row, a page of scrollback read as the screen. Each was patched,
// and each patch narrowed the guess without ending it.
//
// Claude Code and Codex both run hooks when the agent stops, and Claude Code
// when it needs you (a permission prompt). So Coldfall can install one tiny
// hook that writes "this desk stopped" to a local log, and turn a desk green
// on that, not on the bytes. The hook sees which desk it belongs to because
// Coldfall gives every desk CLAUDE_DESK in its environment.
//
// A desk whose agent has reported once is trusted from then on: its output
// still shows it working, but only the agent's own signal turns it green.
// Desks that never report (other agents, or before the hook is installed)
// keep the guess.
//
// The hook sends nothing anywhere, calls no model, and costs no tokens. It
// appends one line to a file on this Mac.

import Foundation

public enum DoneSignal {

    public enum Event: String, Equatable {
        /// The agent finished answering.
        case stop
        /// The agent is waiting on you: a permission prompt, a question.
        case notify
    }

    public struct Signal: Equatable {
        public let at: Date
        public let event: Event
        /// The desk name as the hook wrote it (see `fileName`).
        public let desk: String
        public init(at: Date, event: Event, desk: String) { self.at = at; self.event = event; self.desk = desk }
    }

    /// Where the hook writes. Overridable so tests use a temp folder.
    public static var logPath = NSString(string: "~/.local/share/coldfall/signals.log").expandingTildeInPath
    /// The hook script. Lives with the recorder.
    public static var scriptPath: String { (Limits.configDir as NSString).appendingPathComponent("done-hook.sh") }
    /// How Coldfall's hook entries are recognised in a settings file.
    public static let marker = "done-hook.sh"

    /// A desk name as the hook writes it: anything but letters, digits and
    /// `. _ -` becomes `_`, so a name can never break the line or the file.
    public static func fileName(_ desk: String) -> String {
        String(desk.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "_" })
    }

    /// One line of the log: `<epoch seconds> <event> <desk>`.
    public static func parse(_ line: Substring) -> Signal? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let t = Double(parts[0]), let e = Event(rawValue: String(parts[1])) else { return nil }
        return Signal(at: Date(timeIntervalSince1970: t), event: e, desk: String(parts[2]))
    }

    /// Reads what the hook has added since the last read. Starts at the end
    /// of the file, because signals from before Coldfall started are about
    /// desks you have since seen, or that no longer run.
    public final class Reader {
        public private(set) var offset: UInt64
        let path: String
        public init(path: String = DoneSignal.logPath, fromStart: Bool = false) {
            self.path = path
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 ?? 0
            offset = fromStart ? 0 : size
        }

        public func read() -> [Signal] {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 else { return [] }
            if size < offset { offset = 0 }              // trimmed or replaced: start over
            guard size > offset, let fh = FileHandle(forReadingAtPath: path) else { return [] }
            defer { try? fh.close() }
            try? fh.seek(toOffset: offset)
            let data = fh.readDataToEndOfFile()
            // Only whole lines; a line still being written waits for the next read.
            guard let lastNewline = data.lastIndex(of: 10) else { return [] }
            let whole = data[data.startIndex...lastNewline]
            offset += UInt64(whole.count)
            return String(decoding: whole, as: UTF8.self).split(separator: "\n").compactMap(DoneSignal.parse)
        }
    }

    /// Keep the log small: when it passes `max` bytes, keep the last half.
    public static func trim(path: String = DoneSignal.logPath, max: Int = 256 * 1024) {
        guard let d = FileManager.default.contents(atPath: path), d.count > max else { return }
        var tail = d.suffix(max / 2)
        if let nl = tail.firstIndex(of: 10) { tail = tail[tail.index(after: nl)...] }
        try? Data(tail).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - the hook

    /// The script. `$1` is the event. It reads the hook's JSON from stdin only
    /// to skip Claude Code's "waiting for your input" reminder, which fires
    /// after a minute of quiet: that would turn a desk green you'd already read.
    public static var script: String {
        """
        #!/bin/sh
        # Installed by Project Coldfall. Tells the desk list when this desk's agent
        # has finished or needs you, so it can turn green on the agent's word rather
        # than guessing from output. Appends one line to a file on this Mac; sends
        # nothing anywhere. Remove it from the "hooks" in your settings to turn it off.
        [ -n "$CLAUDE_DESK" ] || { cat >/dev/null; exit 0; }
        input=$(cat)
        case "$1" in
          stop) ev=stop ;;
          notify)
            case "$input" in *idle_prompt*) exit 0 ;; esac
            ev=notify ;;
          *) exit 0 ;;
        esac
        desk=$(printf '%s' "$CLAUDE_DESK" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
        log="$HOME/.local/share/coldfall/signals.log"
        mkdir -p "$(dirname "$log")"
        printf '%s %s %s\\n' "$(date +%s)" "$ev" "$desk" >> "$log"
        exit 0
        """
    }

    @discardableResult
    public static func writeScript() -> Bool {
        try? FileManager.default.createDirectory(atPath: Limits.configDir, withIntermediateDirectories: true)
        guard (try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return true
    }

    /// The events each vendor gets, and the argument the script is called with.
    /// Codex has no Notification event; it gets Stop only.
    static let claudeEvents: [(String, Event)] = [("Stop", .stop), ("Notification", .notify)]
    static let codexEvents: [(String, Event)] = [("Stop", .stop)]

    /// Claude Code's settings and Codex's hooks.json share the shape:
    /// `{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "..."}]}]}}`.
    /// Adds Coldfall's entry to each event, leaving every other hook alone.
    /// Returns the new JSON, or nil if it was already all there.
    public static func adding(to json: [String: Any], events: [(String, Event)], script: String) -> [String: Any]? {
        var j = json
        var hooks = j["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for (name, ev) in events {
            var rules = hooks[name] as? [[String: Any]] ?? []
            let has = rules.contains { rule in
                (rule["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
            }
            if has { continue }
            rules.append(["hooks": [["type": "command", "command": "\(Shell.quote(script)) \(ev.rawValue)"]]])
            hooks[name] = rules
            changed = true
        }
        guard changed else { return nil }
        j["hooks"] = hooks
        return j
    }

    /// Takes Coldfall's entries out again, and any event or rule left empty.
    /// Returns the new JSON, or nil if there was nothing of Coldfall's.
    public static func removing(from json: [String: Any]) -> [String: Any]? {
        guard var hooks = json["hooks"] as? [String: Any] else { return nil }
        var changed = false
        for (name, value) in hooks {
            guard let rules = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for var rule in rules {
                let hs = rule["hooks"] as? [[String: Any]] ?? []
                let left = hs.filter { ($0["command"] as? String)?.contains(marker) != true }
                if left.count != hs.count { changed = true }
                if left.isEmpty, !hs.isEmpty { continue }
                rule["hooks"] = left
                kept.append(rule)
            }
            if kept.isEmpty { hooks.removeValue(forKey: name) } else { hooks[name] = kept }
        }
        guard changed else { return nil }
        var j = json
        if hooks.isEmpty { j.removeValue(forKey: "hooks") } else { j["hooks"] = hooks }
        return j
    }

    public static func installed(in json: [String: Any], events: [String]) -> Bool {
        let hooks = json["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { name in
            (hooks[name] as? [[String: Any]] ?? []).contains { rule in
                (rule["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
            }
        }
    }

    // MARK: - the files

    /// The settings files the hook goes in: Claude's for the default account
    /// and each other account desks use, and Codex's own hooks.json.
    public static func claudeSettings(desks: [Desk], home: String = NSHomeDirectory()) -> [String] {
        Uninstall.settingsFiles(desks: desks, home: home)
    }
    public static func codexHooks(home: String = NSHomeDirectory()) -> String {
        let root = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? (home as NSString).appendingPathComponent(".codex")
        return (root as NSString).appendingPathComponent("hooks.json")
    }

    static func readJSON(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return [:] }      // no file yet: start empty
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]                // unreadable: leave it alone
    }
    static func writeJSON(_ j: [String: Any], to path: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        guard let out = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? out.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    /// Whether the Claude hook is in the default account's settings.
    public static var isInstalled: Bool {
        guard let j = readJSON(NSString(string: "~/.claude/settings.json").expandingTildeInPath) else { return false }
        return installed(in: j, events: claudeEvents.map(\.0))
    }

    /// Install everywhere it applies. Codex only if Codex is set up on this
    /// Mac. Returns one line per file, for the alert.
    @discardableResult
    public static func install(desks: [Desk], home: String = NSHomeDirectory(),
                               codex: Bool? = nil) -> [String] {
        guard writeScript() else { return ["Could not write \(scriptPath)"] }
        var log: [String] = []
        for s in claudeSettings(desks: desks, home: home) {
            // Only accounts that exist: a folder named in desks.toml but never signed in stays untouched.
            guard FileManager.default.fileExists(atPath: (s as NSString).deletingLastPathComponent) else { continue }
            guard let j = readJSON(s) else { log.append("Left \(s) alone: it isn't valid JSON."); continue }
            guard let next = adding(to: j, events: claudeEvents, script: scriptPath) else {
                log.append("Already on in \(s)"); continue
            }
            log.append(writeJSON(next, to: s) ? "Turned on in \(s)" : "Could not write \(s)")
        }
        let cx = codexHooks(home: home)
        let wantCodex = codex ?? FileManager.default.fileExists(atPath: (cx as NSString).deletingLastPathComponent)
        if wantCodex {
            if let j = readJSON(cx) {
                if let next = adding(to: j, events: codexEvents, script: scriptPath) {
                    log.append(writeJSON(next, to: cx)
                               ? "Turned on in \(cx). Codex asks you to trust a new hook once: run /hooks in a Codex desk."
                               : "Could not write \(cx)")
                } else { log.append("Already on in \(cx)") }
            } else { log.append("Left \(cx) alone: it isn't valid JSON.") }
        }
        return log
    }

    /// Take the hook out of every file it went into, and delete the script.
    /// `script` is the script to delete: a caller working under another
    /// config folder (a test, a full uninstall) passes its own, so it never
    /// deletes the real one by default.
    @discardableResult
    public static func uninstall(desks: [Desk], home: String = NSHomeDirectory(),
                                 script: String = DoneSignal.scriptPath) -> [String] {
        var log: [String] = []
        for s in claudeSettings(desks: desks, home: home) + [codexHooks(home: home)] {
            guard FileManager.default.fileExists(atPath: s), let j = readJSON(s),
                  let next = removing(from: j) else { continue }
            log.append(writeJSON(next, to: s) ? "Removed from \(s)" : "Could not write \(s)")
        }
        try? FileManager.default.removeItem(atPath: script)
        return log
    }
}
