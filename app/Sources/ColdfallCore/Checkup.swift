import Foundation

/// How this Mac uses AI, looked at before setting anything up: which agent
/// tools are installed and which are actually used, how often and in how many
/// folders, what the person has built on top (custom agents, skills, commands,
/// MCP servers, instruction files), chat apps, editor add-ons and local models.
/// From that, a profile and a suggested start (`coldfall-cli checkup`).
///
/// It only counts and dates things. It never opens a conversation's text, a
/// prompt, a file's contents, browser history or anything holding a key: a
/// conversation is a file's modification time, plus the folder it ran in, read
/// from the `cwd` field near the top of the file and nothing else. Sign-in is a
/// file being there (or, for Claude, a key being present in its settings),
/// never what's in it.
///
/// `share(_:)` is the version for sending to someone else: counts and the
/// profile only, no folder, agent or desk names.
public enum Checkup {

    // MARK: what it looks at

    /// An agent tool, where it keeps its conversations, and how its sign-in shows.
    struct Spec {
        let id: String, name: String, bins: [String]
        /// Folders under home whose files are its conversations (searched to `depth`).
        let history: [String]
        let suffixes: [String]
        let depth: Int
        /// Files whose presence means it's signed in; empty: Coldfall can't tell.
        let signIn: [String]
        let runtime: String?
        /// History folders that hold one folder per conversation (several files each).
        var perFolder: [String] = []
    }

    static let specs: [Spec] = [
        Spec(id: "claude", name: "Claude Code", bins: ["claude"], history: [".claude/projects"], suffixes: [".jsonl"], depth: 2,
             signIn: [".claude/.credentials.json"], runtime: "claude"),
        Spec(id: "codex", name: "Codex", bins: ["codex"], history: [".codex/sessions"], suffixes: [".jsonl"], depth: 5,
             signIn: [".codex/auth.json"], runtime: "codex"),
        Spec(id: "antigravity", name: "Antigravity / Gemini CLI", bins: ["agy", "gemini"],
             history: [".gemini/antigravity-cli/brain", ".gemini/tmp"], suffixes: [".json", ".jsonl", ".pb", ".md"], depth: 6,
             signIn: [".gemini/google_accounts.json", ".gemini/oauth_creds.json"], runtime: "antigravity",
             perFolder: [".gemini/antigravity-cli/brain"]),
        Spec(id: "copilot", name: "GitHub Copilot CLI", bins: ["copilot"], history: [".copilot/session-state", ".copilot/history-session-state"],
             suffixes: [".jsonl", ".json"], depth: 2, signIn: [], runtime: "copilot"),
        Spec(id: "grok", name: "Grok CLI", bins: ["grok"], history: [".grok/sessions", ".grok/chats"], suffixes: [".json", ".jsonl"], depth: 2,
             signIn: [], runtime: "grok"),
        Spec(id: "ollama", name: "Ollama", bins: ["ollama"], history: [], suffixes: [], depth: 0, signIn: [], runtime: "ollama"),
        Spec(id: "cursor-agent", name: "Cursor CLI", bins: ["cursor-agent"], history: [], suffixes: [], depth: 0, signIn: [], runtime: nil),
        Spec(id: "aider", name: "Aider", bins: ["aider"], history: [], suffixes: [], depth: 0, signIn: [], runtime: nil),
        Spec(id: "opencode", name: "opencode", bins: ["opencode"], history: [], suffixes: [], depth: 0, signIn: [], runtime: nil),
    ]

    static let chatApps = ["ChatGPT", "Claude", "Perplexity", "Codex", "Gemini"]
    static let editors = ["Cursor", "Windsurf", "Visual Studio Code", "Zed", "Xcode"]
    static let localApps = ["LM Studio", "Ollama", "Msty", "Jan"]
    static let editorAIWords = ["copilot", "claude", "anthropic", "continue", "cline", "codeium", "openai", "chatgpt", "roo-cline", "kilo", "gemini", "amazon-q", "tabnine", "supermaven"]

    // MARK: what it finds

    public struct Tool: Equatable {
        public var id: String
        public var name: String
        public var installed: Bool
        /// nil: this tool's sign-in can't be seen from outside it.
        public var signedIn: Bool?
        public var conversations: Int
        public var last7: Int
        public var last30: Int
        public var lastUsed: Date?
        public var foldersLast30: Int
        public var runtime: String?
        public var active: Bool { last30 > 0 }
        /// Installed, with history, and none of it in 60 days.
        public func dormant(now: Date) -> Bool {
            installed && (lastUsed.map { now.timeIntervalSince($0) > 60 * 86400 } ?? true)
        }
    }

    /// A folder agents have worked in: shown to the person, never shared.
    public struct Folder: Equatable {
        public var path: String
        public var tools: [String]
        public var conversations: Int
        public var lastUsed: Date
        public var agents: [String]
        public var skills: Int
        public var commands: Int
        public var mcp: Int
        public var instructions: [String]
    }

    public struct Built: Equatable {
        public var agents = 0, skills = 0, commands = 0, mcp = 0, instructionFolders = 0
        public var total: Int { agents + skills + commands }
    }

    public enum Profile: String {
        case agentBuilder, multiTool, oneTool, local, installedUnused, chatOnly, newcomer
        public var title: String {
            switch self {
            case .agentBuilder: return "Builds their own agents"
            case .multiTool: return "Uses several agent tools"
            case .oneTool: return "Uses one agent tool"
            case .local: return "Runs models on this Mac"
            case .installedUnused: return "Has agent tools, hasn't used them much"
            case .chatOnly: return "Uses AI in a chat app"
            case .newcomer: return "New to AI agents"
            }
        }
    }

    /// A desk the check-up would start with: shown to the person, never shared.
    public struct Suggestion: Equatable {
        public var name: String
        public var runtime: String
        public var folder: String
        public var agent: String?
        public var why: String
    }

    public struct Report {
        public var tools: [Tool]
        public var chatApps: [String]
        public var editors: [String]
        public var editorAI: [String]
        public var localModels: Int
        public var localApps: [String]
        public var built: Built
        public var folders: [Folder]
        public var profile: Profile
        public var simple: Bool
        public var suggestions: [Suggestion]
        public var now: Date
        public var active: [Tool] { tools.filter(\.active) }
        public var dormant: [Tool] { tools.filter { !$0.active && $0.dormant(now: now) } }
    }

    // MARK: looking

    /// Files under `dir` ending in one of `suffixes`, at most `depth` folders down.
    static func files(_ dir: String, suffixes: [String], depth: Int, cap: Int = 20000) -> [(path: String, modified: Date)] {
        let fm = FileManager.default
        var out: [(String, Date)] = []
        var queue: [(String, Int)] = [(dir, 0)]
        while let next = queue.popLast(), out.count < cap {
            let (d, level) = next
            guard let names = try? fm.contentsOfDirectory(atPath: d) else { continue }
            for n in names where !n.hasPrefix(".") {
                let p = (d as NSString).appendingPathComponent(n)
                guard let a = try? fm.attributesOfItem(atPath: p) else { continue }
                if a[.type] as? FileAttributeType == .typeDirectory {
                    if level < depth { queue.append((p, level + 1)) }
                } else if suffixes.contains(where: { n.hasSuffix($0) }), let m = a[.modificationDate] as? Date {
                    out.append((p, m))
                }
            }
        }
        return out
    }

    /// The folder a conversation ran in: the first `"cwd":"…"` in its first
    /// 64KB. Only that field is looked for; nothing else in the file is read.
    static func cwd(of path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { h.closeFile() }
        let head = String(decoding: h.readData(ofLength: 64 * 1024), as: UTF8.self)
        guard let r = head.range(of: #""cwd"\s*:\s*"((?:[^"\\]|\\.)*)""#, options: .regularExpression) else { return nil }
        let field = String(head[r])
        guard let q = field.range(of: #":\s*""#, options: .regularExpression) else { return nil }
        let raw = String(field[q.upperBound...].dropLast())
        let value = (try? JSONSerialization.jsonObject(with: Data("\"\(raw)\"".utf8), options: .fragmentsAllowed) as? String) ?? raw
        return value.hasPrefix("/") ? value : nil
    }

    static func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    /// A folder agents ran in for a moment (a second opinion, a script), not one a person works in.
    public static var passingRoots = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
    public static func passing(_ path: String) -> Bool {
        passingRoots.contains { path.hasPrefix($0) || path + "/" == $0 }
    }

    /// One name for a folder however it was reached: links followed, so a
    /// folder moved and linked from its old place counts once.
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Files grouped into conversations: under a `perFolder` root, every file
    /// in one top folder is one conversation, dated by its newest file.
    static func conversations(_ found: [(path: String, modified: Date)], home: String, perFolder: [String]) -> [(path: String, modified: Date)] {
        let roots = perFolder.map { home + "/" + $0 + "/" }
        var groups: [String: Date] = [:]
        var out: [(String, Date)] = []
        for f in found {
            if let r = roots.first(where: { f.path.hasPrefix($0) }) {
                let top = r + (f.path.dropFirst(r.count).split(separator: "/").first.map(String.init) ?? "")
                groups[top] = max(groups[top] ?? .distantPast, f.modified)
            } else {
                out.append(f)
            }
        }
        return out + groups.map { ($0.key, $0.value) }
    }

    static func count(_ pattern: (dir: String, file: String?), suffix: String = ".md") -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        guard let names = try? fm.contentsOfDirectory(atPath: pattern.dir) else { return [] }
        for n in names.sorted() where !n.hasPrefix(".") {
            let p = (pattern.dir as NSString).appendingPathComponent(n)
            if let f = pattern.file {
                if exists((p as NSString).appendingPathComponent(f)) { out.append(n) }
            } else if n.hasSuffix(suffix) {
                out.append(String(n.dropLast(suffix.count)))
            } else {
                var dir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &dir), dir.boolValue {
                    out += count((p, nil), suffix: suffix).map { n + "/" + $0 }
                }
            }
        }
        return out
    }

    /// MCP servers in a JSON file's `mcpServers` (Claude, Cursor).
    static func mcpJSON(_ path: String) -> Int {
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return 0 }
        return (o["mcpServers"] as? [String: Any])?.count ?? 0
    }

    /// MCP servers in Codex's TOML: one `[mcp_servers.<name>]` table each.
    static func mcpTOML(_ path: String) -> Int {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return s.split(separator: "\n").filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[mcp_servers.") && !t.dropFirst("[mcp_servers.".count).contains(".")
        }.count
    }

    static func claudeSignedIn(home: String) -> Bool {
        if exists(home + "/.claude/.credentials.json") { return true }
        guard let d = FileManager.default.contents(atPath: home + "/.claude.json"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return o["oauthAccount"] != nil || o["primaryApiKey"] != nil
    }

    static func apps(_ names: [String], home: String, roots: [String]? = nil) -> [String] {
        let where_ = roots ?? ["/Applications", home + "/Applications"]
        return names.filter { n in where_.contains { exists("\($0)/\(n).app") } }
    }

    /// Look. `which` finds a command (DeskConfig.which outside tests).
    public static func run(home: String = NSHomeDirectory(), which: (String) -> String? = DeskConfig.which,
                           appRoots: [String]? = nil, now: Date = Date()) -> Report {
        var tools: [Tool] = []
        var byFolder: [String: (tools: Set<String>, n: Int, last: Date)] = [:]
        for s in specs {
            let installed = s.bins.contains { which($0) != nil }
            var found: [(path: String, modified: Date)] = []
            for h in s.history { found += files(home + "/" + h, suffixes: s.suffixes, depth: s.depth) }
            found = conversations(found, home: home, perFolder: s.perFolder)
            if !installed && found.isEmpty { continue }
            var recent = found.filter { now.timeIntervalSince($0.modified) < 30 * 86400 }
            var folders = Set<String>()
            // Where the last month's conversations ran, newest first, at most 300 looked at.
            // Runs in passing folders (second opinions, scripts) aren't the person's use.
            if s.id == "claude" || s.id == "codex" {
                var passed = Set<String>()
                for f in recent.sorted(by: { $0.modified > $1.modified }).prefix(300) {
                    guard let raw = cwd(of: f.path) else { continue }
                    if passing(raw) { passed.insert(f.path); continue }
                    let c = canonical(raw)
                    guard exists(c) else { continue }
                    folders.insert(c)
                    var e = byFolder[c] ?? ([], 0, .distantPast)
                    e.tools.insert(s.name); e.n += 1; e.last = max(e.last, f.modified)
                    byFolder[c] = e
                }
                found.removeAll { passed.contains($0.path) }
                recent.removeAll { passed.contains($0.path) }
            }
            var signedIn: Bool? = s.signIn.isEmpty ? nil : s.signIn.contains { exists(home + "/" + $0) }
            if s.id == "claude" { signedIn = claudeSignedIn(home: home) }
            tools.append(Tool(id: s.id, name: s.name, installed: installed, signedIn: signedIn, conversations: found.count,
                              last7: found.filter { now.timeIntervalSince($0.modified) < 7 * 86400 }.count, last30: recent.count,
                              lastUsed: found.map(\.modified).max(), foldersLast30: folders.count, runtime: s.runtime))
        }

        // What's been built on top: for the person as a whole, and per folder.
        var built = Built()
        built.agents = count((home + "/.claude/agents", nil)).count
        built.skills = count((home + "/.claude/skills", "SKILL.md")).count
        built.commands = count((home + "/.claude/commands", nil)).count
        built.mcp = mcpJSON(home + "/.claude.json") + mcpTOML(home + "/.codex/config.toml") + mcpJSON(home + "/.cursor/mcp.json")
        if exists(home + "/.claude/CLAUDE.md") || exists(home + "/.codex/AGENTS.md") { built.instructionFolders += 1 }

        var folders: [Folder] = []
        for (path, e) in byFolder.sorted(by: { $0.value.last > $1.value.last }).prefix(12) {
            let agents = count((path + "/.claude/agents", nil))
            let f = Folder(path: path, tools: e.tools.sorted(), conversations: e.n, lastUsed: e.last, agents: agents,
                           skills: count((path + "/.claude/skills", "SKILL.md")).count, commands: count((path + "/.claude/commands", nil)).count,
                           mcp: mcpJSON(path + "/.mcp.json"),
                           instructions: ["CLAUDE.md", "AGENTS.md", "GEMINI.md"].filter { exists(path + "/" + $0) })
            built.agents += f.agents.count; built.skills += f.skills; built.commands += f.commands; built.mcp += f.mcp
            if !f.instructions.isEmpty { built.instructionFolders += 1 }
            folders.append(f)
        }

        let chat = apps(chatApps, home: home, roots: appRoots)
        let eds = apps(editors, home: home, roots: appRoots)
        var editorAI = Set<String>()
        for dir in [".vscode/extensions", ".cursor/extensions", ".windsurf/extensions"] {
            for n in (try? FileManager.default.contentsOfDirectory(atPath: home + "/" + dir)) ?? [] {
                let l = n.lowercased()
                if let w = editorAIWords.first(where: { l.contains($0) }) { editorAI.insert(w) }
            }
        }
        let models = files(home + "/.ollama/models/manifests", suffixes: [""], depth: 4).count
        let local = apps(localApps, home: home, roots: appRoots)

        var r = Report(tools: tools, chatApps: chat, editors: eds, editorAI: editorAI.sorted(), localModels: models, localApps: local,
                       built: built, folders: folders, profile: .newcomer, simple: true, suggestions: [], now: now)
        r.profile = profile(r)
        r.simple = [.oneTool, .local, .installedUnused, .chatOnly, .newcomer].contains(r.profile)
        r.suggestions = suggest(r, home: home)
        return r
    }

    // MARK: made up, for snapshots

    /// A made-up check-up for each kind of person: snapshots of Welcome show
    /// these, never the real Mac's folders. Paths are neutral (`/srv/demo`).
    public static func demo(_ p: Profile, now: Date = Date()) -> Report {
        func tool(_ id: String, _ name: String, _ rt: String?, installed: Bool = true, n: Int = 0, week: Int = 0, month: Int = 0,
                  days: Double? = nil, folders: Int = 0) -> Tool {
            Tool(id: id, name: name, installed: installed, signedIn: true, conversations: n, last7: week, last30: month,
                 lastUsed: days.map { now.addingTimeInterval(-$0 * 86400) }, foldersLast30: folders, runtime: rt)
        }
        func folder(_ path: String, _ tools: [String], _ n: Int, days: Double, agents: [String] = []) -> Folder {
            Folder(path: path, tools: tools, conversations: n, lastUsed: now.addingTimeInterval(-days * 86400), agents: agents,
                   skills: 0, commands: 0, mcp: 0, instructions: ["CLAUDE.md"])
        }
        var r = Report(tools: [], chatApps: [], editors: ["Visual Studio Code"], editorAI: [], localModels: 0, localApps: [],
                       built: Built(), folders: [], profile: p, simple: true, suggestions: [], now: now)
        switch p {
        case .agentBuilder:
            r.tools = [tool("claude", "Claude Code", "claude", n: 120, week: 18, month: 64, days: 0, folders: 2),
                       tool("codex", "Codex", "codex", n: 30, week: 2, month: 9, days: 3, folders: 1),
                       tool("copilot", "GitHub Copilot CLI", "copilot", n: 4, days: 80)]
            r.folders = [folder("/srv/demo/workspace", ["Claude Code", "Codex"], 52, days: 0,
                                agents: ["research", "taxes", "deals", "health", "writing", "travel"]),
                         folder("/srv/demo/site", ["Claude Code"], 11, days: 4)]
            r.built = Built(agents: 6, skills: 3, commands: 4, mcp: 2, instructionFolders: 2)
            r.chatApps = ["Claude"]
            r.simple = false
        case .multiTool:
            r.tools = [tool("claude", "Claude Code", "claude", n: 80, week: 12, month: 40, days: 0, folders: 3),
                       tool("codex", "Codex", "codex", n: 25, week: 5, month: 14, days: 1, folders: 2)]
            r.folders = [folder("/srv/demo/api", ["Claude Code", "Codex"], 26, days: 0), folder("/srv/demo/app", ["Claude Code"], 18, days: 2),
                         folder("/srv/demo/notes", ["Codex"], 7, days: 9)]
            r.simple = false
        case .oneTool:
            r.tools = [tool("claude", "Claude Code", "claude", n: 40, week: 9, month: 22, days: 0, folders: 2)]
            r.folders = [folder("/srv/demo/api", ["Claude Code"], 15, days: 0), folder("/srv/demo/blog", ["Claude Code"], 7, days: 6)]
        case .local:
            r.tools = [tool("ollama", "Ollama", "ollama")]
            r.localModels = 3
        case .installedUnused:
            r.tools = [tool("codex", "Codex", "codex", n: 2, days: 70)]
            r.chatApps = ["ChatGPT"]
        case .chatOnly:
            r.chatApps = ["ChatGPT"]
        case .newcomer:
            break
        }
        return r
    }

    // MARK: reading it

    static func profile(_ r: Report) -> Profile {
        let active = r.active.filter { $0.id != "ollama" }
        if !active.isEmpty && r.built.total >= 3 { return .agentBuilder }
        if active.count >= 2 { return .multiTool }
        if active.count == 1 { return .oneTool }
        if r.localModels > 0 { return .local }
        if r.tools.contains(where: \.installed) { return .installedUnused }
        if !r.chatApps.isEmpty { return .chatOnly }
        return .newcomer
    }

    /// Where to start: a few desks, never one per installed tool.
    static func suggest(_ r: Report, home: String) -> [Suggestion] {
        let main = r.active.filter { $0.runtime != nil && $0.id != "ollama" }.sorted { $0.last30 > $1.last30 }
        func short(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
        switch r.profile {
        case .agentBuilder:
            var out: [Suggestion] = []
            for f in r.folders where !f.agents.isEmpty {
                out.append(Suggestion(name: (f.path as NSString).lastPathComponent, runtime: "claude", folder: short(f.path), agent: nil,
                                      why: "\(f.agents.count) agents you built here: choose the ones to make desks for"))
                if out.count >= 3 { break }
            }
            if out.isEmpty, let t = main.first, let f = r.folders.first {
                out.append(Suggestion(name: (f.path as NSString).lastPathComponent, runtime: t.runtime ?? "claude", folder: short(f.path), agent: nil,
                                      why: "where you used \(t.name) most recently"))
            }
            return out
        case .multiTool, .oneTool:
            return r.folders.prefix(r.profile == .oneTool ? 2 : 3).map { f in
                let tool = main.first { f.tools.contains($0.name) } ?? main.first
                return Suggestion(name: (f.path as NSString).lastPathComponent, runtime: tool?.runtime ?? "claude", folder: short(f.path), agent: nil,
                                  why: "\(f.conversations) conversation\(f.conversations == 1 ? "" : "s") here this month, picked up where they left off")
            }
        case .local:
            return [Suggestion(name: "local", runtime: "ollama", folder: "~/Coldfall/local", agent: nil, why: "free, on this Mac, with the models you already have")]
        case .installedUnused:
            let t = r.tools.first { $0.installed && $0.runtime != nil && $0.signedIn != false } ?? r.tools.first { $0.installed && $0.runtime != nil }
            return t.map { [Suggestion(name: "first", runtime: $0.runtime!, folder: "~/Coldfall/first", agent: nil, why: "\($0.name) is installed; start with one job")] } ?? []
        case .chatOnly, .newcomer:
            return []
        }
    }

    static func when(_ d: Date?, now: Date) -> String {
        guard let d else { return "no history found" }
        let days = Int(now.timeIntervalSince(d) / 86400)
        return days < 1 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
    }

    /// The whole report, for the person on their own Mac.
    public static func describe(_ r: Report) -> String {
        var s = "Your AI check-up\n\nProfile: \(r.profile.title)\n"
        s += "\nAgent tools\n"
        if r.tools.isEmpty { s += "  none installed\n" }
        for t in r.tools {
            var l = "  \(t.name): "
            if !t.installed { l += "not installed, but " }
            if t.conversations == 0 { l += t.runtime == "ollama" ? "installed" : "installed, no conversations found" }
            else {
                l += "\(t.conversations) conversation\(t.conversations == 1 ? "" : "s"), \(t.last7) this week, \(t.last30) this month"
                if t.foldersLast30 > 0 { l += ", in \(t.foldersLast30) folder\(t.foldersLast30 == 1 ? "" : "s")" }
                l += "; last \(when(t.lastUsed, now: r.now))"
            }
            if t.signedIn == false { l += " (not signed in)" }
            s += l + "\n"
        }
        if !r.dormant.isEmpty { s += "  No use found in the last 60 days: \(r.dormant.map(\.name).joined(separator: ", "))\n" }
        s += "\nWhat you've built\n"
        s += "  \(r.built.agents) custom agents, \(r.built.skills) skills, \(r.built.commands) commands, \(r.built.mcp) MCP servers"
        s += ", instruction files in \(r.built.instructionFolders) place\(r.built.instructionFolders == 1 ? "" : "s")\n"
        if !r.folders.isEmpty {
            s += "\nWhere agents worked this month\n"
            for f in r.folders {
                var l = "  \(f.path)  \(f.conversations) conversation\(f.conversations == 1 ? "" : "s") (\(f.tools.joined(separator: ", "))), last \(when(f.lastUsed, now: r.now))"
                if !f.agents.isEmpty { l += ", \(f.agents.count) agents" }
                s += l + "\n"
            }
        }
        s += "\nApps\n"
        s += "  Chat apps: \(r.chatApps.isEmpty ? "none" : r.chatApps.joined(separator: ", "))\n"
        s += "  Editors: \(r.editors.isEmpty ? "none" : r.editors.joined(separator: ", "))"
        s += r.editorAI.isEmpty ? ", no AI add-ons\n" : ", AI add-ons: \(r.editorAI.joined(separator: ", "))\n"
        s += "  Local models: \(r.localModels)" + (r.localApps.isEmpty ? "" : " (\(r.localApps.joined(separator: ", ")))") + "\n"
        s += "\nSuggested start\n"
        s += r.simple ? "  The simple window: one desk to begin with, more when you want them.\n" : "  The full window: you already work across several agents.\n"
        for g in r.suggestions { s += "  • \(g.name) (\(g.runtime)) in \(g.folder): \(g.why)\n" }
        switch r.profile {
        case .chatOnly: s += "  • Coldfall runs agent tools, not chat apps. The one that matches \(r.chatApps.contains("ChatGPT") ? "ChatGPT is Codex" : "Claude is Claude Code"), and Welcome helps install it.\n"
        case .newcomer: s += "  • Install one agent tool first; Welcome lists them, with the plan each one needs.\n"
        default: break
        }
        if !r.dormant.isEmpty { s += "  • No desks for \(r.dormant.map(\.name).joined(separator: ", ")) for now: you haven't used \(r.dormant.count == 1 ? "it" : "them") lately.\n" }
        s += "\nNothing here left this Mac. `coldfall-cli checkup --share` makes a version without names to send.\n"
        return s
    }

    /// The version to send: counts and the profile, no folder, agent or desk names.
    public static func share(_ r: Report, version: String = "", macOS: String = ProcessInfo.processInfo.operatingSystemVersionString) -> String {
        var s = "Coldfall check-up (shared summary: counts only, no names or folders)\n"
        s += "Profile: \(r.profile.title)\n"
        let used = r.active.map { "\($0.name) (\($0.last30) this month, \($0.last7) this week)" }
        s += "In use: \(used.isEmpty ? "none" : used.joined(separator: ", "))\n"
        let quiet = r.tools.filter { !$0.active }.map(\.name)
        if !quiet.isEmpty { s += "Installed, not used this month: \(quiet.joined(separator: ", "))\n" }
        s += "Works in \(r.folders.count) folder\(r.folders.count == 1 ? "" : "s") this month\n"
        s += "Built: \(r.built.agents) agents, \(r.built.skills) skills, \(r.built.commands) commands, \(r.built.mcp) MCP servers, instruction files in \(r.built.instructionFolders)\n"
        s += "Chat apps: \(r.chatApps.isEmpty ? "none" : r.chatApps.joined(separator: ", ")); editors: \(r.editors.isEmpty ? "none" : r.editors.joined(separator: ", "))"
        s += r.editorAI.isEmpty ? " (no AI add-ons)" : " (AI add-ons: \(r.editorAI.joined(separator: ", ")))"
        s += "; local models: \(r.localModels)\n"
        s += "Suggested: \(r.simple ? "simple window" : "full window"), \(r.suggestions.count) starting desk\(r.suggestions.count == 1 ? "" : "s")\n"
        var tail: [String] = []
        if !version.isEmpty { tail.append("Coldfall \(version)") }
        if !macOS.isEmpty { tail.append("macOS \(macOS.replacingOccurrences(of: "Version ", with: ""))") }
        if !tail.isEmpty { s += tail.joined(separator: ", ") + "\n" }
        return s
    }
}
