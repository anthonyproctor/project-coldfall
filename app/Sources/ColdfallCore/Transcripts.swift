import Foundation

/// The conversations an agent has had in a folder, found on disk where each
/// vendor keeps them, to search and to pick one back up.
///
/// A desk that has lived for weeks has dozens. This reads only what is
/// already on this Mac (Claude Code's project folders, Codex's session
/// rollouts), sends nothing anywhere, and never writes to them.
public enum Transcripts {

    public struct Conversation: Equatable {
        public let vendor: String          // "claude" or "codex"
        public let id: String
        public let path: String
        public let folder: String?
        public let modified: Date
        public let bytes: Int
        /// The name it was given, if any.
        public let title: String?
        /// The first thing you asked, cut to a line.
        public let firstPrompt: String?
        public var heading: String { title ?? firstPrompt ?? "(no prompt found)" }
        public init(vendor: String, id: String, path: String, folder: String?, modified: Date, bytes: Int,
                    title: String?, firstPrompt: String?) {
            self.vendor = vendor; self.id = id; self.path = path; self.folder = folder
            self.modified = modified; self.bytes = bytes; self.title = title; self.firstPrompt = firstPrompt
        }
    }

    public static var codexRoot: String { Resume.codexSessionsRoot }

    /// How to pick a conversation back up, as a command for a shell.
    public static func resumeCommand(_ c: Conversation) -> String? {
        guard c.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), !c.id.isEmpty else { return nil }
        switch c.vendor {
        case "claude": return "claude --resume \(c.id)"
        case "codex": return "codex resume \(c.id)"
        default: return nil
        }
    }

    static func clip(_ s: String, _ n: Int = 140) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > n ? String(t.prefix(n - 1)) + "…" : t
    }

    /// Text you typed, out of a message's content: a string, or a list of
    /// parts with "text". Wrappers the tools add (tags, tool results) are
    /// not what you asked.
    static func userText(_ content: Any?) -> String? {
        var text: String?
        if let s = content as? String { text = s }
        else if let parts = content as? [[String: Any]] {
            text = parts.compactMap { p -> String? in
                guard let t = p["type"] as? String, t == "text" || t == "input_text" else { return nil }
                return p["text"] as? String
            }.first
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") else { return nil }
        return t
    }

    /// Title and first prompt from the head of a Claude Code transcript.
    public static func claudeHead(_ text: String) -> (title: String?, prompt: String?) {
        var title: String?, prompt: String?
        for line in text.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "custom-title": title = (o["customTitle"] as? String) ?? title
            case "summary": if title == nil { title = o["summary"] as? String }
            case "user":
                guard prompt == nil, o["isMeta"] as? Bool != true, o["isSidechain"] as? Bool != true,
                      let m = o["message"] as? [String: Any], let t = userText(m["content"]) else { continue }
                prompt = clip(t)
            default: break
            }
            if title != nil, prompt != nil { break }
        }
        return (title, prompt)
    }

    /// Folder, id and first prompt from the head of a Codex rollout.
    public static func codexHead(_ text: String) -> (id: String?, folder: String?, prompt: String?) {
        var id: String?, folder: String?, prompt: String?
        for line in text.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let p = o["payload"] as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "session_meta":
                id = (p["id"] as? String) ?? id
                folder = (p["cwd"] as? String) ?? folder
            case "response_item":
                guard prompt == nil, p["type"] as? String == "message", p["role"] as? String == "user",
                      let t = userText(p["content"]) else { continue }
                prompt = clip(t)
            default: break
            }
            if id != nil, prompt != nil { break }
        }
        return (id, folder, prompt)
    }

    static func head(_ path: String, bytes: Int = 256 * 1024) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        return String(decoding: fh.readData(ofLength: bytes), as: UTF8.self)
    }

    static func stat(_ path: String) -> (Date, Int)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let d = a[.modificationDate] as? Date, let n = a[.size] as? Int else { return nil }
        return (d, n)
    }

    /// Claude Code's conversations for a folder, newest first.
    public static func claude(folder: String, root: String = Resume.claudeProjectsRoot) -> [Conversation] {
        let dir = Resume.claudeProjectDir(for: folder, root: root)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".jsonl") }.compactMap { f -> Conversation? in
            let path = (dir as NSString).appendingPathComponent(f)
            guard let (when, size) = stat(path), size > 0 else { return nil }
            let h = claudeHead(head(path))
            return Conversation(vendor: "claude", id: String(f.dropLast(6)), path: path, folder: folder,
                                modified: when, bytes: size, title: h.title, firstPrompt: h.prompt)
        }.sorted { $0.modified > $1.modified }
    }

    /// Codex's conversations, newest first; for one folder, or all of them.
    public static func codex(folder: String?, root: String = Transcripts.codexRoot, limit: Int = 400) -> [Conversation] {
        guard let walk = FileManager.default.enumerator(atPath: root) else { return [] }
        var paths: [String] = []
        for case let rel as String in walk where rel.hasSuffix(".jsonl") { paths.append((root as NSString).appendingPathComponent(rel)) }
        // Names begin with the date, so the newest are the last in order.
        return paths.sorted().suffix(limit).reversed().compactMap { path -> Conversation? in
            guard let (when, size) = stat(path), size > 0 else { return nil }
            let h = codexHead(head(path, bytes: 512 * 1024))
            if let want = folder, h.folder != want { return nil }
            guard let id = h.id else { return nil }
            return Conversation(vendor: "codex", id: id, path: path, folder: h.folder, modified: when, bytes: size,
                                title: nil, firstPrompt: h.prompt)
        }
    }

    public static func all(folder: String, claudeRoot: String = Resume.claudeProjectsRoot,
                           codexRoot: String = Transcripts.codexRoot) -> [Conversation] {
        (claude(folder: folder, root: claudeRoot) + codex(folder: folder, root: codexRoot))
            .sorted { $0.modified > $1.modified }
    }

    /// The conversations whose text holds every word of `query`, any case.
    /// An empty query keeps them all. Reads each file whole, so call it off
    /// the main thread.
    public static func search(_ list: [Conversation], query: String) -> [Conversation] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return list }
        return list.filter { c in
            if words.allSatisfy({ c.heading.lowercased().contains($0) }) { return true }
            guard c.bytes < 64 * 1024 * 1024, let d = FileManager.default.contents(atPath: c.path) else { return false }
            let text = String(decoding: d, as: UTF8.self).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    public static func size(_ bytes: Int) -> String {
        bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : "\(max(1, bytes / 1024)) KB"
    }
}
