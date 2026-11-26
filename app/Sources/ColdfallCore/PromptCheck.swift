// Saying when a question couldn't be read, and whether an update is new.
//
// Coldfall reads a desk's choices off its terminal (see Prompt). That works
// until a vendor redraws its prompts, and vendors ship every few days. A
// table of "versions this release was tested with" would be out of date
// within the week, so there isn't one. Coldfall keeps its own record on each
// Mac instead: the agent version each desk was started on, and the version
// it last read a desk's choices from. When it can't read them and the desk is
// on a version it has no record of, it says so, rather than leaving a card
// with no buttons and no reason.
//
// Nothing here leaves the Mac. A version is read by running the vendor's CLI
// with --version: no model call, no tokens.

import Foundation

public enum PromptCheck {

    /// A desk's agent as it was started: which vendor, on which version.
    public struct Stamp: Equatable {
        public let runtime: String
        public let version: String
        public init(runtime: String, version: String) { self.runtime = runtime; self.version = version }
        /// As kept in ui.json: [runtime, version].
        public init?(_ pair: [String]?) {
            guard let pair, pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
            self.init(runtime: pair[0], version: pair[1])
        }
        public var pair: [String] { [runtime, version] }
    }

    /// The CLI whose version says what a desk is running, or nil when that
    /// can't be known from here: a plain shell, a vendor Coldfall has no
    /// entry for, or a desk whose own command runs on another machine.
    public static func bin(for desk: Desk) -> String? {
        guard desk.runtime != "shell", let rt = Bridge.known.first(where: { $0.name == desk.runtime }) else { return nil }
        if let first = desk.command?.split(whereSeparator: { $0 == " " || $0 == "\t" }).first {
            let word = first.split(separator: "/").last.map(String.init) ?? String(first)
            if ["ssh", "mosh", "et", "tailscale"].contains(word) { return nil }
        }
        return rt.bin
    }

    /// Choices were read from a desk on this stamp. The record with that in
    /// it, or nil when it already said so (nothing to save).
    public static func noting(_ read: [String: String], _ stamp: Stamp?) -> [String: String]? {
        guard let stamp, read[stamp.runtime] != stamp.version else { return nil }
        var r = read
        r[stamp.runtime] = stamp.version
        return r
    }

    /// Stamps for desks that are still around. A removed desk's is dropped.
    public static func pruned(_ stamps: [String: [String]], keeping names: Set<String>) -> [String: [String]] {
        stamps.filter { names.contains($0.key) && Stamp($0.value) != nil }
    }

    public static let base = "Its choices couldn't be read from here."
    public static let open = "Open the desk to answer."

    /// What to say under a waiting desk whose choices couldn't be read. A
    /// question with no numbered choices is ordinary (the agent asked
    /// something in words), so this states only what Coldfall knows: whether
    /// it has ever read choices from the version this desk is on.
    public static func unread(_ stamp: Stamp?, read: [String: String]) -> String {
        [base, note(stamp, read: read), open].compactMap { $0 }.joined(separator: " ")
    }

    /// The sentence about the version alone, or nil when there is nothing to
    /// add: the desk's version isn't known, or choices have been read on it.
    public static func note(_ stamp: Stamp?, read: [String: String]) -> String? {
        guard let stamp else { return nil }
        let agent = "\(AgentOffer.shortName(stamp.runtime)) \(stamp.version)"
        guard let last = read[stamp.runtime] else {
            return "Coldfall hasn't read choices from \(agent) on this Mac yet."
        }
        if last == stamp.version { return nil }
        return "Coldfall hasn't read choices from \(agent) yet (it last did on \(last))."
    }

    /// One more sentence for an update's tooltip, when there is a record to
    /// compare with.
    public static func afterUpdate(_ change: AgentVersions.Change, read: [String: String]) -> String? {
        guard let last = read[change.runtime], last != change.to else { return nil }
        return "Coldfall last read a desk's choices on \(last). If it can't read them on \(change.to), Needs You will say so."
    }

    /// For `coldfall-cli versions --read`: each agent's installed version
    /// beside the one choices were last read on.
    public static func rows(installed: [String: String], read: [String: String]) -> [[String: Any]] {
        Set(installed.keys).union(read.keys).sorted().map { rt in
            var o: [String: Any] = ["agent": rt]
            if let v = installed[rt] { o["installed"] = v }
            if let r = read[rt] { o["choicesReadOn"] = r }
            o["checked"] = installed[rt] != nil && installed[rt] == read[rt]
            return o
        }
    }
}
