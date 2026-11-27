import Foundation

/// Watching a desk's pull request, so a failed check or a review that asks
/// for changes comes to you instead of waiting for you to open Changes.
///
/// Off until turned on (Settings, General): it is the one thing besides
/// updates that asks a service on a timer. It runs your own `gh`, signed in
/// as you, once per folder every five minutes, only for desks that are
/// running, and never while the last pass is still going. Nothing else is
/// sent: `gh pr view` in the desk's folder, as you would type it.
///
/// A card stays in Needs You while there is something to do. Dismissing it
/// hides that state of the pull request, not the pull request: a new
/// commit that fails, or a review asking again, brings it back.
public enum PRWatch {
    public static let every: TimeInterval = 300

    public struct Alert: Equatable {
        public let desk: String
        public let pr: PullRequest
        /// What a dismissal remembers: the pull request, its commit, and what is wrong.
        public let key: String
        public let headline: String
        /// The title and the failing checks, one per line.
        public let detail: String
    }

    /// Nil when there is nothing to tell you about: closed, merged, a draft
    /// with nothing failing, all passing, or still running.
    public static func key(_ p: PullRequest) -> String? {
        guard p.state == "OPEN" else { return nil }
        var what = p.failed.map(\.name).sorted()
        if p.review == "CHANGES_REQUESTED" { what.append("review: changes requested") }
        guard !what.isEmpty else { return nil }
        return "#\(p.number)@\(p.head ?? "?"):" + what.joined(separator: ",")
    }

    public static func alert(desk: String, pr p: PullRequest) -> Alert? {
        guard let k = key(p) else { return nil }
        let n = p.failed.count
        let checks = n == 0 ? nil : (n == 1 ? "a check is failing" : "\(n) checks are failing")
        let review = p.review == "CHANGES_REQUESTED" ? "a review asks for changes" : nil
        let what = [checks, review].compactMap { $0 }.joined(separator: " and ")
        let headline = "PR #\(p.number): " + what
        var detail = p.title
        for c in p.failed.prefix(6) { detail += "\n• " + c.name }
        if n > 6 { detail += "\n• and \(n - 6) more" }
        return Alert(desk: desk, pr: p, key: k, headline: headline, detail: detail)
    }

    /// The folders to ask about, once each, named for the first running desk
    /// there in list order. A shell desk counts: its folder's branch is the
    /// same branch.
    public static func targets(_ desks: [(name: String, folder: String)], running: Set<String>) -> [(desk: String, folder: String)] {
        var seen = Set<String>()
        var out: [(desk: String, folder: String)] = []
        for d in desks where running.contains(d.name) {
            let f = d.folder
            guard !f.isEmpty else { continue }
            let key = (f as NSString).standardizingPath
            if seen.insert(key).inserted { out.append((d.name, f)) }
        }
        return out
    }

    /// The alerts still to show, given what was dismissed.
    public static func shown(_ alerts: [Alert], dismissed: [String: String]) -> [Alert] {
        alerts.filter { dismissed[$0.desk] != $0.key }
    }

    /// Dismissals worth keeping: only those for a state that is still there,
    /// so the list never grows and a state that comes back later is news.
    public static func prune(_ dismissed: [String: String], alerts: [Alert]) -> [String: String] {
        let live = Dictionary(alerts.map { ($0.desk, $0.key) }, uniquingKeysWith: { a, _ in a })
        return dismissed.filter { live[$0.key] == $0.value }
    }
}
