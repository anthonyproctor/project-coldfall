import Foundation

/// The first desks Welcome offers, from the check-up (see Checkup): a few
/// to choose from, one ticked to begin with, never a desk per installed tool.
/// For someone with no agent tool yet, which one to install, by the plan they
/// already pay for.
public enum FirstDesk {

    public enum Kind: String { case folder, agent, job }

    public struct Option: Equatable {
        public var kind: Kind
        public var name: String
        public var runtime: String
        /// The folder it works in, as written in desks.toml (`~/…`).
        public var cwd: String
        public var agent: String?
        /// One line under it: why it's offered.
        public var detail: String
        public var on: Bool
        public init(kind: Kind, name: String, runtime: String, cwd: String, agent: String?, detail: String, on: Bool) {
            self.kind = kind; self.name = name; self.runtime = runtime; self.cwd = cwd; self.agent = agent; self.detail = detail; self.on = on
        }
    }

    /// A tool a new job desk can run on, as the person knows it.
    public struct Tool: Equatable {
        public var runtime: String
        public var name: String
    }

    /// What someone pays for, and the agent tool that goes with it.
    public struct Plan: Equatable {
        public var title: String
        public var detail: String
        public var runtime: String
    }

    public static let plans: [Plan] = [
        Plan(title: "Claude", detail: "Pro or Max plan", runtime: "claude"),
        Plan(title: "ChatGPT", detail: "Plus or Pro plan", runtime: "codex"),
        Plan(title: "Gemini", detail: "Google AI Pro or Ultra", runtime: "antigravity"),
        Plan(title: "GitHub Copilot", detail: "a Copilot plan", runtime: "copilot"),
        Plan(title: "Nothing yet", detail: "free, runs on this Mac", runtime: "ollama"),
    ]

    /// The plan to suggest first: the chat app they already have, else Claude.
    public static func likelyPlan(_ r: Checkup.Report) -> Plan {
        if r.chatApps.contains("ChatGPT") || r.chatApps.contains("Codex") { return plans[1] }
        if r.chatApps.contains("Gemini") { return plans[2] }
        return plans[0]
    }

    /// Letters, digits, - _ . only, lower case: a desk's name in desks.toml
    /// and a folder's name under ~/Coldfall.
    public static func cleanName(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
        var out = ""
        for u in s.lowercased().unicodeScalars {
            if allowed.contains(u) { out.unicodeScalars.append(u) }
            else if !out.hasSuffix("-") { out += "-" }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return String(out.prefix(40))
    }

    /// `name`, or `name-2`, `name-3`… so it doesn't take one already used.
    public static func unique(_ name: String, taken: Set<String>) -> String {
        let base = cleanName(name).isEmpty ? "desk" : cleanName(name)
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Tools a new job desk can run on: the ones in use first, then the rest installed.
    public static func tools(_ r: Checkup.Report) -> [Tool] {
        let usable = r.tools.filter { $0.installed && $0.runtime != nil }
        let order = usable.filter(\.active).sorted { $0.last30 > $1.last30 } + usable.filter { !$0.active }
        return order.map { Tool(runtime: $0.runtime!, name: $0.name) }
    }

    static func short(_ p: String, home: String) -> String {
        p == home ? "~" : p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    /// What Welcome offers. `agentsIn` lists a folder's own agents
    /// (Discovery.agents(in:) outside tests).
    /// Agents and folders that already have a desk in `existing` aren't offered again.
    public static func options(_ r: Checkup.Report, home: String = NSHomeDirectory(), existing: [Desk] = [],
                               agentsIn: (String) -> [DiscoveredAgent] = { Discovery.agents(in: $0) }) -> [Option] {
        let runners = tools(r)
        guard let first = runners.first else { return [] }
        var out: [Option] = []
        var taken = Set(existing.map(\.name))
        let hasAgent = Set(existing.compactMap(\.agent))
        let hasFolder = Set(existing.filter { $0.agent == nil && $0.command == nil }.map { Checkup.canonical($0.resolvedCwd) })
        func add(_ o: Option) { var o = o; o.name = unique(o.name, taken: taken); taken.insert(o.name); out.append(o) }

        if r.profile == .agentBuilder {
            for f in r.folders where !f.agents.isEmpty {
                let here = (f.path as NSString).lastPathComponent
                for a in agentsIn(f.path).filter({ $0.isProjectLevel && !hasAgent.contains($0.name) }).prefix(40) {
                    add(Option(kind: .agent, name: a.name, runtime: a.runtime, cwd: short(f.path, home: home), agent: a.name,
                               detail: a.description.map { String($0.prefix(90)) } ?? "an agent you built in \(here)", on: false))
                }
                if out.count >= 40 { break }
            }
        }
        // Folders agents worked in this month, newest first.
        for f in r.folders.filter({ !hasFolder.contains(Checkup.canonical($0.path)) }).prefix(4) {
            let tool = runners.first { f.tools.contains($0.name) } ?? first
            let n = f.conversations
            add(Option(kind: .folder, name: (f.path as NSString).lastPathComponent, runtime: tool.runtime, cwd: short(f.path, home: home),
                       agent: nil, detail: "\(tool.name) · \(n) conversation\(n == 1 ? "" : "s") here this month", on: false))
        }
        // The first folder starts ticked, for one or several tools. An agent
        // builder chooses their own agents; nothing is ticked for them.
        if r.profile != .agentBuilder, let i = out.firstIndex(where: { $0.kind == .folder }) { out[i].on = true }
        return out
    }

    /// The job desk Welcome offers as the last choice (or the only one).
    public static func job(name: String, runtime: String, taken: Set<String>) -> Option {
        let n = unique(name.isEmpty ? "first" : name, taken: taken)
        return Option(kind: .job, name: n, runtime: runtime, cwd: "~/Coldfall/\(n)", agent: nil,
                      detail: "a new folder for one ongoing job", on: true)
    }

    /// The desks for what was ticked, named so none clashes with those already there.
    public static func desks(_ chosen: [Option], existing: [Desk] = []) -> [Desk] {
        var taken = Set(existing.map(\.name))
        var out: [Desk] = []
        for o in chosen where o.on {
            let name = unique(o.name, taken: taken)
            taken.insert(name)
            if o.kind == .agent, o.runtime == "codex" {
                out.append(Desk(name: name, runtime: "codex", cwd: o.cwd, command: "codex -p \(Shell.quote(o.agent ?? o.name))"))
            } else {
                out.append(Desk(name: name, agent: o.agent, runtime: o.runtime, cwd: o.cwd))
            }
        }
        return out
    }

    /// Make a job desk's folder, with a short instructions file the agent
    /// reads (CLAUDE.md for Claude, AGENTS.md for the rest). Never overwrites.
    @discardableResult
    public static func makeFolder(_ o: Option, home: String = NSHomeDirectory()) -> Bool {
        guard o.kind == .job else { return true }
        let path = o.cwd.hasPrefix("~/") ? home + o.cwd.dropFirst(1) : o.cwd
        let fm = FileManager.default
        guard (try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)) != nil else { return false }
        let file = (path as NSString).appendingPathComponent(o.runtime == "claude" ? "CLAUDE.md" : "AGENTS.md")
        if !fm.fileExists(atPath: file) {
            let text = """
            # \(o.name)

            This folder belongs to the \(o.name) desk in Project Coldfall: one ongoing job,
            picked up where it left off each time. Keep this job's notes and files here.

            What this job is about:

            """
            fm.createFile(atPath: file, contents: Data(text.utf8))
        }
        return true
    }
}
