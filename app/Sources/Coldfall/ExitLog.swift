import AppKit
import ColdfallCore

/// Why Coldfall last stopped, written as it happens.
///
/// An app that is told to stop leaves no crash report: a signal from
/// another process, a quit, a closed window all look the same afterwards,
/// which is "it just disappeared". This keeps one line per exit in
/// ~/.local/share/coldfall/exit.log saying which it was, and for a signal,
/// which process sent it.
enum ExitLog {
    static var path: String { NSString(string: "~/.local/share/coldfall/exit.log").expandingTildeInPath }
    private static var fd: Int32 = -1
    private static var normal = false

    /// One line, now. Safe to call from anywhere but a signal handler.
    static func note(_ what: String) {
        guard fd >= 0 else { return }
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        let line = "\(f.string(from: Date())) pid \(getpid()) v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") \(what)\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }

    /// A stop that Coldfall chose: said once, so the exit hook doesn't also
    /// call it unexplained.
    static func leaving(_ why: String) {
        normal = true
        note(why)
    }

    static func install() {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Kept small: the last few dozen exits are plenty.
        if let a = try? FileManager.default.attributesOfItem(atPath: path), (a[.size] as? Int ?? 0) > 64 * 1024,
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            try? text.split(separator: "\n").suffix(100).joined(separator: "\n").appending("\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        note("started")

        // Signals that would stop the app: note who sent it, then stop the
        // way the signal meant. The handler only records; a timer on the
        // main thread does the writing, where it is safe to.
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            var sa = sigaction()
            sa.sa_flags = SA_SIGINFO
            sa.__sigaction_u.__sa_sigaction = { signo, info, _ in
                ExitLog.gotSignal = signo
                ExitLog.gotSender = info?.pointee.si_pid ?? 0
            }
            sigaction(sig, &sa, nil)
        }
        Timer.inEveryMode(withTimeInterval: 0.2, repeats: true) { _ in
            let sig = ExitLog.gotSignal
            guard sig != 0 else { return }
            ExitLog.gotSignal = 0
            let sender = ExitLog.gotSender
            leaving("stopped by signal \(sig) from pid \(sender): \(command(of: sender))")
            signal(sig, SIG_DFL)
            raise(sig)
        }
        atexit { if !ExitLog.normal { ExitLog.note("exit() with no reason recorded") } }
    }

    // Written by the handler, read by the timer.
    nonisolated(unsafe) static var gotSignal: Int32 = 0
    nonisolated(unsafe) static var gotSender: pid_t = 0

    /// What a process is, and what started it: the sender, and its parent.
    static func command(of pid: pid_t) -> String {
        guard pid > 0 else { return "unknown" }
        func ps(_ fields: String) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-o", fields, "-p\(pid)"]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cmd = ps("command=")
        let parent = ps("ppid=")
        return (cmd.isEmpty ? "already gone" : String(cmd.prefix(300))) + (parent.isEmpty ? "" : " (its parent: pid \(parent))")
    }
}
