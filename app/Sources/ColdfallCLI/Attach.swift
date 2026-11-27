import Foundation
import ColdfallCore

// `coldfall-cli attach <desk>`: a desk kept running by Coldfall, in this
// terminal. Any terminal app on the Mac, or an SSH session from another
// machine (Tailscale SSH from a phone), sees the desk and can type into it
// while Coldfall's own window keeps showing it too. Whichever typed last
// decides the size the agent draws for. Ctrl-\ leaves; the desk carries on.
//
// It joins the desk's holder (see Holder), so it only reaches desks that are
// held, and only from this account: the holder refuses anyone else.

/// Exit status: 0 left or the agent ended cleanly, 1 couldn't attach or the
/// holder went, 2 usage.
func attachDesk(_ desk: String) -> Never {
    let err = FileHandle.standardError
    func say(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
        say("attach needs a terminal: run it in Terminal, Ghostty, iTerm or an SSH session, not from a script or an agent.")
        exit(2)
    }
    if let me = ProcessInfo.processInfo.environment["CLAUDE_DESK"], me == desk {
        say("This terminal is \(desk) already. Attaching it to itself would echo forever.")
        exit(2)
    }
    let sock = Holder.socketPath(desk: desk)
    guard let first = Holder.connect(sock) else {
        let known = DeskConfig.load().contains { $0.name == desk }
        say(known
            ? "\(desk) isn't being kept running, so there's nothing to attach to. Only desks Coldfall keeps running "
              + "(Settings, Desks, \"Keep desks running when Coldfall quits\") can be reached from another terminal, "
              + "and only once they've been started that way."
            : "There's no desk called \(desk). `coldfall-cli holders` lists the desks you can attach to.")
        exit(1)
    }

    var ws = winsize()
    _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &ws)
    var saved = termios()
    tcgetattr(STDIN_FILENO, &saved)

    func send(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR || errno == EAGAIN { usleep(1000); continue }; return false }
            off += n
        }
        return true
    }
    func finish(_ code: Int32, _ note: String) -> Never {
        var s = saved; tcsetattr(STDIN_FILENO, TCSANOW, &s)
        for f in [STDIN_FILENO, STDOUT_FILENO] { _ = fcntl(f, F_SETFL, fcntl(f, F_GETFL) & ~O_NONBLOCK) }
        _ = send(STDOUT_FILENO, Array(Holder.terminalReset.utf8))
        say("\r\n" + note)
        exit(code)
    }

    // Join first. A holder from before joining existed closes the
    // connection at once; then watch instead, which those holders know.
    var conn = first
    var watching = false
    _ = send(conn, Holder.Wire.encode(.join, Holder.Wire.join(cols: ws.ws_col, rows: ws.ws_row)))
    var dec = Holder.Decoder()
    var pending: [UInt8] = []
    var p = pollfd(fd: conn, events: Int16(POLLIN), revents: 0)
    if poll(&p, 1, 1500) > 0 {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(conn, &buf, buf.count)
        if n > 0 { pending = Array(buf[0..<n]) }
        else {
            close(conn)
            guard let again = Holder.connect(sock) else { say("\(desk) stopped while attaching."); exit(1) }
            conn = again
            watching = true
            _ = send(conn, Holder.Wire.encode(.tap, Holder.Wire.tap()))
        }
    }

    say(watching
        ? "Watching \(desk). It was started before Coldfall could share a desk, so you can watch but not type; "
          + "that works once it's restarted. Ctrl-C or Ctrl-\\ leaves."
        : "Attached to \(desk). Ctrl-\\ leaves; the desk keeps running.")

    var raw = saved; cfmakeraw(&raw); tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    var winch: [Int32] = [-1, -1]
    pipe(&winch)
    attachWinchFD = winch[1]
    signal(SIGWINCH) { _ in var b: UInt8 = 1; _ = write(attachWinchFD, &b, 1) }
    signal(SIGPIPE, SIG_IGN)
    for f in [conn, STDIN_FILENO, STDOUT_FILENO] { _ = fcntl(f, F_SETFL, fcntl(f, F_GETFL) | O_NONBLOCK) }

    var toHolder: [UInt8] = [], toScreen: [UInt8] = []
    let ceiling = 4 << 20
    func flush(_ fd: Int32, _ q: inout [UInt8]) -> Bool {
        while !q.isEmpty {
            let n = q.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { q.removeFirst(n); continue }
            if n < 0, errno == EAGAIN || errno == EINTR { return true }
            return false
        }
        return true
    }
    func readNow(_ fd: Int32) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        if n > 0 { return Array(buf[0..<n]) }
        if n < 0, errno == EAGAIN || errno == EINTR { return [] }
        return nil
    }
    func take(_ bytes: [UInt8]) {
        for (kind, payload) in dec.push(bytes) {
            switch kind {
            case .output: toScreen += payload
            case .exit:
                _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) & ~O_NONBLOCK)
                _ = send(STDOUT_FILENO, toScreen)
                let code = Holder.Wire.readStatus(payload) ?? 0
                finish(code == 0 ? 0 : 1, "\(desk)'s agent exited" + (code == 0 ? "." : " with status \(code)."))
            default: break      // a tap's echo of keys and its "live from here" mark
            }
        }
        if dec.broken { finish(1, "\(desk)'s holder spoke a version this coldfall-cli can't read.") }
    }
    take(pending)

    while true {
        var fds = [pollfd(fd: STDIN_FILENO, events: toHolder.count < ceiling ? Int16(POLLIN) : 0, revents: 0),
                   pollfd(fd: conn, events: (toScreen.count < ceiling ? Int16(POLLIN) : 0) | (toHolder.isEmpty ? 0 : Int16(POLLOUT)), revents: 0),
                   pollfd(fd: winch[0], events: Int16(POLLIN), revents: 0),
                   pollfd(fd: STDOUT_FILENO, events: toScreen.isEmpty ? 0 : Int16(POLLOUT), revents: 0)]
        if poll(&fds, nfds_t(fds.count), -1) < 0 { if errno == EINTR { continue }; finish(1, "Lost the terminal.") }
        if fds[2].revents & Int16(POLLIN) != 0 {
            _ = readNow(winch[0])
            var w = winsize()
            if !watching, ioctl(STDIN_FILENO, TIOCGWINSZ, &w) == 0 {
                toHolder += Holder.Wire.encode(.resize, Holder.Wire.size(cols: w.ws_col, rows: w.ws_row))
            }
        }
        if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            // The terminal closed (an SSH session dropped): leave, desk untouched.
            guard let b = readNow(STDIN_FILENO) else { finish(0, "Left \(desk); it's still running.") }
            let (keys, leave) = Holder.detach(b)
            if watching {
                if leave || keys.contains(3) { finish(0, "Stopped watching \(desk); it's still running.") }
            } else if !keys.isEmpty {
                toHolder += Holder.Wire.encode(.input, keys)
            }
            if leave {
                _ = fcntl(conn, F_SETFL, fcntl(conn, F_GETFL) & ~O_NONBLOCK)
                _ = send(conn, toHolder)
                finish(0, "Left \(desk); it's still running.")
            }
        }
        if fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            guard let b = readNow(conn) else {
                _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) & ~O_NONBLOCK)
                _ = send(STDOUT_FILENO, toScreen)
                finish(1, "\(desk)'s holder stopped.")
            }
            take(b)
        }
        if !flush(conn, &toHolder) { finish(1, "\(desk)'s holder stopped.") }
        if !flush(STDOUT_FILENO, &toScreen) { finish(0, "Left \(desk); it's still running.") }
    }
}

/// Where SIGWINCH says so; a signal handler can't capture.
var attachWinchFD: Int32 = -1
