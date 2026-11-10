// Leaving.
//
// Coldfall never reimplements an agent, so leaving should cost nothing: the
// CLIs, their logins, conversations, hooks and memory files are the vendors'
// and are not touched. What Coldfall has of its own is two folders, plus one
// thing it changed elsewhere — if live Claude limits were turned on, it set
// `statusLine` in that account's settings.json to its recorder script (which
// still runs whatever statusline was there before).
//
// This lists all of it, undoes the statusline, and deletes the folders. It is
// here rather than in the app so the list can be tested against a fake home
// instead of someone's real one.

import Foundation

public enum Uninstall {

    public struct Item: Equatable {
        public let path: String
        /// What this is, in the words the alert uses.
        public let what: String
        public let bytes: Int
        public init(path: String, what: String, bytes: Int) {
            self.path = path; self.what = what; self.bytes = bytes
        }
    }

    /// The folders Coldfall owns, with what is in them, skipping any that are
    /// not there.
    public static func items(configRoot: String = NSString(string: "~/.config/coldfall").expandingTildeInPath,
                             dataRoot: String = NSString(string: "~/.local/share/coldfall").expandingTildeInPath)
    -> [Item] {
        [(configRoot, "your desk list, bridge settings and the statusline recorder"),
         (dataRoot, "window state, agent mail threads, the usage cache and plan limit readings")]
            .filter { FileManager.default.fileExists(atPath: $0.0) }
            .map { Item(path: $0.0, what: $0.1, bytes: size(of: $0.0)) }
    }

    /// Bytes under a path, directories included. Unreadable files count zero
    /// rather than stopping the walk.
    public static func size(of path: String) -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return ((try? fm.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        }
        var total = 0
        if let e = fm.enumerator(atPath: path) {
            for case let rel as String in e {
                let p = (path as NSString).appendingPathComponent(rel)
                total += ((try? fm.attributesOfItem(atPath: p))?[.size] as? Int) ?? 0
            }
        }
        return total
    }

    public static func humanSize(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes) bytes"
    }

    /// Every Claude settings file Coldfall may have changed: the default
    /// account's, and one per account a desk uses.
    public static func settingsFiles(desks: [Desk], home: String = NSHomeDirectory()) -> [String] {
        [(home as NSString).appendingPathComponent(".claude/settings.json")]
            + ClaudeAccount.used(by: desks, home: home).map {
                ($0.path(home: home) as NSString).appendingPathComponent("settings.json")
            }
    }

    /// The statusline command the recorder script wraps, i.e. what was there
    /// before Coldfall. Empty when it wrapped nothing.
    public static func wrappedStatusline(recorder path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("WRAPPED=") {
            return unquoteFromRecorder(String(line.dropFirst("WRAPPED=".count)))
        }
        return nil
    }

    /// The wrapped command as the recorder script carries it: single-quoted,
    /// any single quote inside closed, escaped and reopened, so a command
    /// with quotes, `$` or backticks is stored as written and never run as
    /// part of the script itself. The old form was double quotes with no
    /// escaping, and a command containing `"$@"` broke the whole recorder.
    public static func quoteForRecorder(_ cmd: String) -> String {
        "'" + cmd.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Undo `quoteForRecorder`; also reads the old double-quoted form.
    public static func unquoteFromRecorder(_ v: String) -> String {
        if v.hasPrefix("'"), v.hasSuffix("'"), v.count >= 2 {
            return String(v.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        }
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { return String(v.dropFirst().dropLast()) }
        return v
    }

    /// Put `statusLine` back the way it was in one settings file. Returns what
    /// happened, or nil if Coldfall's recorder was not in there at all.
    @discardableResult
    public static func revertStatusline(settings: String) -> String? {
        guard let d = FileManager.default.contents(atPath: settings),
              var json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sl = json["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String, cmd.contains("statusline-recorder") else { return nil }

        let before = wrappedStatusline(recorder: cmd) ?? ""
        if before.isEmpty {
            json.removeValue(forKey: "statusLine")
        } else {
            json["statusLine"] = ["type": "command", "command": before, "padding": sl["padding"] ?? 0]
        }
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              (try? out.write(to: URL(fileURLWithPath: settings))) != nil else {
            return "could not write \(settings)"
        }
        return before.isEmpty
            ? "statusLine removed from \(settings)"
            : "statusLine in \(settings) points at your own command again"
    }

    /// What the alert says, built here so the wording is testable.
    public static func summary(items: [Item], recorders: [String], doneHook: Bool = false) -> String {
        var body = "Your agents are not touched. Claude Code, Codex and the rest keep their logins, "
                 + "conversations, settings and hooks, and work from a terminal exactly as before.\n\n"
        guard !items.isEmpty || !recorders.isEmpty || doneHook else {
            return body + "There is nothing of Coldfall's left to remove."
        }
        body += "This deletes:\n"
        for i in items { body += "\n• \(i.path)\n    \(i.what) — \(humanSize(i.bytes))\n" }
        for s in recorders {
            body += "\nand puts statusLine in \(s) back the way it was, so Claude stops running "
                  + "Coldfall's recorder.\n"
        }
        if doneHook {
            body += "\nand takes Coldfall's done hook out of Claude Code's and Codex's hooks, "
                  + "leaving every other hook there.\n"
        }
        return body + "\nYour desk list goes with it. Afterwards, quit Project Coldfall and drag it to the Trash."
    }

    /// Undo the statusline everywhere, then delete Coldfall's folders. The
    /// app itself is not touched: dragging it to the Trash stays the person's
    /// own move, and this says so rather than doing it behind their back.
    @discardableResult
    public static func removeEverything(desks: [Desk],
                                        configRoot: String = NSString(string: "~/.config/coldfall").expandingTildeInPath,
                                        dataRoot: String = NSString(string: "~/.local/share/coldfall").expandingTildeInPath,
                                        home: String = NSHomeDirectory()) -> [String] {
        var log: [String] = []
        for s in settingsFiles(desks: desks, home: home) {
            if let line = revertStatusline(settings: s) { log.append(line) }
        }
        // The script lives in the config folder this call was given, which is
        // deleted below anyway. Not DoneSignal.scriptPath: a test passing a
        // temp configRoot deleted the real hook on every run (v0.3.24-0.3.27).
        log += DoneSignal.uninstall(desks: desks, home: home,
                                    script: (configRoot as NSString).appendingPathComponent("done-hook.sh"))
        for root in [configRoot, dataRoot] where FileManager.default.fileExists(atPath: root) {
            do {
                try FileManager.default.removeItem(atPath: root)
                log.append("deleted \(root)")
            } catch {
                log.append("could not delete \(root): \(error.localizedDescription)")
            }
        }
        return log
    }
}
