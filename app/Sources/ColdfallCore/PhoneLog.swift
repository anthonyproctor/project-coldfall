import Foundation

/// What the phone page saw go wrong: its own errors, requests that failed or
/// were slow, stalls and reloads, plus problem reports the person writes. The
/// page keeps a short log on the phone and sends it here, so trouble on the
/// phone can be read on the Mac (`coldfall-cli phone-log`).
///
/// It never holds what a desk said: the page sends only its own messages
/// (an error's text, a route, a status), and what it sends is cleaned here
/// again: kinds from a fixed list, short fields, no control characters, and
/// the inbox secret taken out of anything that looks like a link carrying it.
/// It stays on the Mac, in a log that keeps itself small.
public enum PhoneLog {
    public static var dir = NSString(string: "~/.local/share/coldfall/phone").expandingTildeInPath
    static var logPath: String { (dir as NSString).appendingPathComponent("phone.log") }
    /// The log is cut back to its newer half past this.
    public static var maxLog = 512 * 1024
    /// Screenshots kept from reports; older ones go.
    public static let keepShots = 20
    public static let maxEvents = 120

    /// What the page may say happened. Anything else is dropped.
    public static let kinds: Set<String> = ["load", "error", "rejection", "net", "timeout", "http", "slow",
                                             "stall", "reload", "visible", "hidden", "online", "offline", "report"]

    public struct Entry: Equatable {
        public var at: Date          // when the Mac got it
        public var time: Double      // when the phone saw it (ms since 1970)
        public var kind: String
        public var message: String
        public var desk: String
        public var tab: String
        public var page: String
        public var device: String
        public var shot: String      // a report's screenshot, on the Mac
    }

    /// One field, made safe to keep: no control characters, no secret, short.
    public static func clean(_ s: String, max: Int) -> String {
        var out = String(String.UnicodeScalarView(s.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        if let re = try? NSRegularExpression(pattern: #"([?&#]t=)[^&#\s"']*"#) {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1…")
        }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.count > max ? String(out.prefix(max)) + "…" : out
    }

    /// The entries in what the page sent. Bad ones are left out, never guessed at.
    public static func entries(_ body: Data, now: Date = Date()) -> [Entry] {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [] }
        let device = clean([o["device"] as? String, o["size"] as? String].compactMap { $0 }.joined(separator: " · "), max: 240)
        var out: [Entry] = []
        for case let e as [String: Any] in (o["events"] as? [Any] ?? []).prefix(maxEvents) {
            guard let kind = e["kind"] as? String, kinds.contains(kind), kind != "report" else { continue }
            out.append(Entry(at: now, time: (e["t"] as? NSNumber)?.doubleValue ?? 0, kind: kind,
                             message: clean(e["msg"] as? String ?? "", max: 500),
                             desk: clean(e["desk"] as? String ?? "", max: 64), tab: clean(e["tab"] as? String ?? "", max: 12),
                             page: clean(e["page"] as? String ?? "", max: 24), device: "", shot: ""))
        }
        if let note = o["note"] as? String {
            out.append(Entry(at: now, time: now.timeIntervalSince1970 * 1000, kind: "report",
                             message: clean(note, max: 2000), desk: clean(o["desk"] as? String ?? "", max: 64),
                             tab: clean(o["tab"] as? String ?? "", max: 12), page: clean(o["page"] as? String ?? "", max: 24),
                             device: device, shot: ""))
        } else if !out.isEmpty {
            out[out.count - 1].device = device
        }
        return out
    }

    static func line(_ e: Entry) -> String {
        var o: [String: Any] = ["at": Int(e.at.timeIntervalSince1970), "t": e.time, "kind": e.kind, "msg": e.message]
        if !e.desk.isEmpty { o["desk"] = e.desk }
        if !e.tab.isEmpty { o["tab"] = e.tab }
        if !e.page.isEmpty { o["page"] = e.page }
        if !e.device.isEmpty { o["device"] = e.device }
        if !e.shot.isEmpty { o["shot"] = e.shot }
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Keep what the page sent, and a report's screenshot (a picture only,
    /// under a name made here). Returns how many entries were kept.
    @discardableResult
    public static func record(_ body: Data, shot: Data? = nil, now: Date = Date()) -> Int {
        var list = entries(body, now: now)
        guard !list.isEmpty else { return 0 }
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return 0 }
        }
        if let shot, let i = list.lastIndex(where: { $0.kind == "report" }), let path = saveShot(shot, now: now) {
            list[i].shot = path
        }
        let text = list.map(line).filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
        if !fm.fileExists(atPath: logPath) { fm.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let h = FileHandle(forWritingAtPath: logPath) else { return 0 }
        h.seekToEndOfFile(); h.write(Data(text.utf8)); h.closeFile()
        trim()
        return list.count
    }

    static func saveShot(_ data: Data, now: Date) -> String? {
        guard data.count <= Inbox.maxPhoto, let kind = Inbox.photoKind(data) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let fm = FileManager.default
        var path = (dir as NSString).appendingPathComponent("report-\(f.string(from: now)).\(kind)")
        var n = 2
        while fm.fileExists(atPath: path) { path = (dir as NSString).appendingPathComponent("report-\(f.string(from: now))-\(n).\(kind)"); n += 1 }
        guard fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        let shots = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("report-") }.sorted()
        for old in shots.dropLast(keepShots) { try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(old)) }
        return path
    }

    /// Past `maxLog`, keep the newer half, from a line's start.
    static func trim() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.size] as? Int, size > maxLog,
              let d = FileManager.default.contents(atPath: logPath) else { return }
        var tail = d.suffix(maxLog / 2)
        if let nl = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[tail.index(after: nl)...] }
        try? Data(tail).write(to: URL(fileURLWithPath: logPath), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPath)
    }

    /// What has been kept, oldest first.
    public static func read() -> [Entry] {
        guard let d = FileManager.default.contents(atPath: logPath) else { return [] }
        return String(decoding: d, as: UTF8.self).split(separator: "\n").compactMap { l in
            guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], let k = o["kind"] as? String else { return nil }
            return Entry(at: Date(timeIntervalSince1970: (o["at"] as? NSNumber)?.doubleValue ?? 0), time: (o["t"] as? NSNumber)?.doubleValue ?? 0,
                         kind: k, message: o["msg"] as? String ?? "", desk: o["desk"] as? String ?? "", tab: o["tab"] as? String ?? "",
                         page: o["page"] as? String ?? "", device: o["device"] as? String ?? "", shot: o["shot"] as? String ?? "")
        }
    }

    /// One entry as a line for a person: the phone's own time.
    public static func describe(_ e: Entry) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss"
        let when = f.string(from: e.time > 0 ? Date(timeIntervalSince1970: e.time / 1000) : e.at)
        var s = "\(when)  \(e.kind.padding(toLength: 9, withPad: " ", startingAt: 0)) \(e.message)"
        let place = [e.desk, e.tab].filter { !$0.isEmpty }.joined(separator: "/")
        if !place.isEmpty { s += "  [\(place)]" }
        if e.kind == "report" {
            if !e.page.isEmpty { s += "  page \(e.page)" }
            if !e.device.isEmpty { s += "\n                          on \(e.device)" }
            if !e.shot.isEmpty { s += "\n                          screenshot \(e.shot)" }
        }
        return s
    }
}
