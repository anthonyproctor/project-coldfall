// coldfall-holder: keeps a desk's agent running when Coldfall quits.
//
//   coldfall-holder attach <desk> -- <program> [args...]
//       Run inside Coldfall's terminal. Connects to the desk's holder,
//       starting one first if there is none, and relays bytes both ways until
//       the held program exits (exit status passed on) or Coldfall goes (the
//       holder carries on).
//
//   coldfall-holder serve <desk> -- <program> [args...]
//       The holder itself. Started by `attach`, in its own session, so a
//       hangup from Coldfall's terminal never reaches it. Owns the program's
//       pty, keeps its recent output in memory for the next attach, and exits
//       when the program does.
//
// See Holder in ColdfallCore for the why, the wire and the trust boundary.
// Single threaded while it matters: the program is forked before anything
// could start a thread, and the loop is a plain poll. Ending a desk reads the
// process table with Foundation's Process, which may start threads; by then
// nothing else is forked.

import Foundation
import ColdfallCore

let args = CommandLine.arguments
func usage() -> Never {
    FileHandle.standardError.write("usage: coldfall-holder attach|serve <desk> -- <program> [args...]\n".data(using: .utf8)!)
    exit(2)
}
guard args.count >= 5, let dash = args.firstIndex(of: "--"), dash == 3, dash + 1 < args.count else { usage() }
let mode = args[1], desk = args[2]
let program = Array(args[(dash + 1)...])
let sock = Holder.socketPath(desk: desk)

/// Write all of `bytes`, retrying short writes. False if the other end is gone.
@discardableResult
func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 { if errno == EINTR || errno == EAGAIN { usleep(1000); continue }; return false }
        off += n
    }
    return true
}

// MARK: - attach

/// SIGWINCH arrives on this pipe, so the poll loop can see it.
var winchPipe: [Int32] = [-1, -1]

func attach() -> Never {
    var fd = Holder.connect(sock)
    if fd == nil {
        Holder.ensureRoot()
        // The serve sorts out a leftover socket itself, and only its own.
        startHolder()
        for _ in 0..<100 {
            if let f = Holder.connect(sock) { fd = f; break }
            usleep(50_000)
        }
    }
    guard let conn = fd else {
        FileHandle.standardError.write("\r\nColdfall couldn't start this desk's holder.\r\n".data(using: .utf8)!)
        exit(1)
    }

    var ws = winsize()
    _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &ws)
    writeAll(conn, Holder.Wire.encode(.hello, Holder.Wire.hello(cols: ws.ws_col, rows: ws.ws_row)))

    // Raw, so every byte goes to the held program untouched; restored on the
    // way out so whatever runs this terminal next gets it back as it was.
    var saved = termios()
    let isTTY = tcgetattr(STDIN_FILENO, &saved) == 0
    if isTTY { var raw = saved; cfmakeraw(&raw); tcsetattr(STDIN_FILENO, TCSANOW, &raw) }
    func finish(_ code: Int32, _ note: String? = nil) -> Never {
        if isTTY { var s = saved; tcsetattr(STDIN_FILENO, TCSANOW, &s) }
        for f in [STDIN_FILENO, STDOUT_FILENO] { _ = fcntl(f, F_SETFL, fcntl(f, F_GETFL) & ~O_NONBLOCK) }
        if let note { FileHandle.standardError.write(note.data(using: .utf8)!) }
        exit(code)
    }

    pipe(&winchPipe)
    signal(SIGWINCH) { _ in var b: UInt8 = 1; _ = write(winchPipe[1], &b, 1) }
    signal(SIGPIPE, SIG_IGN)

    // Both ways queued and non-blocking, like the holder: Coldfall's terminal
    // and the holder can each be busy without the other waiting on it, and
    // a side that falls far behind is stopped being read until it catches up.
    for f in [conn, STDOUT_FILENO, STDIN_FILENO] { _ = fcntl(f, F_SETFL, fcntl(f, F_GETFL) | O_NONBLOCK) }
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
    /// Nil: the other end is gone. Empty: nothing right now.
    func readNow(_ fd: Int32) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        if n > 0 { return Array(buf[0..<n]) }
        if n < 0, errno == EAGAIN || errno == EINTR { return [] }
        return nil
    }

    var dec = Holder.Decoder()
    while true {
        var fds = [pollfd(fd: STDIN_FILENO, events: toHolder.count < ceiling ? Int16(POLLIN) : 0, revents: 0),
                   pollfd(fd: conn, events: (toScreen.count < ceiling ? Int16(POLLIN) : 0) | (toHolder.isEmpty ? 0 : Int16(POLLOUT)), revents: 0),
                   pollfd(fd: winchPipe[0], events: Int16(POLLIN), revents: 0),
                   pollfd(fd: STDOUT_FILENO, events: toScreen.isEmpty ? 0 : Int16(POLLOUT), revents: 0)]
        if poll(&fds, nfds_t(fds.count), -1) < 0 { if errno == EINTR { continue }; finish(1) }
        if fds[2].revents & Int16(POLLIN) != 0 {
            _ = readNow(winchPipe[0])
            var w = winsize()
            if ioctl(STDIN_FILENO, TIOCGWINSZ, &w) == 0 {
                toHolder += Holder.Wire.encode(.resize, Holder.Wire.size(cols: w.ws_col, rows: w.ws_row))
            }
        }
        if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            // Coldfall's terminal is gone: leave the holder running.
            guard let b = readNow(STDIN_FILENO) else { finish(0) }
            if !b.isEmpty { toHolder += Holder.Wire.encode(.input, b) }
        }
        if fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            guard let b = readNow(conn) else {
                _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) & ~O_NONBLOCK)
                writeAll(STDOUT_FILENO, toScreen)
                finish(1, "\r\n[this desk's holder stopped]\r\n")
            }
            for (kind, payload) in dec.push(b) {
                switch kind {
                case .output: toScreen += payload
                case .exit:
                    _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) & ~O_NONBLOCK)
                    writeAll(STDOUT_FILENO, toScreen)
                    finish(Holder.Wire.readStatus(payload) ?? 0)
                default: break
                }
            }
            if dec.broken { finish(1, "\r\n[this desk's holder spoke a version Coldfall can't read]\r\n") }
        }
        if !flush(conn, &toHolder) { finish(1, "\r\n[this desk's holder stopped]\r\n") }
        if !flush(STDOUT_FILENO, &toScreen) { finish(0) }
    }
}

/// Start `serve` detached: its own session, no terminal, quiet.
func startHolder() {
    let me = Bundle.main.executablePath ?? args[0]
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    for target: Int32 in [0, 1, 2] {
        posix_spawn_file_actions_addopen(&fa, target, "/dev/null", target == 0 ? O_RDONLY : O_WRONLY, 0)
    }
    let argv = [me, "serve", desk, "--"] + program
    var cargs = argv.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    _ = posix_spawn(&pid, me, &fa, &attr, &cargs, environ)
    for p in cargs { free(p) }
    posix_spawn_file_actions_destroy(&fa)
    posix_spawnattr_destroy(&attr)
    // Not waited for: it outlives us. It reparents to launchd when we exit.
}

// MARK: - serve

func serve() -> Never {
    signal(SIGHUP, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
    Holder.ensureRoot()
    // A socket path macOS can't take would be cut short; refuse instead.
    guard Holder.fits(sock) else { exit(1) }

    // One holder per desk, decided by a lock held for the holder's whole
    // life. Two attaches at once (a click and a launch-time reopen) both
    // start a serve; the second can't take the lock and leaves before it
    // touches the socket or starts a second agent. With the lock, a socket
    // nobody answers on really is left over, and safe to replace.
    let lockFD = open(Holder.lockPath(socket: sock), O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
    if Holder.isAlive(sock) { exit(0) }
    let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard lfd >= 0 else { exit(1) }
    _ = fcntl(lfd, F_SETFD, FD_CLOEXEC)          // not into the agent
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(sock.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in path.enumerated() { raw[i] = b }
        raw[path.count] = 0
    }
    func bindIt() -> Int32 {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    if bindIt() != 0 {
        // A socket file nobody answers on is left over from a holder that
        // died. Only then is it ours to remove.
        guard errno == EADDRINUSE, !Holder.isAlive(sock) else { exit(0) }
        unlink(sock)
        guard bindIt() == 0 else { exit(0) }
    }
    guard listen(lfd, 4) == 0 else { unlink(sock); exit(1) }
    chmod(sock, 0o600)
    // Which file is ours, so leaving never removes one that a renamed or
    // newer desk has put at this path since.
    var st = stat()
    let mine: ino_t = stat(sock, &st) == 0 ? st.st_ino : 0
    func ours() -> Bool { var s2 = stat(); return mine != 0 && stat(sock, &s2) == 0 && s2.st_ino == mine }

    // Now the program. No threads have started yet.
    var ws = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    var master: Int32 = -1
    var cargs = program.map { strdup($0) } + [nil]
    let child = forkpty(&master, nil, nil, &ws)
    if child == 0 {
        execve(program[0], &cargs, environ)
        _exit(127)
    }
    guard child > 0 else { if ours() { unlink(sock) }; exit(1) }
    // Neither side may block the other: writes queue, and go when there's room.
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    try? "\(child)\n".write(toFile: Holder.pidPath(socket: sock), atomically: true, encoding: .utf8)
    try? "\(desk)\n".write(toFile: Holder.namePath(socket: sock), atomically: true, encoding: .utf8)
    // The name the agent's hooks report under (its CLAUDE_DESK), kept with
    // the holder so a Coldfall reattaching after a rename still knows it.
    let launch = ProcessInfo.processInfo.environment["CLAUDE_DESK"] ?? desk
    try? "\(launch)\n".write(toFile: Holder.launchPath(socket: sock), atomically: true, encoding: .utf8)

    var replay = Holder.Replay()
    var attaches = 0
    /// Keys waiting for room in the program's input.
    var toProgram: [UInt8] = []

    /// A connection: the attached terminal once it has said hello, or a
    /// passer-by (a liveness check, an end request) until then. Only a hello
    /// takes over the terminal, so checking on a holder never cuts off the
    /// Coldfall attached to it.
    struct Conn { var fd: Int32; var dec = Holder.Decoder(); var attached = false; var tap = false; var out: [UInt8] = [] }
    var conns: [Conn] = []
    /// A terminal this far behind isn't reading; it's let go rather than
    /// holding the program's output in memory.
    let maxBehind = 8 << 20

    func status(_ st: Int32) -> Int32 {
        // WIFEXITED / WEXITSTATUS / WTERMSIG, which Swift doesn't import as macros.
        let sig = st & 0x7f
        return sig == 0 ? (st >> 8) & 0xff : 128 + sig
    }
    /// One line in the holders' log: what happened to this desk, and when.
    func record(_ what: String) {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        let line = "\(f.string(from: Date())) \(desk) (holder pid \(getpid())) \(what)\n"
        let path = (Holder.root as NSString).appendingPathComponent("holders.log")
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    var recordedEnd = false
    func done(_ code: Int32) -> Never {
        if !recordedEnd { recordedEnd = true; record("its program exited with status \(code)") }
        // A last word to the terminal, but never a wait on one that has
        // stopped reading: half a second, then it's dropped.
        let bye = Holder.Wire.encode(.exit, Holder.Wire.status(code))
        let until = Date().addingTimeInterval(0.5)
        for i in conns.indices where conns[i].attached && conns[i].fd >= 0 {
            var q = conns[i].out + bye
            while !q.isEmpty, Date() < until, flush(conns[i].fd, &q) { if !q.isEmpty { usleep(10_000) } }
        }
        for c in conns where c.fd >= 0 { close(c.fd) }
        close(lfd)
        if ours() { Holder.clearFiles(socket: sock) }
        exit(0)
    }
    func reap() -> Int32? {
        var st: Int32 = 0
        return waitpid(child, &st, WNOHANG) == child ? status(st) : nil
    }
    func setSize(_ cols: UInt16, _ rows: UInt16) {
        var w = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &w)
    }
    /// Write what fits without waiting; keep the rest. False if the fd is gone.
    func flush(_ fd: Int32, _ q: inout [UInt8]) -> Bool {
        while !q.isEmpty {
            let n = q.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { q.removeFirst(n); continue }
            if n < 0, errno == EAGAIN || errno == EINTR { return true }
            return false
        }
        return true
    }
    func queue(_ i: Int, _ bytes: [UInt8]) {
        guard conns[i].fd >= 0 else { return }
        conns[i].out += bytes
        if conns[i].out.count > maxBehind || !flush(conns[i].fd, &conns[i].out) { close(conns[i].fd); conns[i].fd = -1 }
    }
    /// End the desk: every process under the shell asked to stop, the shell
    /// hung up, and whatever is left a few seconds later killed. Done here,
    /// in order, so the exit status that goes back is the real one.
    func endDesk() -> Never {
        let tree = ProcessTree.descendants(of: child, in: ProcessTree.read())
        let others = tree.filter { $0 != child }
        let born = Dictionary(uniqueKeysWithValues: tree.map { ($0, ProcessTree.startTime($0)) })
        for p in others { kill(p, SIGTERM) }
        kill(child, SIGHUP)
        close(master)
        var code: Int32?
        for _ in 0..<30 where code == nil { usleep(100_000); code = reap() }
        for p in tree where kill(p, 0) == 0 {
            if let b = born[p] ?? nil, ProcessTree.startTime(p) == b { kill(p, SIGKILL) }
        }
        if code == nil { for _ in 0..<10 where code == nil { usleep(100_000); code = reap() } }
        done(code ?? 129)
    }

    while true {
        var fds = [pollfd(fd: lfd, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: master, events: Int16(POLLIN) | (toProgram.isEmpty ? 0 : Int16(POLLOUT)), revents: 0)]
        // A terminal sending faster than the program takes input waits:
        // its keys stay in the socket rather than being dropped here.
        let full = toProgram.count >= 1 << 20
        fds += conns.map { pollfd(fd: $0.fd, events: (full && $0.attached ? 0 : Int16(POLLIN)) | ($0.out.isEmpty ? 0 : Int16(POLLOUT)), revents: 0) }
        let r = poll(&fds, nfds_t(fds.count), 1000)
        if r < 0 { if errno == EINTR { continue }; break }
        if r == 0 { if let c = reap() { done(c) }; continue }

        if fds[0].revents & Int16(POLLIN) != 0 {
            let c = accept(lfd, nil, nil)
            if c >= 0 {
                var uid: uid_t = 0, gid: gid_t = 0
                if getpeereid(c, &uid, &gid) == 0, uid == getuid(), conns.count < 16 {
                    var one: Int32 = 1
                    setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK)
                    _ = fcntl(c, F_SETFD, FD_CLOEXEC)
                    conns.append(Conn(fd: c))
                } else { close(c) }
            }
        }
        if fds[1].revents & Int16(POLLOUT) != 0, !flush(master, &toProgram) { toProgram = [] }
        if fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(master, &buf, buf.count)
            if n > 0 {
                let b = Array(buf[0..<n])
                replay.append(b)
                let frame = Holder.Wire.encode(.output, b)
                for i in conns.indices where conns[i].attached || conns[i].tap { queue(i, frame) }
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                // The program's side closed: collect it and pass the status on.
                for _ in 0..<20 { if let c = reap() { done(c) }; usleep(50_000) }
                done(0)
            }
        }
        // Connections, matched to the poll entries taken above.
        for (i, pf) in fds.dropFirst(2).enumerated() where i < conns.count && conns[i].fd >= 0 {
            if pf.revents & Int16(POLLOUT) != 0, !flush(conns[i].fd, &conns[i].out) { close(conns[i].fd); conns[i].fd = -1; continue }
            guard pf.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 else { continue }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(conns[i].fd, &buf, buf.count)
            if n < 0, errno == EAGAIN || errno == EINTR { continue }
            guard n > 0 else { close(conns[i].fd); conns[i].fd = -1; continue }
            for (kind, payload) in conns[i].dec.push(Array(buf[0..<n])) {
                switch kind {
                case .hello:
                    // A Coldfall speaking another version of the wire is let go
                    // rather than misread.
                    guard payload.count >= 8,
                          (UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3])) == Holder.protocolVersion
                    else { close(conns[i].fd); conns[i].fd = -1; break }
                    // This one is Coldfall's terminal now; an older one is let go.
                    for j in conns.indices where j != i && conns[j].attached { close(conns[j].fd); conns[j].fd = -1 }
                    conns[i].attached = true
                    attaches += 1
                    if let s = Holder.Wire.readSize(payload), s.cols > 0, s.rows > 0 {
                        // On a reattach, nudge the size so the program redraws
                        // its whole screen for the new terminal.
                        if attaches > 1 { setSize(s.cols, max(1, s.rows - 1)) }
                        setSize(s.cols, s.rows)
                    }
                    let snap = replay.snapshot
                    var off = 0
                    while off < snap.count, conns[i].fd >= 0 {
                        let end = min(snap.count, off + 256 * 1024)
                        queue(i, Holder.Wire.encode(.output, Array(snap[off..<end])))
                        off = end
                    }
                case .input:
                    // Queued, never blocking: a big paste while the program is
                    // busy writing can't wedge the two against each other.
                    if conns[i].attached {
                        toProgram += payload
                        if !flush(master, &toProgram) { toProgram = [] }
                        // Taps see the keys too, so Coldfall can tell typing
                        // from answering without the terminal telling it.
                        let echo = Holder.Wire.encode(.input, payload)
                        for j in conns.indices where conns[j].tap { queue(j, echo) }
                    }
                case .tap:
                    // Watching only: same version or nothing, and never the terminal.
                    guard Holder.Wire.readVersion(payload) == Holder.protocolVersion, !conns[i].attached
                    else { close(conns[i].fd); conns[i].fd = -1; break }
                    // What's remembered so far, then the mark that says
                    // "live from here", then it joins the live copy.
                    let snap = replay.snapshot
                    var off = 0
                    while off < snap.count, conns[i].fd >= 0 {
                        let end = min(snap.count, off + 256 * 1024)
                        queue(i, Holder.Wire.encode(.output, Array(snap[off..<end])))
                        off = end
                    }
                    queue(i, Holder.Wire.encode(.tap, []))
                    if conns[i].fd >= 0 { conns[i].tap = true }
                case .resize:
                    if conns[i].attached, let s = Holder.Wire.readSize(payload), s.cols > 0, s.rows > 0 { setSize(s.cols, s.rows) }
                case .end:
                    // Who asked, for the record: a desk that vanishes
                    // should be explainable afterwards.
                    var peer: pid_t = 0
                    var len = socklen_t(MemoryLayout<pid_t>.size)
                    getsockopt(conns[i].fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &len)
                    record("ended by request from pid \(peer)")
                    endDesk()
                default: break
                }
                if conns[i].fd < 0 { break }
            }
            if conns[i].fd >= 0, conns[i].dec.broken { close(conns[i].fd); conns[i].fd = -1 }
        }
        conns.removeAll { $0.fd < 0 }
    }
    done(1)
}

switch mode {
case "attach": attach()
case "serve": serve()
default: usage()
}
