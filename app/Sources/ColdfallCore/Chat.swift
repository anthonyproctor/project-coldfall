import Foundation

/// A desk's conversation as messages, for the phone: what you said, what the
/// agent answered, and a line for each tool it used. Read from the agent's
/// own transcript (Claude's or Codex's JSONL), never from its screen.
///
/// Transcripts run to hundreds of megabytes, and the phone asks every couple
/// of seconds, so nothing here reads one whole: the first look reads the last
/// few megabytes, each look after that only what was added (as LineTail
/// does), and scrolling back reads one window further back on request.
public enum Chat {
    public struct Message: Equatable {
        /// Where its line starts in the file: stable, and how "earlier" pages.
        public let id: Int
        /// "user", "assistant" or "tool".
        public let role: String
        public let text: String
        public let time: Double?
        public init(id: Int, role: String, text: String, time: Double?) {
            self.id = id; self.role = role; self.text = text; self.time = time
        }
    }

    /// How much of a long message travels: the start of it, which is what a
    /// phone shows, with a note that there is more on the Mac.
    public static let maxText = 24_000

    static func clip(_ s: String) -> String {
        s.count <= maxText ? s : String(s.prefix(maxText)) + "\n\n… (longer on the Mac)"
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func time(_ s: Any?) -> Double? {
        guard let s = s as? String else { return nil }
        return (iso.date(from: s) ?? ISO8601DateFormatter().date(from: s))?.timeIntervalSince1970
    }

    /// Text the agent's harness adds to your turn, not words you typed.
    static func isHarness(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix("<") || t.hasPrefix("Caveat:") || t.hasPrefix("[Request interrupted")
    }

    /// One line a tool use is shown as: its name and what it was pointed at.
    static func tool(_ name: String, _ input: [String: Any]) -> String {
        var what = ""
        for k in ["description", "command", "file_path", "path", "pattern", "url", "query", "prompt", "skill"] {
            if let v = input[k] as? String, !v.isEmpty { what = v; break }
            if let v = input[k] as? [String], !v.isEmpty { what = v.joined(separator: " "); break }
        }
        let one = what.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let short = one.count > 140 ? String(one.prefix(139)) + "…" : one
        return short.isEmpty ? name : name + " · " + short
    }

    /// The messages in one line of a Claude transcript.
    public static func claude(_ line: Data, at offset: Int) -> [Message] {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = o["type"] as? String, type == "user" || type == "assistant",
              o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true,
              let m = o["message"] as? [String: Any] else { return [] }
        let t = time(o["timestamp"])
        var out: [Message] = []
        func add(_ role: String, _ text: String) { out.append(Message(id: offset + out.count, role: role, text: clip(text), time: t)) }
        if let s = m["content"] as? String {
            if type == "user" ? !isHarness(s) : !s.isEmpty { add(type, s) }
            return out
        }
        for c in m["content"] as? [[String: Any]] ?? [] {
            switch c["type"] as? String {
            case "text":
                if let s = c["text"] as? String, type == "user" ? !isHarness(s) : !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(type, s) }
            case "image" where type == "user":
                add("user", "[image]")
            case "tool_use" where type == "assistant":
                add("tool", tool(c["name"] as? String ?? "tool", c["input"] as? [String: Any] ?? [:]))
            default: break      // thinking, tool results, anything new
            }
        }
        return out
    }

    /// The messages in one line of a Codex session.
    public static func codex(_ line: Data, at offset: Int) -> [Message] {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              o["type"] as? String == "response_item", let p = o["payload"] as? [String: Any] else { return [] }
        let t = time(o["timestamp"])
        var out: [Message] = []
        func add(_ role: String, _ text: String) { out.append(Message(id: offset + out.count, role: role, text: clip(text), time: t)) }
        switch p["type"] as? String {
        case "message":
            let role = p["role"] as? String
            guard role == "user" || role == "assistant" else { return [] }
            for c in p["content"] as? [[String: Any]] ?? [] {
                guard let s = c["text"] as? String else { continue }
                if role == "user" ? !isHarness(s) : !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(role!, s) }
            }
        case "function_call", "custom_tool_call", "local_shell_call":
            var input: [String: Any] = [:]
            if let a = p["arguments"] as? String, let j = (try? JSONSerialization.jsonObject(with: Data(a.utf8))) as? [String: Any] { input = j }
            if let a = p["input"] as? String { input["command"] = a }
            add("tool", tool(p["name"] as? String ?? "shell", input))
        default: break
        }
        return out
    }

    public static func messages(_ line: Data, at offset: Int, vendor: String) -> [Message] {
        if skips(line, vendor: vendor) { return [] }
        return vendor == "codex" ? codex(line, at: offset) : claude(line, at: offset)
    }

    /// Lines that can't hold a message, told by their first bytes without
    /// parsing them: tool results (where screenshots and file dumps make up
    /// most of a transcript's size) and bookkeeping.
    public static func skips(_ line: Data, vendor: String) -> Bool {
        let head = line.prefix(1500)
        func has(_ s: String) -> Bool { head.range(of: Data(s.utf8)) != nil }
        if vendor == "codex" {
            return has("\"type\":\"event_msg\"") || has("_output\"") || has("\"type\":\"reasoning\"") || has("\"type\":\"token")
        }
        // The record's own "type" comes after its message, so far in for a
        // long one; the message's "role" comes first.
        return has("\"type\":\"tool_result\"") || !(has("\"role\":\"user\"") || has("\"role\":\"assistant\""))
    }

    /// Whole lines in `data`, which starts at file offset `base`, parsed. A
    /// first line that began before `base` is skipped when `partial`.
    static func parse(_ data: Data, base: Int, vendor: String, partial: Bool) -> (messages: [Message], used: Int, from: Int) {
        var out: [Message] = []
        var at = data.startIndex
        var from = base
        if partial {
            guard let nl = data.firstIndex(of: 0x0A) else { return ([], 0, base) }
            at = data.index(after: nl)
            from = base + (at - data.startIndex)
        }
        var used = at - data.startIndex
        while at < data.endIndex, let nl = data[at...].firstIndex(of: 0x0A) {
            if nl > at { out += messages(data[at..<nl], at: base + (at - data.startIndex), vendor: vendor) }
            at = data.index(after: nl)
            used = at - data.startIndex
        }
        return (out, used, from)
    }

    /// Enough to fill a screen: some of what was said (tool lines don't
    /// count), including something you said.
    static func fills(_ m: [Message], _ enough: Int) -> Bool {
        m.filter { $0.role != "tool" }.count >= enough && m.contains { $0.role == "user" }
    }

    /// What a page has: the messages, a mark for "nothing new", and whether
    /// there is more before the first.
    public struct View: Equatable {
        public var messages: [Message]
        public var rev: String
        /// Whether anything comes before; ask with `before` for it.
        public var more: Bool
        public var before: Int
        public init(messages: [Message], rev: String, more: Bool, before: Int) {
            self.messages = messages; self.rev = rev; self.more = more; self.before = before
        }
    }

    /// Follows transcripts as they grow, keeping the last messages of each.
    public final class Tail {
        struct Entry { var head: Data; var start: Int; var end: Int; var messages: [Message]; var vendor: String }
        private var entries: [String: Entry] = [:]
        private let lock = NSLock()
        let window: Int, keep: Int
        public init(window: Int = 3 << 20, keep: Int = 300) { self.window = window; self.keep = keep }

        /// Whether a read would be quick: the transcript is followed already
        /// and has grown by less than a window. Otherwise the first look (or
        /// one after a big jump) reads back through megabytes, which belongs
        /// off the main thread.
        public func isQuick(_ path: String, vendor: String) -> Bool {
            lock.lock(); let e = entries[path]; lock.unlock()
            guard let q = e, q.vendor == vendor, let a = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (a[.size] as? NSNumber)?.intValue else { return false }
            return size >= q.end && size - q.end <= window
        }

        /// The furthest back a first look goes for enough messages to fill a screen.
        public var reach = 48 << 20
        public var enough = 20

        public func read(_ path: String, vendor: String) -> View? {
            guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? fh.close() }
            let head = (try? fh.read(upToCount: 256)) ?? Data()
            let size = Int((try? fh.seekToEnd()) ?? 0)
            lock.lock(); var e = entries[path]; lock.unlock()
            // Rewritten, cut short, another reader's, or grown by more than
            // a window since: start again from the end.
            if let q = e, q.vendor != vendor || size < q.end || head.prefix(q.head.count) != q.head || size - q.end > window { e = nil }
            if e == nil {
                // Back a window at a time until there's a screenful of messages.
                var span = window
                var got: (messages: [Message], used: Int, from: Int) = ([], 0, 0)
                var start = 0
                while true {
                    start = max(0, size - span)
                    try? fh.seek(toOffset: UInt64(start))
                    let data = (try? fh.read(upToCount: size - start)) ?? Data()
                    got = Chat.parse(data, base: start, vendor: vendor, partial: start > 0)
                    if Chat.fills(got.messages, enough) || start == 0 || span >= reach { break }
                    span *= 2
                }
                e = Entry(head: head, start: got.from, end: start + got.used, messages: got.messages, vendor: vendor)
            } else if var q = e, size > q.end {
                try? fh.seek(toOffset: UInt64(q.end))
                let data = (try? fh.read(upToCount: size - q.end)) ?? Data()
                let p = Chat.parse(data, base: q.end, vendor: vendor, partial: false)
                q.messages += p.messages
                q.end += p.used
                e = q
            }
            guard var q = e else { return nil }
            if q.messages.count > keep {
                q.messages.removeFirst(q.messages.count - keep)
                q.start = q.messages.first?.id ?? q.start
            }
            lock.lock(); entries[path] = q; lock.unlock()
            return View(messages: q.messages, rev: "\(q.start)-\(q.end)", more: q.start > 0, before: q.start)
        }

        /// Messages before `before` (an id), one window's worth, on request.
        public func earlier(_ path: String, vendor: String, before: Int) -> View? {
            guard before > 0, let fh = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? fh.close() }
            var span = window, start = 0
            var p: (messages: [Message], used: Int, from: Int) = ([], 0, 0)
            while true {
                start = max(0, before - span)
                try? fh.seek(toOffset: UInt64(start))
                let data = (try? fh.read(upToCount: before - start)) ?? Data()
                p = Chat.parse(data, base: start, vendor: vendor, partial: start > 0)
                if Chat.fills(p.messages, enough) || start == 0 || span >= reach { break }
                span *= 2
            }
            let all = p.messages.filter { $0.id < before }
            let list = Array(all.suffix(keep))
            // A window may hold no messages at all (one tool's huge output):
            // then the page asks again from where this one began.
            let next = list.count < all.count ? (list.first?.id ?? p.from) : p.from
            return View(messages: list, rev: "", more: next > 0, before: next)
        }

        /// Forget transcripts no longer looked at.
        public func keep(_ live: Set<String>) {
            lock.lock(); defer { lock.unlock() }
            for k in entries.keys where !live.contains(k) { entries.removeValue(forKey: k) }
        }
    }
}
