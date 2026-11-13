import Foundation

/// What an agent changed in its folder, and your notes on it sent back.
///
/// Reading is all Coldfall does to the repository: `git status` and
/// `git diff`, with optional locks off so it never contends with the
/// agent's own git. Nothing is staged, committed or reverted from here.
public enum Changes {

    public struct File: Equatable {
        public let path: String
        /// "M" modified, "A" added, "D" deleted, "R" renamed, "?" untracked.
        public let status: String
        public init(path: String, status: String) { self.path = path; self.status = status }
    }

    /// `git status --porcelain=v1 -z`: entries are "XY path", NUL-ended; a
    /// rename is followed by one more entry, the path it came from.
    public static func parseStatus(_ z: String) -> [File] {
        var out: [File] = []
        var parts = z.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let e = parts.next() {
            guard e.count > 3 else { continue }
            let xy = e.prefix(2), path = String(e.dropFirst(3))
            let code: String
            if xy == "??" { code = "?" }
            else if xy.contains("R") { code = "R"; _ = parts.next() }
            else if xy.contains("C") { code = "A"; _ = parts.next() }
            else if xy.contains("D") { code = "D" }
            else if xy.contains("A") { code = "A" }
            else { code = "M" }
            out.append(File(path: path, status: code))
        }
        return out
    }

    public struct Line: Equatable {
        public enum Kind: Equatable { case meta, hunk, context, added, removed }
        public let kind: Kind
        public let text: String
        /// The line's number in the file as it is now (nil for removed lines and headers).
        public let number: Int?
        public init(_ kind: Kind, _ text: String, _ number: Int? = nil) { self.kind = kind; self.text = text; self.number = number }
    }

    /// A unified diff as lines, each knowing its number in the new file.
    public static func parseDiff(_ diff: String) -> [Line] {
        var out: [Line] = []
        var n = 0
        var inHunk = false
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(raw)
            if l.hasPrefix("@@") {
                // @@ -a,b +c,d @@
                inHunk = true
                if let plus = l.range(of: "+"), let end = l[plus.upperBound...].firstIndex(where: { $0 == "," || $0 == " " }) {
                    n = Int(l[plus.upperBound..<end]) ?? 1
                } else { n = 1 }
                out.append(Line(.hunk, l))
            } else if !inHunk {
                if !l.isEmpty { out.append(Line(.meta, l)) }
            } else if l.hasPrefix("+") {
                out.append(Line(.added, String(l.dropFirst()), n)); n += 1
            } else if l.hasPrefix("-") {
                out.append(Line(.removed, String(l.dropFirst())))
            } else if l.hasPrefix("\\") {
                out.append(Line(.meta, l))
            } else if l.hasPrefix("diff --git") {
                inHunk = false
                out.append(Line(.meta, l))
            } else {
                out.append(Line(.context, l.isEmpty ? "" : String(l.dropFirst()), n)); n += 1
            }
        }
        while let last = out.last, last.kind == .context, last.text.isEmpty { out.removeLast() }
        return out
    }

    /// A whole new file, as a diff of nothing but additions.
    public static func asAdded(_ text: String, limit: Int = 2000) -> [Line] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(limit)
        return lines.enumerated().map { Line(.added, String($0.element), $0.offset + 1) }
    }

    public struct Comment: Equatable {
        public let file: String
        public let line: Int?
        /// The code the comment is on, for the agent to find it by.
        public let quote: String
        public let text: String
        public init(file: String, line: Int?, quote: String, text: String) {
            self.file = file; self.line = line; self.quote = quote; self.text = text
        }
    }

    /// The comments as one message to the agent. One paragraph per comment,
    /// each naming its file and line and quoting the code, so it reads the
    /// same whether the agent looks the line up or not. No newline at the
    /// end: sending adds the Return.
    public static func compose(_ comments: [Comment]) -> String {
        guard !comments.isEmpty else { return "" }
        var s = comments.count == 1 ? "A review comment on your changes:" : "\(comments.count) review comments on your changes:"
        for (i, c) in comments.enumerated() {
            let at = c.line.map { "\(c.file):\($0)" } ?? c.file
            let quote = c.quote.trimmingCharacters(in: .whitespaces)
            s += "\n\n\(i + 1). \(at)"
            if !quote.isEmpty { s += "  `" + (quote.count > 120 ? String(quote.prefix(119)) + "…" : quote) + "`" }
            s += "\n   " + c.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\n   ")
        }
        return s
    }

    // MARK: - reading the repository

    /// Run git, read-only, in a folder. Nil when it isn't a repository,
    /// git isn't there, or it took too long.
    public static func git(_ arguments: [String], in folder: String, timeout: TimeInterval = 8,
                           extraEnv: [String: String] = [:]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", folder] + arguments
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let r = Subprocess.drain(p, out: out, err: err, timeout: timeout)
        guard !r.timedOut, p.terminationStatus == 0 || p.terminationStatus == 1 else { return nil }
        return String(decoding: r.out, as: UTF8.self)
    }

    // MARK: - a turn's changes

    /// The folder as it is right now, as a git tree: every file, tracked or
    /// not (ignored ones aside). Taken with a throwaway copy of the index,
    /// so the real index, HEAD and the working files are never touched; the
    /// only thing written is unreferenced objects, which git clears itself.
    ///
    /// Two of these, one when you send a prompt and one now, are what
    /// "what did this turn change" is the difference between.
    public static func snapshot(in folder: String) -> String? {
        guard let real = git(["rev-parse", "--git-path", "index"], in: folder)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !real.isEmpty else { return nil }
        let realPath = real.hasPrefix("/") ? real : (folder as NSString).appendingPathComponent(real)
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("coldfall-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: tmp); try? FileManager.default.removeItem(atPath: tmp + ".lock") }
        // Starting from the real index lets git skip files it already knows.
        try? FileManager.default.copyItem(atPath: realPath, toPath: tmp)
        let env = ["GIT_INDEX_FILE": tmp]
        guard git(["add", "-A"], in: folder, timeout: 30, extraEnv: env) != nil,
              let tree = git(["write-tree"], in: folder, timeout: 15, extraEnv: env)?.trimmingCharacters(in: .whitespacesAndNewlines),
              tree.count >= 40 else { return nil }
        return tree
    }

    /// `git diff --name-status -z`: "M", NUL, path, NUL; a rename is
    /// "R100", NUL, old, NUL, new, NUL.
    public static func parseNameStatus(_ z: String) -> [File] {
        var out: [File] = []
        var parts = z.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let code = parts.next() {
            guard let c = code.first, let path = parts.next() else { break }
            if c == "R" || c == "C" {
                guard let to = parts.next() else { break }
                out.append(File(path: String(to), status: c == "R" ? "R" : "A"))
            } else {
                out.append(File(path: String(path), status: c == "A" ? "A" : (c == "D" ? "D" : "M")))
            }
        }
        return out
    }

    /// What changed between two snapshots.
    public static func files(from a: String, to b: String, in folder: String) -> [File]? {
        git(["diff", "--name-status", "-z", a, b], in: folder).map(parseNameStatus)
    }

    public static func diff(_ file: File, from a: String, to b: String, in folder: String) -> [Line] {
        guard let text = git(["diff", "--no-color", "--no-ext-diff", a, b, "--", file.path], in: folder) else {
            return [Line(.meta, "Couldn't read this file's changes.")]
        }
        let lines = parseDiff(text)
        return lines.isEmpty ? [Line(.meta, "No text changes (binary, or only its mode changed).")] : lines
    }

    public static func files(in folder: String) -> [File]? {
        git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: folder).map(parseStatus)
    }

    /// One file's changes against the last commit; a new file in full.
    public static func diff(_ file: File, in folder: String) -> [Line] {
        if file.status == "?" {
            let path = (folder as NSString).appendingPathComponent(file.path)
            guard let d = FileManager.default.contents(atPath: path), d.count < 1_000_000,
                  let text = String(data: d, encoding: .utf8) else { return [Line(.meta, "A new file (not shown: binary or large).")] }
            return asAdded(text)
        }
        guard let text = git(["diff", "HEAD", "--no-color", "--no-ext-diff", "--", file.path], in: folder) else {
            return [Line(.meta, "Couldn't read this file's changes.")]
        }
        let lines = parseDiff(text)
        return lines.isEmpty ? [Line(.meta, "No text changes (binary, or only its mode changed).")] : lines
    }
}
