import Foundation

/// The pull request for a desk's branch, and its checks, as GitHub's own
/// `gh` reports them.
///
/// Asked for only when you open Changes (or refresh it): Coldfall makes no
/// background calls to GitHub. It runs your `gh`, signed in as you, in the
/// desk's folder, and reads the answer.
public struct PullRequest: Equatable {
    public struct Check: Equatable {
        public enum Outcome: Equatable { case passed, failed, pending, skipped }
        public let name: String
        public let outcome: Outcome
        public let url: String?
        public init(name: String, outcome: Outcome, url: String? = nil) { self.name = name; self.outcome = outcome; self.url = url }
    }
    public let number: Int
    public let title: String
    /// OPEN, MERGED or CLOSED.
    public let state: String
    public let isDraft: Bool
    public let url: String
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or none.
    public let review: String?
    public let checks: [Check]

    public var failed: [Check] { checks.filter { $0.outcome == .failed } }
    public var pending: [Check] { checks.filter { $0.outcome == .pending } }
    public var passed: [Check] { checks.filter { $0.outcome == .passed } }

    /// `gh pr view --json number,title,state,isDraft,url,reviewDecision,statusCheckRollup`.
    public static func parse(_ json: String) -> PullRequest? {
        guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let n = o["number"] as? Int else { return nil }
        let rollup = o["statusCheckRollup"] as? [[String: Any]] ?? []
        let checks = rollup.map { c -> Check in
            // A check run has status and conclusion; a commit status has state.
            let name = (c["name"] as? String) ?? (c["context"] as? String) ?? "check"
            let conclusion = ((c["conclusion"] as? String) ?? "").uppercased()
            let status = ((c["status"] as? String) ?? "").uppercased()
            let state = ((c["state"] as? String) ?? "").uppercased()
            let out: Check.Outcome
            if ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion)
                || ["FAILURE", "ERROR"].contains(state) { out = .failed }
            else if conclusion == "SUCCESS" || state == "SUCCESS" { out = .passed }
            else if ["SKIPPED", "NEUTRAL"].contains(conclusion) { out = .skipped }
            else if !status.isEmpty && status != "COMPLETED" || state == "PENDING" || state == "EXPECTED" { out = .pending }
            else { out = conclusion.isEmpty && state.isEmpty ? .pending : .skipped }
            return Check(name: name, outcome: out, url: (c["detailsUrl"] as? String) ?? (c["targetUrl"] as? String))
        }
        let review = (o["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return PullRequest(number: n, title: (o["title"] as? String) ?? "", state: ((o["state"] as? String) ?? "OPEN").uppercased(),
                           isDraft: (o["isDraft"] as? Bool) ?? false, url: (o["url"] as? String) ?? "", review: review, checks: checks)
    }

    /// One line for the top of Changes: "PR #12 · 2 checks failing".
    public var summary: String {
        var s = "PR #\(number)"
        if state == "MERGED" { return s + " · merged" }
        if state == "CLOSED" { return s + " · closed" }
        if isDraft { s += " · draft" }
        if !failed.isEmpty { s += " · \(failed.count) check\(failed.count == 1 ? "" : "s") failing" }
        else if !pending.isEmpty { s += " · \(pending.count) check\(pending.count == 1 ? "" : "s") running" }
        else if !passed.isEmpty { s += " · all \(passed.count) checks passed" }
        switch review {
        case "APPROVED": s += " · approved"
        case "CHANGES_REQUESTED": s += " · changes requested"
        default: break
        }
        return s
    }

    /// The message that asks the agent to fix what is failing. Nil when
    /// nothing is.
    public var fixChecksMessage: String? {
        guard !failed.isEmpty else { return nil }
        var m = "\(failed.count == 1 ? "A check is" : "\(failed.count) checks are") failing on pull request #\(number) (\(url)):"
        for c in failed { m += "\n- \(c.name)" + (c.url.map { " (\($0))" } ?? "") }
        m += "\n\nLook at why (gh run view --log-failed, or the links), fix the cause in the code, and tell me what you changed. Don't push until I've seen it."
        return m
    }

    /// Ask `gh` about the folder's branch. Nil with no gh, no repository on
    /// GitHub, or no pull request for the branch.
    public static func fetch(folder: String, gh: String? = DeskConfig.which("gh"), timeout: TimeInterval = 15) -> PullRequest? {
        guard let gh else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["pr", "view", "--json", "number,title,state,isDraft,url,reviewDecision,statusCheckRollup"]
        p.currentDirectoryURL = URL(fileURLWithPath: folder)
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let r = Subprocess.drain(p, out: out, err: err, timeout: timeout)
        guard !r.timedOut, p.terminationStatus == 0 else { return nil }
        return parse(String(decoding: r.out, as: UTF8.self))
    }
}
