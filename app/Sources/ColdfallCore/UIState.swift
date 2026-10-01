import Foundation

/// Small bits of window state that should survive a restart.
public struct UIState: Codable {
    public var collapsed: [String] = []
    public var treeOnTop: Bool = false
    public var seenWelcome: Bool = false
    /// Layout toggles: cmd-B, cmd-opt-B, cmd-J.
    public var railHidden: Bool = false
    public var readerHidden: Bool = false
    public var readerPoppedOut: Bool = false
    public var meterHidden: Bool = false
    /// "Keep Active Groups on Top" in the rail.
    public var liveRail: Bool = false
    /// Agents whose "add a desk" offer was waved off with Not now.
    public var dismissedOffers: [String] = []
    /// Whether reopening a big, idle conversation asks about starting fresh
    /// at all. Settings has the switch; a desk can also opt out on its own.
    public var offerFreshStart: Bool = true
    /// Desks that were wrapped up when last stopped: name -> when. Cleared
    /// when the desk starts again, whichever way it starts.
    public var wrappedUp: [String: Double] = [:]
    /// Each agent's version when Coldfall last looked, to notice updates.
    public var agentVersions: [String: String] = [:]
    /// Updates not yet dismissed: runtime -> [from, to].
    public var agentUpdates: [String: [String]] = [:]
    /// The desk on screen when the app last ran, to open again at launch.
    public var lastDesk: String?
    /// Picking a desk that isn't running shows its Start button first,
    /// rather than starting it on the click. Settings, Desks turns it off.
    public var confirmStart: Bool = true
    /// "Move Ready Desks to Top": a desk that is waiting on you rises to the
    /// top of the rail, under any pinned desks, until you have looked at it.
    public var readyOnTop: Bool = true

    public init() {}

    /// Every field is optional on the way in.
    ///
    /// Swift's synthesised decoder THROWS on a missing key rather than using
    /// the default, and load() falls back to a fresh UIState on any failure.
    /// So adding a field used to silently wipe everyone's saved state the
    /// first time they ran the new build: the welcome screen came back and the
    /// tree moved. Decoding each key if present means an older file loads
    /// cleanly and any field added later is safe.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        collapsed       = try c.decodeIfPresent([String].self, forKey: .collapsed) ?? []
        treeOnTop       = try c.decodeIfPresent(Bool.self, forKey: .treeOnTop) ?? false
        seenWelcome     = try c.decodeIfPresent(Bool.self, forKey: .seenWelcome) ?? false
        railHidden      = try c.decodeIfPresent(Bool.self, forKey: .railHidden) ?? false
        readerHidden    = try c.decodeIfPresent(Bool.self, forKey: .readerHidden) ?? false
        readerPoppedOut = try c.decodeIfPresent(Bool.self, forKey: .readerPoppedOut) ?? false
        meterHidden     = try c.decodeIfPresent(Bool.self, forKey: .meterHidden) ?? false
        liveRail        = try c.decodeIfPresent(Bool.self, forKey: .liveRail) ?? false
        dismissedOffers = try c.decodeIfPresent([String].self, forKey: .dismissedOffers) ?? []
        offerFreshStart = try c.decodeIfPresent(Bool.self, forKey: .offerFreshStart) ?? true
        wrappedUp = try c.decodeIfPresent([String: Double].self, forKey: .wrappedUp) ?? [:]
        agentVersions = try c.decodeIfPresent([String: String].self, forKey: .agentVersions) ?? [:]
        agentUpdates = try c.decodeIfPresent([String: [String]].self, forKey: .agentUpdates) ?? [:]
        lastDesk = try c.decodeIfPresent(String.self, forKey: .lastDesk)
        confirmStart = try c.decodeIfPresent(Bool.self, forKey: .confirmStart) ?? true
        readyOnTop = try c.decodeIfPresent(Bool.self, forKey: .readyOnTop) ?? true
    }

    public static var path: String { NSString(string: "~/.config/coldfall/ui.json").expandingTildeInPath }

    public static func load() -> UIState {
        guard let d = FileManager.default.contents(atPath: path),
              let s = try? JSONDecoder().decode(UIState.self, from: d) else { return UIState() }
        return s
    }
    public static func markSeenWelcome() {
        var s = UIState.load(); s.seenWelcome = true; s.save()
    }

    public func save() {
        let dir = (UIState.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: URL(fileURLWithPath: UIState.path))
    }
}

