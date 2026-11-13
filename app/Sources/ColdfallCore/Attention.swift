import Foundation

// Who needs you next, and why. The pieces behind the priority view of the
// desk list, the line of dim text beside a desk's name, the next/previous
// desk keys, the context gauge and the branch shown in a pane's header.

public extension DeskOrder {

    enum Urgency: Int, Equatable, CaseIterable {
        case needsYou, done, working, idle
        public var title: String {
            switch self {
            case .needsYou: return "Needs you"
            case .done: return "Done"
            case .working: return "Working"
            case .idle: return "Idle"
            }
        }
    }

    struct PrioritySection: Equatable {
        public let urgency: Urgency
        public let names: [String]
        public init(_ urgency: Urgency, _ names: [String]) { self.urgency = urgency; self.names = names }
    }

    /// The desk list by priority: every running desk that isn't pinned or
    /// hidden, across all groups, in sections Needs you, Done, Working,
    /// Idle. Inside the first two the longest wait is first; inside the
    /// others the most recent. Empty sections are left out.
    static func priority(_ desks: [Desk], live: [String: Live]) -> [PrioritySection] {
        let names = active(desks, live: live, enabled: true)
        return Urgency.allCases.compactMap { u in
            let mine = names.filter { live[$0]?.rank == u.rawValue }
            return mine.isEmpty ? nil : PrioritySection(u, mine)
        }
    }

    /// The desk after (or before) `current` in the list as it is shown,
    /// wrapping. From a desk that isn't in the list, the first (or last).
    static func step(_ shown: [String], from current: String?, by delta: Int) -> String? {
        guard !shown.isEmpty else { return nil }
        guard let c = current, let i = shown.firstIndex(of: c) else { return delta >= 0 ? shown.first : shown.last }
        guard shown.count > 1 else { return nil }
        return shown[((i + delta) % shown.count + shown.count) % shown.count]
    }
}

/// The dim text beside a desk's name: why it stopped, when it is waiting
/// on you; otherwise what it says it is doing (its terminal title).
public enum DeskDetail {

    public static let maxLength = 80

    /// Why an agent is waiting, from what it said. Claude Code's
    /// notification reads "Claude needs your permission to use Bash"; the
    /// desk's name already says who, so that becomes "wants to use Bash".
    /// With no message, the kind of a status report will do.
    public static func reason(message: String?, kind: String? = nil) -> String? {
        var m = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        m = m.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        for who in ["Claude Code ", "Claude ", "Codex "] where m.hasPrefix(who) { m = String(m.dropFirst(who.count)); break }
        for (from, to) in [("needs your permission to ", "wants to "), ("needs your approval for ", "wants approval for "),
                           ("is waiting for your input", "is waiting for you")] where m.hasPrefix(from) {
            m = to + m.dropFirst(from.count)
        }
        if m.isEmpty {
            switch kind {
            case "permission": m = "wants permission"
            case "question": m = "asked a question"
            case "auth": m = "needs you to sign in"
            default: return nil
            }
        }
        return clip(m)
    }

    /// A terminal title worth showing. Agents put what they are working on
    /// there ("✳ Fix the invoice parser"); shells put the folder or the
    /// command, which says nothing the row doesn't already.
    public static func title(_ raw: String, desk: String, runtime: String = "claude") -> String? {
        // Leading spinner and status glyphs, and the space after them.
        var t = String(raw.drop { !($0.isLetter || $0.isNumber) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        let dull: Set<String> = ["claude", "claude code", "codex", "zsh", "bash", "sh", "fish", "login", "terminal",
                                 desk.lowercased(), runtime.lowercased()]
        if dull.contains(lower) { return nil }
        // A path, or user@host: a shell's title, not an agent's.
        if t.hasPrefix("/") || t.hasPrefix("~") || t.contains("@") && t.contains(":") { return nil }
        if raw.hasPrefix("/") || raw.hasPrefix("~") { return nil }
        if t.count < 3 { return nil }
        t = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
        return clip(t)
    }

    /// What the row shows: the reason while it waits on you, else the title.
    public static func line(blocked: Bool, reason: String?, title: String?) -> String? {
        if blocked, let r = reason { return r }
        return blocked ? nil : title
    }

    static func clip(_ s: String) -> String {
        s.count > maxLength ? String(s.prefix(maxLength - 1)) + "…" : s
    }
}

/// How full a desk's conversation is. Past 60% it is worth a glance; past
/// 80% the agent is close to compacting and its answers get worse.
public enum ContextGauge {
    public enum Level: Equatable { case fine, high, full }
    public static func level(_ pct: Double) -> Level { pct >= 80 ? .full : (pct >= 60 ? .high : .fine) }
    public static func text(_ pct: Double) -> String { "ctx \(Int(pct.rounded()))%" }
}

/// The branch a desk's folder is on, shown only when it says something:
/// not on main or master.
public enum GitTail {
    /// From the text of `.git/HEAD`. A detached HEAD shows its short hash.
    public static func branch(head: String) -> String? {
        let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = "ref: refs/heads/"
        if h.hasPrefix(ref) {
            let b = String(h.dropFirst(ref.count))
            return b.isEmpty || b == "main" || b == "master" ? nil : b
        }
        let hex = h.allSatisfy { $0.isHexDigit }
        return hex && h.count >= 7 ? String(h.prefix(7)) : nil
    }

    /// Where HEAD lives for a folder: `.git/HEAD`, or, in a worktree, the
    /// HEAD of the gitdir its `.git` file points at.
    public static func headPath(folder: String, read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
                                isDir: (String) -> Bool = { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }) -> String? {
        let dot = (folder as NSString).appendingPathComponent(".git")
        if isDir(dot) { return (dot as NSString).appendingPathComponent("HEAD") }
        guard let text = read(dot), text.hasPrefix("gitdir:") else { return nil }
        var dir = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !dir.hasPrefix("/") { dir = (folder as NSString).appendingPathComponent(dir) }
        return (dir as NSString).appendingPathComponent("HEAD")
    }

    public static func branch(folder: String) -> String? {
        guard let p = headPath(folder: folder), let h = try? String(contentsOfFile: p, encoding: .utf8) else { return nil }
        return branch(head: h)
    }
}
