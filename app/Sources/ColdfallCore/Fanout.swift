// Fan-out — the mailbox, applied to several slices at once.
//
// The mailbox does one question and one answer. That is the right shape for a
// second opinion and the wrong one for a review: "look at these twelve files"
// becomes a single invocation pointed at a whole tree, which is both expensive
// and imprecise. The first live use of the bridge did exactly that and sent
// the responder grepping through an entire workspace to answer one question.
//
// A fan-out asks the same question of N narrow slices in parallel, then asks
// one more time with every answer as context. That last step is the point: N
// opinions the human has to reconcile is worse than no opinions.
//
// WHAT THIS DELIBERATELY IS NOT
//
// Not a graph, not a DAG, not a config format. Every orchestration framework
// starts as "agents hand work to each other" and ends as a worse programming
// language that nobody can debug. The mailbox's whole virtue is that it is a
// FILE — readable, diffable, keepable — so a fan-out is a DIRECTORY of those
// files and nothing more. If you cannot `cat` the state of a run, this is the
// wrong design.
//
// Concretely, a run looks like:
//
//     mail/fanout-2026-09-20-143022-review/
//       00-ask.md          the question, and what it was sliced across
//       01-src-api.md      one thread per slice, same format as any thread
//       02-src-web.md
//       ...
//       merge.md           every answer as context, one reply
//
// WHY THIS LIVES HERE AND NOT IN A FRAMEWORK
//
// N slices cost N times the tokens, and Coldfall is the only thing in the loop
// that knows what the vendor has left. A fan-out that quietly spends the rest
// of your week is a bug, so this one prices the run first, refuses when the
// budget says no, and says which vendor has room instead.

import Foundation

// MARK: - what a run costs

/// The budget verdict for a proposed fan-out, decided before anything runs.
public struct FanoutBudget {
    public enum Verdict {
        /// Go ahead.
        case ok
        /// Runnable, but it will take a visible bite. Worth showing the number.
        case tight(String)
        /// Refuse. The reason is written for a human, not a log.
        case refuse(String)
        /// Another vendor has materially more room. Advice, never automatic —
        /// moving work to a different company is a decision, not an optimisation.
        case suggestOther(vendor: String, reason: String)
    }
    public var verdict: Verdict
    public var slices: Int
    public var vendor: String

    public var allowsRun: Bool {
        switch verdict {
        case .ok, .tight, .suggestOther: return true
        case .refuse: return false
        }
    }

    /// One line for the interface. Nil when there is nothing worth saying —
    /// the router is quiet unless it has something actionable, same as the meter.
    public var advice: String? {
        switch verdict {
        case .ok: return nil
        case .tight(let s), .refuse(let s): return s
        case .suggestOther(let v, let r): return "\(r) Try \(v) instead."
        }
    }
}

public enum Fanout {

    /// Price a run before it happens.
    ///
    /// The arithmetic is deliberately crude, because the input is crude: a
    /// slice costs roughly what one mailbox question costs, and the only
    /// number available is a percentage of a weekly window. Crude and shown
    /// beats precise and hidden — the point is that nobody discovers the cost
    /// after the fact.
    public static func budget(vendor: String, slices: Int,
                              limits: [VendorLimits]) -> FanoutBudget {
        let mine = limits.first { $0.vendor == vendor && $0.isUsable }

        // No quota data is not a reason to block. Antigravity and Copilot keep no
        // quota locally, and refusing to fan out on those would punish the
        // user for their vendor's choice.
        guard let used = mine?.liveWeekPct else {
            return FanoutBudget(verdict: .ok, slices: slices, vendor: vendor)
        }
        let left = max(0, 100 - used)

        // A merge pass is one more invocation on top of the slices.
        let calls = Double(slices + 1)

        // Anchor: a week's window absorbs roughly 200 mailbox-sized questions.
        // Wrong in both directions for different people, which is why the
        // estimate is always shown rather than silently enforced.
        let costPct = calls * 0.5

        if costPct > left {
            let reset = mine?.weekResetsAt.map { " Resets \(shortDate($0))." } ?? ""
            return FanoutBudget(
                verdict: .refuse("\(slices) slices would cost about \(pct(costPct)) of "
                    + "\(vendor)'s week and only \(pct(left)) is left.\(reset) "
                    + "Narrow the slices, or send it to a vendor with room."),
                slices: slices, vendor: vendor)
        }

        // Somebody else is materially emptier. Say so; never act on it.
        if let other = limits.first(where: {
            $0.vendor != vendor && $0.isUsable
                && ($0.liveWeekPct ?? 100) + 25 < used
        }) {
            return FanoutBudget(
                verdict: .suggestOther(
                    vendor: other.vendor,
                    reason: "\(vendor) is \(pct(used)) through its week and "
                        + "\(other.vendor) is only \(pct(other.liveWeekPct ?? 0))."),
                slices: slices, vendor: vendor)
        }

        if costPct > left / 3 {
            return FanoutBudget(
                verdict: .tight("About \(pct(costPct)) of \(vendor)'s remaining "
                    + "\(pct(left)) for \(slices) slices."),
                slices: slices, vendor: vendor)
        }
        return FanoutBudget(verdict: .ok, slices: slices, vendor: vendor)
    }

    /// How long one slice may run before it is killed. Generous, because a
    /// large directory genuinely takes minutes, but finite — an unbounded slice
    /// hangs the whole run and reports nothing.
    public static var sliceTimeout: TimeInterval = 600

    static func pct(_ d: Double) -> String { String(format: "%.0f%%", d) }
    static func shortDate(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE h:mm a"
        return f.string(from: Date(timeIntervalSince1970: t)).lowercased()
    }
}

// MARK: - a run

/// One slice of a fan-out: a label and the directory the responder sees.
///
/// The directory is the same privacy boundary the mailbox has. Slicing makes it
/// TIGHTER, which is the security argument for doing this at all: twelve
/// responders each seeing one subdirectory read less than one responder seeing
/// the whole tree.
public struct Slice {
    public let label: String
    public let cwd: String
    public init(label: String, cwd: String) {
        self.label = label
        self.cwd = cwd
    }
}

/// A live run, so it can actually be stopped.
///
/// The sheet had a Cancel button that closed the window and nothing else. The
/// processes carried on in the background, invisible, spending tokens, with no
/// way left to reach them — which is worse than having no button, because the
/// button says the work stopped.
public final class FanoutCancel {
    private let lock = NSLock()
    private var procs: [Process] = []
    private(set) var cancelled = false

    public init() {}

    func add(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        // Cancelled between launch and registration: kill it immediately rather
        // than leaving an orphan nothing is tracking.
        if cancelled { p.terminate(); return }
        procs.append(p)
    }

    /// Kill everything this run started. Safe to call twice.
    public func cancel() {
        lock.lock()
        cancelled = true
        let live = procs
        procs.removeAll()
        lock.unlock()
        for p in live where p.isRunning { p.terminate() }
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

public struct FanoutResult {
    public let label: String
    public let reply: String
    public let path: String
    public let failed: Bool
}

extension Mailbox {

    /// Where one run's threads live. A directory named for when it ran, so two
    /// runs of the same question never overwrite each other.
    public func fanoutDir(topic: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let safe = topic.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            .prefix(32)
        return (dir as NSString).appendingPathComponent("fanout-\(f.string(from: Date()))-\(safe)")
    }

    /// Ask `rt` the same question of every slice in parallel, then once more
    /// with all the answers as context.
    ///
    /// `onProgress` fires on the main queue as each slice lands, because a
    /// fan-out takes minutes and a progress-free wait is indistinguishable from
    /// a hang — the same reason a starting desk paints a line before its CLI
    /// has booted.
    public func fanout(from: String,
                       to rt: Bridge.Runtime,
                       question: String,
                       slices: [Slice],
                       topic: String,
                       onProgress: @escaping (Int, Int, String) -> Void = { _, _, _ in },
                       onMerge: @escaping () -> Void = {},
                       completion: @escaping (Result<(results: [FanoutResult], merged: String, dir: String), BridgeError>) -> Void) -> FanoutCancel {

        let cancel = FanoutCancel()
        guard !slices.isEmpty else {
            completion(.failure(BridgeError(message: "nothing to fan out across")))
            return cancel
        }
        guard DeskConfig.which(rt.bin) != nil else {
            completion(.failure(BridgeError(message: "\(rt.bin) is not on PATH")))
            return cancel
        }

        let runDir = fanoutDir(topic: topic)
        try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)

        // The question, written down before anything runs. A run that dies
        // halfway still leaves a readable record of what was asked.
        let askPath = (runDir as NSString).appendingPathComponent("00-ask.md")
        let header = "# \(topic)\n\n**Asked of \(rt.name), across \(slices.count) slices.**\n\n"
            + question + "\n\n## Slices\n\n"
            + slices.map { "- `\($0.label)` — \($0.cwd)" }.joined(separator: "\n") + "\n"
        try? header.write(toFile: askPath, atomically: true, encoding: .utf8)

        let group = DispatchGroup()
        let lock = NSLock()
        var results: [FanoutResult] = []
        var done = 0

        for (i, slice) in slices.enumerated() {
            group.enter()
            let path = (runDir as NSString)
                .appendingPathComponent(String(format: "%02d-%@.md", i + 1, slice.label))

            // The frame has to say READ THE FILES, not just name the directory.
            // A headless agent handed a question and a path can answer from the
            // question alone and produce something fluent with nothing behind
            // it — which is the worst failure available here, because it reads
            // exactly like a review. Naming the files up front also means the
            // human's message can be the question and nothing else.
            let listing = (try? FileManager.default
                .contentsOfDirectory(atPath: slice.cwd).sorted().prefix(40)
                .joined(separator: ", ")) ?? ""

            let framed = """
            Your working directory is `\(slice.cwd)`. Read the files in it before \
            you answer. Everything below refers to what is in that directory, and \
            nowhere else.

            \(listing.isEmpty ? "" : "It contains: \(listing)\n")
            ## The question

            \(question)

            ## How to answer

            You are one of \(slices.count) readers, each looking at a different \
            directory of the same project: \(slices.map(\.label).joined(separator: ", ")). \
            Your slice is `\(slice.label)`. The answers get reconciled afterwards.

            - Answer for YOUR SLICE ONLY. Do not speculate about the others — say \
            "outside my slice" and move on.
            - Ground every point in a file you actually opened. Cite it as \
            `file:line`. A claim with no file behind it is worse than no claim.
            - If the slice raises nothing worth reporting, say so in one line \
            rather than finding something to say.
            """

            runOne(rt: rt, prompt: framed, cwd: slice.cwd, thread: path,
                   heading: "\(rt.name) · \(slice.label)", ask: question, from: from,
                   register: { cancel.add($0) }) { reply, failed in
                lock.lock()
                results.append(FanoutResult(label: slice.label, reply: reply,
                                            path: path, failed: failed))
                done += 1
                let n = done
                lock.unlock()
                DispatchQueue.main.async { onProgress(n, slices.count, slice.label) }
                group.leave()
            }
        }

        group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
            let ordered = slices.compactMap { s in results.first { $0.label == s.label } }
            let good = ordered.filter { !$0.failed }

            // Cancelled: do not spend one more invocation merging answers
            // nobody is waiting for.
            if cancel.isCancelled {
                DispatchQueue.main.async {
                    completion(.failure(BridgeError(
                        message: "cancelled. Whatever finished is in \(runDir)")))
                }
                return
            }

            guard !good.isEmpty else {
                DispatchQueue.main.async {
                    completion(.failure(BridgeError(
                        message: "every slice failed. The threads are in \(runDir)")))
                }
                return
            }

            // The merge. N opinions a human has to reconcile is worse than
            // none, so this step is not optional and not a summary — it is the
            // deliverable, and the slice threads are its working.
            let mergePath = (runDir as NSString).appendingPathComponent("merge.md")
            let body = good.map { "### \($0.label)\n\n\($0.reply)" }.joined(separator: "\n\n")
            let failedNote = ordered.count > good.count
                ? "\n\n\(ordered.count - good.count) slice(s) failed and are missing below.\n"
                : ""
            let mergePrompt = """
            You asked the same question of \(ordered.count) slices of one codebase and \
            got the answers below.\(failedNote)

            ## The question

            \(question)

            ## The answers

            \(body)

            ## What to do now

            Reconcile them into ONE answer. Specifically:

            - Lead with what matters most across the whole thing, not slice by slice.
            - Where two slices found the SAME problem, say so and name both — a fault \
            that repeats is a different and worse finding than one that does not.
            - Where they contradict each other, say which is right and why, or say \
            plainly that it cannot be settled from here.
            - Drop anything that reads as filler. A short answer is a fine answer.
            """

            try? ("# Merge\n\nReconciling \(good.count) of \(ordered.count) slices.\n")
                .write(toFile: mergePath, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { onMerge() }

            // The merge reads nothing but the answers it was handed, so it runs
            // in the mailbox directory rather than anywhere near the source.
            self.runOne(rt: rt, prompt: mergePrompt, cwd: self.dir, thread: mergePath,
                        heading: "\(rt.name) · merge", ask: question, from: from,
                        register: { cancel.add($0) }) { merged, failed in
                DispatchQueue.main.async {
                    if failed {
                        completion(.failure(BridgeError(
                            message: "the slices ran but the merge failed. They are in \(runDir)")))
                    } else {
                        completion(.success((ordered, merged, runDir)))
                    }
                }
            }
        }
        return cancel
    }

    /// One headless invocation, appended to its own thread. Shares the
    /// mailbox's rules: append never replace, read-only where the vendor
    /// enforces it, and the cwd is the privacy boundary.
    private func runOne(rt: Bridge.Runtime, prompt: String, cwd: String, thread: String,
                        heading: String, ask: String, from: String,
                        timeout: TimeInterval = Fanout.sliceTimeout,
                        register: ((Process) -> Void)? = nil,
                        done: @escaping (String, Bool) -> Void) {
        guard let bin = DeskConfig.which(rt.bin) else { done("\(rt.bin) is not on PATH", true); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let finalFile = rt.hasFinalMessageFlag
                ? NSTemporaryDirectory() + "coldfall-fan-\(UUID().uuidString).txt" : nil
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = rt.argv(prompt, finalFile)
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            var env = ProcessInfo.processInfo.environment
            env["CLAUDECODE"] = ""; env["CLAUDE_CODE_ENTRYPOINT"] = ""
            env.merge(rt.env) { $1 }
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch {
                self.append("could not start \(rt.bin): \(error)", who: heading, to: thread)
                done("could not start \(rt.bin): \(error)", true); return
            }
            register?(p)

            // Both pipes drained at once (a deadlock otherwise: it hung a live
            // run for sixteen minutes), with an upper bound, because a slice
            // with no ceiling can hang the whole run unreported.
            let (d, e, timedOut) = Subprocess.drain(p, out: out, err: err, timeout: timeout)
            if timedOut {
                let mins = Int(timeout / 60)
                let note = "gave up after \(mins) minutes. The process was killed; "
                    + "nothing was written."
                self.append(note, who: heading, to: thread)
                done(note, true)
                return
            }

            var reply = ""
            if let f = finalFile, let only = try? String(contentsOfFile: f, encoding: .utf8),
               !only.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reply = only
                try? FileManager.default.removeItem(atPath: f)
            } else {
                reply = String(data: d, encoding: .utf8) ?? ""
            }
            var failed = false
            if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reply = String(data: e, encoding: .utf8) ?? "(no output)"
                failed = true
            }
            self.append(reply, who: heading, to: thread)
            done(reply, failed)
        }
    }
}
