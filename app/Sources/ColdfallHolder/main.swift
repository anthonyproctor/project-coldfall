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
// Single threaded on purpose: forkpty in a process with other threads running
// is asking for trouble, and a poll loop is all this needs.

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

func readSome(_ fd: Int32, max: Int = 65536) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: max)
    while true {
        let n = read(fd, &buf, max)
        if n > 0 { return Array(buf[0..<n]) }
        if n < 0, errno == EINTR { continue }
        return nil
    }
}

// MARK: - attach

/// SIGWINCH arrives on this pipe, so the poll loop can see it.
var winchPipe: [Int32] = [-1, -1]

func attach() -> Never {
    var fd = Holder.connect(sock)
    if fd == nil {
        Holder.ensureRoot()
        Holder.clearFiles(socket: sock)
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
        if let note { FileHandle.standardError.write(note.data(using: .utf8)!) }
        exit(code)
    }

    pipe(&winchPipe)
    signal(SIGWINCH) { _ in var b: UInt8 = 1; _ = write(winchPipe[1], &b, 1) }
    signal(SIGPIPE, SIG_IGN)

    var dec = Holder.Decoder()
    var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
               pollfd(fd: conn, events: Int16(POLLIN), revents: 0),
               pollfd(fd: winchPipe[0], events: Int16(POLLIN), revents: 0)]
    while true {
        for i in fds.indices { fds[i].revents = 0 }
        if poll(&fds, nfds_t(fds.count), -1) < 0 { if errno == EINTR { continue }; finish(1) }
        if fds[2].revents & Int16(POLLIN) != 0 {
            _ = readSome(winchPipe[0], max: 64)
            var w = winsize()
            if ioctl(STDIN_FILENO, TIOCGWINSZ, &w) == 0 {
                writeAll(conn, Holder.Wire.encode(.resize, Holder.Wire.size(cols: w.ws_col, rows: w.ws_row)))
            }
        }
        if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            // Coldfall's terminal is gone: leave the holder running.
            guard let b = readSome(STDIN_FILENO) else { finish(0) }
            if !writeAll(conn, Holder.Wire.encode(.input, b)) {
                finish(1, "\r\n[this desk's holder stopped]\r\n")
            }
        }
        if fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            guard let b = readSome(conn) else { finish(1, "\r\n[this desk's holder stopped]\r\n") }
            for (kind, payload) in dec.push(b) {
                switch kind {
                case .output: writeAll(STDOUT_FILENO, payload)
                case .exit: finish(Holder.Wire.readStatus(payload) ?? 0)
                default: break
                }
            }
            if dec.broken { finish(1, "\r\n[this desk's holder spoke a version Coldfall can't read]\r\n") }
        }
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
    if Holder.isAlive(sock) { exit(0) }          // someone is already holding it
    Holder.clearFiles(socket: sock)

    // A socket path macOS can't take would be cut short; refuse instead.
    guard Holder.fits(sock) else { exit(1) }

    // The program first, before anything could start a thread.
    var ws = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    var master: Int32 = -1
    var cargs = program.map { strdup($0) } + [nil]
    let child = forkpty(&master, nil, nil, &ws)
    if child == 0 {
        execve(program[0], &cargs, environ)
        _exit(127)
    }
    guard child > 0 else { exit(1) }

    // Listen.
    let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(sock.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in path.enumerated() { raw[i] = b }
        raw[path.count] = 0
    }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(lfd, 4) == 0 else { kill(child, SIGHUP); exit(1) }
    chmod(sock, 0o600)
    try? "\(child)\n".write(toFile: Holder.pidPath(socket: sock), atomically: true, encoding: .utf8)
    try? "\(desk)\n".write(toFile: Holder.namePath(socket: sock), atomically: true, encoding: .utf8)

    var replay = Holder.Replay()
    var attaches = 0

    /// A connection: the attached terminal once it has said hello, or a
    /// passer-by (a liveness check, an end request) until then. Only a hello
    /// takes over the terminal, so checking on a holder never cuts off the
    /// Coldfall attached to it.
    struct Conn { var fd: Int32; var dec = Holder.Decoder(); var attached = false }
    var conns: [Conn] = []

    func status(_ st: Int32) -> Int32 {
        // WIFEXITED / WEXITSTATUS / WTERMSIG, which Swift doesn't import as macros.
        let sig = st & 0x7f
        return sig == 0 ? (st >> 8) & 0xff : 128 + sig
    }
    func done(_ code: Int32) -> Never {
        for c in conns where c.attached { writeAll(c.fd, Holder.Wire.encode(.exit, Holder.Wire.status(code))) }
        for c in conns { close(c.fd) }
        close(lfd)
        Holder.clearFiles(socket: sock)
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

    while true {
        var fds = [pollfd(fd: lfd, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: master, events: Int16(POLLIN), revents: 0)]
        fds += conns.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
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
                    conns.append(Conn(fd: c))
                } else { close(c) }
            }
        }
        if fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            if let b = readSome(master) {
                replay.append(b)
                let frame = Holder.Wire.encode(.output, b)
                for i in conns.indices where conns[i].attached {
                    if !writeAll(conns[i].fd, frame) { close(conns[i].fd); conns[i].fd = -1 }
                }
            } else {
                // The program's side closed: collect it and pass the status on.
                for _ in 0..<20 { if let c = reap() { done(c) }; usleep(50_000) }
                done(0)
            }
        }
        // Connections, matched to the poll entries taken above.
        for (i, pf) in fds.dropFirst(2).enumerated() where i < conns.count && conns[i].fd >= 0 {
            guard pf.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 else { continue }
            guard let b = readSome(conns[i].fd) else { close(conns[i].fd); conns[i].fd = -1; continue }
            for (kind, payload) in conns[i].dec.push(b) {
                switch kind {
                case .hello:
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
                        if !writeAll(conns[i].fd, Holder.Wire.encode(.output, Array(snap[off..<end]))) { close(conns[i].fd); conns[i].fd = -1 }
                        off = end
                    }
                case .input:
                    if conns[i].attached { writeAll(master, payload) }
                case .resize:
                    if conns[i].attached, let s = Holder.Wire.readSize(payload), s.cols > 0, s.rows > 0 { setSize(s.cols, s.rows) }
                case .end:
                    // The same as Coldfall ending a desk it owned: every process
                    // in the tree asked to stop, the rest killed after a grace.
                    let tree = ProcessTree.descendants(of: child, in: ProcessTree.read())
                    ProcessTree.end(tree.isEmpty ? [child] : tree)
                    close(master)
                    Thread.sleep(forTimeInterval: 3.5)
                    done(reap() ?? 129)
                default: break
                }
            }
            if conns[i].dec.broken { close(conns[i].fd); conns[i].fd = -1 }
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
