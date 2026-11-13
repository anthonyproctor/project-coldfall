import Foundation

public struct BridgeError: Error {
    public let message: String
    public init(message: String) { self.message = message }
}

/// Cross-vendor handoff — a MAILBOX, not a protocol.
///
/// Two agents from different companies pass work back and forth through an
/// append-only markdown thread. A wire protocol is the obvious design and the
/// wrong one here:
///
///   * Vendor-agnostic. Anything with a headless mode can join. No adapter, no
///     SDK, no version coupling to anybody's release train.
///   * The thread IS the context. Each headless invocation starts with no
///     memory, so the file carries the conversation. This is why it APPENDS:
///     replacing the thread once destroyed a long exchange by overwriting it
///     with an answer from a session that had never read it.
///   * Inspectable. The exchange is a file you can read, diff, and keep.
///   * The responder is READ-ONLY, enforced by the vendor's own flag, so a
///     second opinion can never quietly edit your workspace.
///
/// Credit where due: this pattern comes from a working hand-rolled setup
/// (`ask-claude.sh` driving a pair of markdown files). Coldfall generalises it
/// to arbitrary runtime pairs and ships it built in, so a new user needs
/// nothing but the CLIs they already have.
public enum Bridge {

    public struct Runtime {
        public var name: String
        public let bin: String
        /// argv for a headless, read-only answer. `out` is a file the runtime
        /// may write its FINAL message to; without it some CLIs return their
        /// entire working transcript, which buries the answer.
        public let argv: (String, String?) -> [String]
        /// Whether read-only is ENFORCED by a vendor flag or merely requested in
        /// the prompt. Shown in the UI; never overstated.
        public let readOnlyEnforced: Bool
        /// True if the CLI can write just its final message to a file.
        public let hasFinalMessageFlag: Bool
        /// Runs entirely on this machine. The important consequence is that
        /// nothing in the thread, and nothing the responder reads, leaves the
        /// host — which is the honest answer to a workspace holding anything
        /// you would not hand to a vendor.
        public let isLocal: Bool
        /// Set for the process, e.g. CLAUDE_CONFIG_DIR for another account.
        public var env: [String: String] = [:]
    }

    public static let known: [Runtime] = [
        Runtime(name: "claude", bin: "claude",
                argv: { p, _ in ["-p", p, "--permission-mode", "plan"] },
                readOnlyEnforced: true, hasFinalMessageFlag: false, isLocal: false),
        // `-o` keeps the answer out of the transcript spew. Without it a single
        // review returned 46KB of grep output with the answer buried at the end.
        Runtime(name: "codex", bin: "codex",
                argv: { p, out in
                    var a = ["exec", "--sandbox", "read-only"]
                    if let out { a += ["-o", out] }
                    a.append(p); return a
                },
                readOnlyEnforced: true, hasFinalMessageFlag: true, isLocal: false),
        // Google's CLI for its AI Pro and Ultra plans, which replaced Gemini
        // CLI sign-in for personal accounts in June 2026.
        // Plan mode asks it not to change anything; nothing documents that as
        // enforced, so the panel doesn't claim it. The timeout is there
        // because print mode has been reported to hang without a terminal.
        Runtime(name: "antigravity", bin: "agy",
                argv: { p, _ in ["-p", p, "--mode", "plan", "--print-timeout", "10m"] }, readOnlyEnforced: false, hasFinalMessageFlag: false, isLocal: false),
        Runtime(name: "copilot", bin: "copilot",
                argv: { p, _ in ["-p", p] }, readOnlyEnforced: false, hasFinalMessageFlag: false, isLocal: false),
        // grok has a headless -p but no sandbox flag, so read-only can only be
        // asked for in the prompt. The panel says so rather than implying more.
        Runtime(name: "grok", bin: "grok",
                argv: { p, _ in ["-p", p] }, readOnlyEnforced: false, hasFinalMessageFlag: false, isLocal: false),
        // Local. Nothing leaves the machine, which makes it the right responder
        // for a workspace you would not expose to a hosted vendor. The model is
        // taken from the desk's `model` field, defaulting to whatever ollama has.
        Runtime(name: "ollama", bin: "ollama",
                argv: { p, _ in ["run", ProcessInfo.processInfo.environment["COLDFALL_OLLAMA_MODEL"] ?? "llama3", p] },
                readOnlyEnforced: false, hasFinalMessageFlag: false, isLocal: true),
    ]

    /// What can answer: every installed runtime, and Claude once more for
    /// each other account desks use, so one plan can ask another.
    public static func available(accounts: [ClaudeAccount] = ClaudeAccount.known()) -> [Runtime] {
        let installed = known.filter { DeskConfig.which($0.bin) != nil }
        return installed + (installed.first { $0.name == "claude" }.map { claude in
            accounts.map { account(claude, $0) } } ?? [])
    }
    public static func runtime(named n: String, accounts: [ClaudeAccount] = []) -> Runtime? {
        if let r = known.first(where: { $0.name == n }) { return r }
        guard let a = accounts.first(where: { $0.vendor == n }),
              let claude = known.first(where: { $0.name == "claude" }) else { return nil }
        return account(claude, a)
    }
    /// Claude, on another account.
    static func account(_ claude: Runtime, _ a: ClaudeAccount) -> Runtime {
        var r = claude
        r.name = a.vendor
        r.env = ["CLAUDE_CONFIG_DIR": a.path()]
        return r
    }

    /// Wraps the thread so the responder knows it is reviewing, not driving.
    public static func framePrompt(thread: String, ask: String, enforced: Bool) -> String {
        var p = """
        You are taking part in an agent-to-agent review. Another AI agent is asking you \
        to look at something in this workspace and answer.

        Be precise. Challenge claims that are not supported. Cite file paths and line \
        numbers. If you disagree with the other agent, say so plainly and say why.
        """
        if !enforced {
            p += "\n\nDo not edit, delete, commit, push, or make any external change. Answer only."
        }
        if !thread.isEmpty {
            p += "\n\nTHREAD SO FAR (oldest first):\n\n\(thread)"
        }
        p += "\n\nLATEST MESSAGE, answer this:\n\n\(ask)"
        return p
    }
}

/// One append-only thread between two runtimes.
public struct Mailbox {
    public var dir: String
    /// A `runner =` line from an older bridge.toml. Never used: the handoff
    /// is always the built-in one. Kept only so Settings can say so.
    public var runner: String?
    /// The directory the RESPONDER runs in. This is a privacy boundary, not a
    /// convenience: read-only blocks writes, not reads, so the other vendor can
    /// read every file under this path. Defaults to the desk's own cwd; set
    /// `scope` in bridge.toml to narrow it.
    public var scope: String?
    public var legacyOutbound: String?
    public var legacyInbound: String?

    public static let configPath = NSString(string: "~/.config/coldfall/bridge.toml").expandingTildeInPath
    public static let defaultDir = NSString(string: "~/.local/share/coldfall/mail").expandingTildeInPath

    /// Always returns a usable mailbox. No config means the built-in one.
    public static func load() -> Mailbox {
        // COLDFALL_MAIL_DIR: a mailbox somewhere else, for pictures of
        // made-up threads.
        if let d = ProcessInfo.processInfo.environment["COLDFALL_MAIL_DIR"] { return Mailbox(dir: d) }
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return Mailbox(dir: defaultDir)
        }
        var kv: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            var line = String(raw)
            line = TomlText.stripComment(line)
            guard let eq = line.firstIndex(of: "=") else { continue }
            kv[String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return Mailbox(dir: NSString(string: kv["dir"] ?? defaultDir).expandingTildeInPath,
                       runner: kv["runner"],
                       scope: kv["scope"].map { NSString(string: $0).expandingTildeInPath },
                       legacyOutbound: kv["outbound"],
                       legacyInbound: kv["inbound"])
    }


    public func threadPath(_ a: String, _ b: String) -> String {
        if let o = legacyInbound { return (dir as NSString).appendingPathComponent(o) }
        let pair = [a, b].sorted().joined(separator: "-")
        return (dir as NSString).appendingPathComponent("thread-\(pair).md")
    }

    public func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    /// Append, never replace.
    public func append(_ text: String, who: String, to path: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm zzz"
        let block = "\n\n---\n\n## \(who) · \(f.string(from: Date()))\n\n\(text)\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(block.data(using: .utf8)!); fh.closeFile()
        } else {
            try? block.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Ask `to` to answer, with the whole thread as context. Appends the reply.
    /// Where the responder will actually be able to read.
    public func effectiveScope(deskCwd: String) -> String { scope ?? deskCwd }

    public func ask(from: String, to rt: Bridge.Runtime, message: String, cwd deskCwd: String,
             completion: @escaping (Result<String, BridgeError>) -> Void) {
        let cwd = effectiveScope(deskCwd: deskCwd)
        let path = threadPath(from, rt.name)
        append(message, who: from, to: path)
        let thread = read(path)
        let prompt = Bridge.framePrompt(thread: thread, ask: message, enforced: rt.readOnlyEnforced)

        guard let bin = DeskConfig.which(rt.bin) else {
            completion(.failure(BridgeError(message: "\(rt.bin) is not on PATH"))); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let finalFile = rt.hasFinalMessageFlag
                ? NSTemporaryDirectory() + "coldfall-reply-\(UUID().uuidString).txt" : nil
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = rt.argv(prompt, finalFile)
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            // A nested agent session refuses to start; clear the marker.
            var env = ProcessInfo.processInfo.environment
            env["CLAUDECODE"] = ""; env["CLAUDE_CODE_ENTRYPOINT"] = ""
            env.merge(rt.env) { $1 }
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch {
                DispatchQueue.main.async { completion(.failure(BridgeError(message: "could not start \(rt.bin): \(error)"))) }
                return
            }
            let (d, e, timedOut) = Subprocess.drain(p, out: out, err: err, timeout: Fanout.sliceTimeout)
            if timedOut {
                let note = "gave up after \(Int(Fanout.sliceTimeout / 60)) minutes. It was stopped."
                self.append(note, who: rt.name, to: path)
                DispatchQueue.main.async { completion(.failure(BridgeError(message: note))) }
                return
            }
            var reply = ""
            if let f = finalFile, let only = try? String(contentsOfFile: f, encoding: .utf8),
               !only.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reply = only                       // just the answer
                try? FileManager.default.removeItem(atPath: f)
            } else {
                reply = String(data: d, encoding: .utf8) ?? ""
            }
            if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reply = String(data: e, encoding: .utf8) ?? "(no output)"
            }
            append(reply, who: rt.name, to: path)
            DispatchQueue.main.async { completion(.success(reply)) }
        }
    }
}
