// Noticing that a question was answered somewhere Coldfall didn't see.
//
// A desk says it needs you on its agent's word (the done hook), and the mark
// comes off when you answer in the desk, when the turn ends, or when the
// agent says it is working again. Claude Code never says that last part. So
// an answer that reached it some other way (from Claude's own phone app, by a
// click, or its auto mode allowing the thing itself) left the desk saying
// "needs you" while it worked, until the turn ended.
//
// Claude's own record of the conversation settles it. The model is only
// asked again once every pending tool has its answer, so a reply from it
// dated after the question means the question is behind it. Reading a file
// on this Mac; nothing is sent.

import Foundation

public enum MovedOn {
    /// A reply this soon after the mark is the one that led to the question.
    public static let margin: TimeInterval = 1

    /// Whether the end of a Claude conversation holds a reply of the model's
    /// own (not a helper agent's) dated after `since`.
    public static func claude(tail: String, since: Date) -> Bool {
        let after = since.addingTimeInterval(margin)
        for line in tail.split(separator: "\n").reversed() {
            guard line.contains("\"assistant\""), let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  o["type"] as? String == "assistant", o["isSidechain"] as? Bool != true,
                  let t = (o["timestamp"] as? String).flatMap(date) else { continue }
            // Newest first: the first reply found decides.
            return t > after
        }
        return false
    }

    /// The same, from the file: only read when it changed after the question.
    public static func claude(path: String, since: Date, bytes: Int = 262_144) -> Bool {
        guard let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
              m > since.addingTimeInterval(margin), let text = tail(of: path, bytes: bytes) else { return false }
        return claude(tail: text, since: since)
    }

    /// The last `bytes` of a file as text. A line cut in half at the front
    /// doesn't parse and is skipped by the reader.
    public static func tail(of path: String, bytes: Int) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        guard let data = try? fh.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Whether to take the mark off: the conversation went on, and the desk's
    /// screen is no longer showing choices. (A helper agent running in the
    /// background can ask while the main conversation carries on; its
    /// question is still on the screen, and still yours to answer.)
    public static func clears(wentOn: Bool, screen: String) -> Bool {
        wentOn && Prompt.parse(screen: screen) == nil
    }
}
