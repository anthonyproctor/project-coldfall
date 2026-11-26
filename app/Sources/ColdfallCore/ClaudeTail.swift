// Reading a Claude transcript a little at a time.
//
// A transcript only grows: Claude appends a line for each message. A desk in
// use changes its file every few seconds, so the usage cache (keyed on size
// and time) never hit for it, and each pass read the whole file again. One
// file reached 659MB in a week; a pass took longer than the gap between
// passes, they piled up, and Coldfall grew to about 100GB before macOS killed
// it. Now each file remembers how far it was read, and a pass reads only the
// lines added since.
//
// Lines are also screened before parsing: only a line holding "usage" (a
// reply, which carries the token counts) or "custom-title" (the desk's name)
// is worth turning into JSON. Tool output, the bulk of a big file, is not.

import Foundation

public enum ClaudeTail {

    /// What reading a file has found so far.
    struct Found {
        var desk: String?
        var seen = Set<String>()        // message ids already counted
        var slices: [String: UsageSlice] = [:]
    }

    private static let tail = LineTail<Found>()

    /// The file's whole contribution to the window starting `since`, reading
    /// only what it gained since the last call. Nil when it can't be read.
    public static func read(_ path: String, since: Date, vendor: String, desk hint: @autoclosure () -> String?) -> [UsageSlice]? {
        tail.read(path, tag: "\(since.timeIntervalSince1970)|\(Pricing.checked)|\(vendor)",
                  fresh: { Found(desk: hint()) },
                  line: { take($0, into: &$1, since: since, vendor: vendor) })
            .map { Array($0.slices.values) }
    }

    private static let usageMark = Data("\"usage\"".utf8)
    private static let titleMark = Data("\"custom-title\"".utf8)

    /// One line: counted if it is a reply in the window not counted before.
    static func take(_ line: Data, into p: inout Found, since: Date, vendor: String) {
        let hasUsage = line.range(of: usageMark) != nil
        guard hasUsage || (p.desk == nil && line.range(of: titleMark) != nil),
              let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if p.desk == nil, o["type"] as? String == "custom-title" {
            p.desk = o["customTitle"] as? String
        }
        guard hasUsage, let msg = o["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any] else { return }
        // A reply in several parts is written once per part, same id and usage.
        if let id = msg["id"] as? String {
            if p.seen.contains(id) { return }
            p.seen.insert(id)
        }
        guard let ts = o["timestamp"] as? String, let when = Usage.iso(ts), when >= since else { return }
        let i = u["input_tokens"] as? Int ?? 0
        let cw = u["cache_creation_input_tokens"] as? Int ?? 0
        let cr = u["cache_read_input_tokens"] as? Int ?? 0
        let out = u["output_tokens"] as? Int ?? 0
        let model = msg["model"] as? String ?? ""
        let (w5, w1) = Pricing.writeSplit(u)
        let usd = Pricing.cost(model: model, fresh: i, read: cr, write: cw,
                               write5m: w5, write1h: w1, output: out)
        Usage.collect(&p.slices, vendor: vendor, desk: p.desk,
                      tokens: i + cw + cr + out, usd: usd, when: when)
    }

    /// Forget files that are gone (called with the files a pass saw).
    public static func keep(_ live: Set<String>) { tail.keep(live) }

    /// Forget everything (tests).
    public static func reset() { tail.reset() }
}
