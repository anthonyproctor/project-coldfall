import Foundation

/// Waiting on an agent run with a deadline: what Agent Mail and Fan out
/// share.
public enum Subprocess {
    /// Read both pipes of a started process to the end, at once, with a
    /// ceiling. Reading one then the other deadlocks the day a child fills
    /// the 64KB stderr buffer: it blocks on write, we block on read, both sit
    /// at 0% CPU looking like a slow model.
    ///
    /// Past `timeout` the process and everything it started are ended (asked
    /// to stop, then killed): a child that ignores SIGTERM, or a grandchild
    /// holding the pipe open, would otherwise outlive the "gave up".
    public static func drain(_ p: Process, out: Pipe, err: Pipe, timeout: TimeInterval) -> (out: Data, err: Data, timedOut: Bool) {
        var d = Data(), e = Data()
        let pipes = DispatchGroup()
        let sink = DispatchQueue(label: "coldfall.subprocess.drain", attributes: .concurrent)
        pipes.enter()
        sink.async { d = out.fileHandleForReading.readDataToEndOfFile(); pipes.leave() }
        pipes.enter()
        sink.async { e = err.fileHandleForReading.readDataToEndOfFile(); pipes.leave() }
        if pipes.wait(timeout: .now() + timeout) == .timedOut {
            let tree = ProcessTree.descendants(of: p.processIdentifier, in: ProcessTree.read())
            ProcessTree.end(tree.isEmpty ? [p.processIdentifier] : tree)
            _ = pipes.wait(timeout: .now() + 8)
            return (d, e, true)
        }
        p.waitUntilExit()
        return (d, e, false)
    }
}
