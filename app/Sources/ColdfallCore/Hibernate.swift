import Foundation

/// Sleeping idle desks.
///
/// An agent that has finished, been read, and then sat untouched is still
/// holding half a gigabyte and a tree of helper processes. If Coldfall can
/// bring its conversation back, it can be put to sleep: its processes end,
/// its row shows a moon, and opening it resumes where it was.
///
/// Every condition is a reason a person might still need it running as it
/// is; any one of them keeps the desk awake.
public enum Hibernate {
    public struct Facts: Equatable {
        public var runtime: String
        /// Coldfall starts this desk in a way that picks its conversation up.
        public var resumes: Bool
        public var running: Bool
        /// On screen, peeked at, or beside another desk.
        public var visible: Bool
        public var activity: DeskActivity
        public var lastOutput: Date?
        public var lastKey: Date?
        /// More than the agent's own pane: a shell someone opened beside it.
        public var panes: Int
        /// A message half typed into it.
        public var draft: Bool
        public init(runtime: String, resumes: Bool, running: Bool, visible: Bool, activity: DeskActivity,
                    lastOutput: Date?, lastKey: Date?, panes: Int, draft: Bool) {
            self.runtime = runtime; self.resumes = resumes; self.running = running; self.visible = visible
            self.activity = activity; self.lastOutput = lastOutput; self.lastKey = lastKey; self.panes = panes; self.draft = draft
        }
    }

    /// `after` seconds of nothing at all; 0 or less means sleeping is off.
    public static func shouldSleep(_ f: Facts, now: Date, after: TimeInterval) -> Bool {
        guard after > 0, f.running, f.resumes, f.runtime != "shell" else { return false }
        // Done and seen: not working, not asking, no answer you haven't read.
        guard !f.visible, f.activity == .quiet, f.panes == 1, !f.draft else { return false }
        // It must have said something once (a desk still starting is not
        // idle), and nothing may have gone in or come out since.
        guard let out = f.lastOutput else { return false }
        let last = max(out, f.lastKey ?? .distantPast)
        return now.timeIntervalSince(last) >= after
    }

    /// The choices in Settings, in minutes; 0 is off.
    public static let choices = [0, 15, 30, 60, 120, 240]
    public static func label(_ minutes: Int) -> String {
        switch minutes {
        case ..<1: return "Never"
        case 60: return "After 1 hour"
        case let m where m % 60 == 0: return "After \(m / 60) hours"
        default: return "After \(minutes) minutes"
        }
    }
}
