import Foundation

/// A desk asking for you in its own words: `coldfall-cli notify --from <desk> "…"`.
///
/// An agent can't click a macOS permission prompt, Chrome's Allow dialog or a
/// sign-in page, and shouldn't. What it can do is say so and keep going, instead
/// of waiting on a screen nobody is looking at. The notice shows in Needs You and
/// on the phone page, with a banner on the Mac; a phone that gets notifications
/// hears "a desk needs you" in Coldfall's fixed words, never the notice itself
/// (it can show on a locked screen and passes through someone else's service).
///
/// One notice per desk: a newer one from the same desk replaces it. It stays
/// until you dismiss it, the desk clears it (`notify --clear`), or a day passes.
public enum Notice {
    public struct Item: Codable, Equatable {
        public var desk: String
        public var text: String
        public var time: Double
        public init(desk: String, text: String, time: Double) { self.desk = desk; self.text = text; self.time = time }
    }

    public static var path: String { (RemoteOpen.root as NSString).appendingPathComponent("notices.json") }
    public static let maxText = 400
    public static let ttl: TimeInterval = 24 * 3600

    /// What a notice may say: one paragraph of plain text. Terminal escapes and
    /// other control characters are dropped, runs of space become one, and it is
    /// cut at `maxText`. Empty means there was nothing to say.
    public static func clean(_ s: String) -> String {
        var out = ""
        // Inside an escape: after ESC, a CSI (ESC [ … final) or an OSC (ESC ] … BEL or ESC \\).
        enum Esc { case none, start, csi, osc, oscEsc }
        var esc = Esc.none
        for u in s.unicodeScalars {
            switch esc {
            case .start: esc = u == "[" ? .csi : u == "]" ? .osc : .none; continue
            case .csi: if (0x40...0x7E).contains(u.value) { esc = .none }; continue
            case .osc: if u == "\u{07}" { esc = .none } else if u == "\u{1B}" { esc = .oscEsc }; continue
            case .oscEsc: esc = .none; continue
            case .none: break
            }
            if u == "\u{1B}" { esc = .start; continue }
            if u == "\n" || u == "\t" || u == "\r" { out.append(" "); continue }
            if u.properties.generalCategory == .control || u.properties.generalCategory == .format { continue }
            out.unicodeScalars.append(u)
        }
        let words = out.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        guard words.count > maxText else { return words }
        return String(words.prefix(maxText - 1)) + "…"
    }

    // Read again only when the file changes: the app asks every tick.
    nonisolated(unsafe) private static var cache: (stamp: Date?, size: Int, items: [Item])?
    private static let lock = NSLock()

    /// The notices still standing, oldest first.
    public static func all(now: Date = Date()) -> [Item] {
        lock.lock(); defer { lock.unlock() }
        return live(load(), now: now)
    }

    static func live(_ items: [Item], now: Date) -> [Item] {
        items.filter { now.timeIntervalSince1970 - $0.time < ttl }.sorted { $0.time < $1.time }
    }

    private static func load() -> [Item] {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        let stamp = a?[.modificationDate] as? Date, size = (a?[.size] as? Int) ?? -1
        if let c = cache, c.stamp == stamp, c.size == size { return c.items }
        // Small by construction (one per desk); refuse anything that isn't.
        var items: [Item] = []
        if size > 0, size < 1 << 20, let d = FileManager.default.contents(atPath: path) {
            items = (try? JSONDecoder().decode([Item].self, from: d)) ?? []
        }
        cache = (stamp, size, items)
        return items
    }

    private static func save(_ items: [Item]) {
        Secret.folder(RemoteOpen.root)
        guard let d = try? JSONEncoder().encode(items) else { return }
        _ = Secret.write(d, to: path)
        cache = nil
    }

    /// Put up a desk's notice, replacing its last one. Nil when the text is empty.
    @discardableResult
    public static func add(desk: String, text: String, now: Date = Date()) -> Item? {
        let t = clean(text)
        guard !t.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        let item = Item(desk: desk, text: t, time: now.timeIntervalSince1970)
        save(live(load(), now: now).filter { $0.desk != desk } + [item])
        return item
    }

    /// Take a desk's notice down. False when it had none.
    @discardableResult
    public static func clear(desk: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let items = live(load(), now: now)
        guard items.contains(where: { $0.desk == desk }) else { return false }
        save(items.filter { $0.desk != desk })
        return true
    }

}
