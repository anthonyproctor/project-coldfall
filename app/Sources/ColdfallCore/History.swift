import Foundation

/// Where you have been, to go back and forward through desks the way a
/// browser does through pages.
public struct VisitHistory: Equatable {
    public private(set) var trail: [String] = []
    /// Index of the desk you are on, in `trail`.
    public private(set) var at = -1
    public static let limit = 50
    public init() {}

    /// You went to a desk by choosing it. Anything "forward" is dropped,
    /// as in a browser; going to the desk you are on changes nothing.
    public mutating func visit(_ name: String) {
        if at >= 0, trail[at] == name { return }
        trail = Array(trail.prefix(at + 1)) + [name]
        if trail.count > VisitHistory.limit { trail.removeFirst(trail.count - VisitHistory.limit) }
        at = trail.count - 1
    }

    public var canGoBack: Bool { at > 0 }
    public var canGoForward: Bool { at >= 0 && at < trail.count - 1 }

    /// The desk one step back (or forward), skipping any that no longer
    /// exist. Nil at the end of the trail.
    public mutating func step(_ delta: Int, exists: (String) -> Bool = { _ in true }) -> String? {
        var i = at + delta
        while trail.indices.contains(i) {
            if exists(trail[i]), trail[i] != (trail.indices.contains(at) ? trail[at] : nil) || delta == 0 { at = i; return trail[i] }
            i += delta > 0 ? 1 : -1
        }
        return nil
    }

    public mutating func rename(_ old: String, to new: String) {
        trail = trail.map { $0 == old ? new : $0 }
    }
}

/// The desks you stopped, most recent last, for "Reopen Stopped Desk".
public struct ClosedDesks: Equatable {
    public private(set) var names: [String] = []
    public init() {}
    public mutating func closed(_ name: String) {
        names.removeAll { $0 == name }
        names.append(name)
        if names.count > 20 { names.removeFirst() }
    }
    /// The one stopped most recently that still exists and isn't running.
    public mutating func reopen(exists: (String) -> Bool, running: (String) -> Bool) -> String? {
        while let n = names.popLast() { if exists(n), !running(n) { return n } }
        return nil
    }
}

/// A plain terminal notification (OSC 9, 99 or 777) from any program,
/// read as the two things a desk can say: it needs you, or it is done.
///
/// Agents that don't speak Coldfall's hook or OSC 7501 often still send
/// one of these when they want attention. The words decide which.
public enum TerminalNotice {
    /// The message out of the payload. OSC 9 is the message itself; 777 is
    /// "notify;title;body"; 99 (kitty) is "metadata;body".
    public static func message(code: Int, payload: String) -> String? {
        var text = payload
        switch code {
        case 777:
            let parts = payload.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.first == "notify" else { return nil }
            text = parts.dropFirst().filter { !$0.isEmpty }.joined(separator: ": ")
        case 99:
            guard let semi = payload.firstIndex(of: ";") else { return nil }
            text = String(payload[payload.index(after: semi)...])
        case 9:
            // "9;4;..." is a progress report (ConEmu), not a message.
            if payload.hasPrefix("4;") { return nil }
        default: return nil
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Needs you, when it reads like a question or a request to act;
    /// otherwise a finished turn.
    public static func event(_ message: String) -> DoneSignal.Event {
        let m = message.lowercased()
        let asks = ["permission", "approve", "approval", "waiting for", "needs your", "need your", "input", "confirm",
                    "question", "allow", "blocked", "action required", "?"]
        return asks.contains { m.contains($0) } ? .notify : .stop
    }
}
