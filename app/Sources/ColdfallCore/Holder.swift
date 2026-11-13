import Foundation

/// Keeping a desk's agent alive when Coldfall quits.
///
/// Without this, each desk's shell runs in a pty that Coldfall owns. Quitting
/// Coldfall (or updating it, or a crash) closes that pty, the shell gets a
/// hangup, and the agent's conversation is cut off mid-turn.
///
/// With it, a small `coldfall-holder` process owns the agent pane's pty
/// instead. It runs in its own session, outside Coldfall, so nothing reaches
/// it when Coldfall goes. Coldfall's terminal runs `coldfall-holder attach`,
/// which relays bytes both ways over a unix socket, the way dtach does. The
/// terminal, input, exit handling and activity all see exactly the bytes they
/// saw before; only where the pty lives has changed. On the next launch the
/// attach replays what the holder kept and asks the agent to redraw.
///
/// What it does not survive: a restart of the Mac, or the holder being
/// killed. Then the desk starts again the ordinary way, resuming its
/// conversation (see Resume and RestoreOffer).
///
/// Trust: the socket folder is 0700 and the holder refuses a peer with another
/// uid, so only this account can attach, the same boundary as the shell
/// itself. What the holder keeps for replay stays in its memory and is never
/// written to disk.
public enum Holder {

    /// Bumped when the wire changes in a way an older peer can't read.
    public static let protocolVersion: UInt32 = 1

    /// Where the sockets live. Overridable for tests; never the real folder
    /// from a test.
    public static var root: String = ProcessInfo.processInfo.environment["COLDFALL_HOLDER_DIR"]
        ?? NSString(string: "~/.local/share/coldfall/holders").expandingTildeInPath

    /// The longest socket path macOS takes (sun_path is 104 bytes, with a NUL).
    static let maxSocketPath = 103

    /// Socket for a desk's agent pane. The name is kept readable when it
    /// fits; a name that is too long or has odd characters gets a stable
    /// hash instead, so any desk name works.
    public static func socketPath(desk: String, root: String = Holder.root) -> String {
        let safe = String(desk.unicodeScalars.map {
            ($0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0))) ? Character($0) : "_"
        })
        let readable = (root as NSString).appendingPathComponent(safe + ".sock")
        if safe == desk, readable.utf8.count <= maxSocketPath { return readable }
        let hashed = (root as NSString).appendingPathComponent("d-" + stableHash(desk) + ".sock")
        return hashed
    }

    /// Whether a socket path is short enough for macOS. A Coldfall whose
    /// folder is too deep for one (a test, an unusual home) runs desks the
    /// ordinary way instead.
    public static func fits(_ socketPath: String) -> Bool { socketPath.utf8.count <= maxSocketPath }

    /// The file next to a socket holding the held shell's pid, for the memory
    /// meter and for ending it.
    public static func pidPath(socket: String) -> String {
        (socket as NSString).deletingPathExtension + ".pid"
    }

    /// The lock a holder keeps for its whole life (see serve).
    public static func lockPath(socket: String) -> String {
        (socket as NSString).deletingPathExtension + ".lock"
    }

    /// The name the held agent reports under (its CLAUDE_DESK at start).
    public static func launchPath(socket: String) -> String {
        (socket as NSString).deletingPathExtension + ".launch"
    }

    /// What a held desk's agent calls itself, which a rename doesn't change.
    public static func launchName(desk: String, root: String = Holder.root) -> String? {
        (try? String(contentsOfFile: launchPath(socket: socketPath(desk: desk, root: root)), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The desk a socket belongs to, recorded beside it so a hashed name can
    /// be listed.
    public static func namePath(socket: String) -> String {
        (socket as NSString).deletingPathExtension + ".desk"
    }

    /// FNV-1a, 64 bit, hex. Stable across runs, unlike Hasher.
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    /// Make the socket folder, private to this account. A folder that
    /// already exists is tightened to 0700 too.
    @discardableResult
    public static func ensureRoot(_ root: String = Holder.root) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root) {
            guard (try? fm.createDirectory(atPath: root, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])) != nil else { return false }
        }
        return chmod(root, 0o700) == 0
    }

    // MARK: - is one there

    /// Open a connection to a socket path, or nil.
    public static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        guard ok == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Whether something accepts TCP connections on this port on loopback.
    public static func portAnswers(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    /// Whether a holder answers on this socket.
    public static func isAlive(_ path: String) -> Bool {
        guard let fd = connect(path) else { return false }
        close(fd)
        return true
    }

    /// Whether this desk's agent is being held right now.
    public static func isHeld(desk: String, root: String = Holder.root) -> Bool {
        isAlive(socketPath(desk: desk, root: root))
    }

    /// Desks with a live holder, by the name recorded beside each socket.
    /// Dead sockets (a holder that was killed) are cleared on the way.
    public static func held(root: String = Holder.root) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var out: [String] = []
        for f in names.sorted() where f.hasSuffix(".sock") {
            let sock = (root as NSString).appendingPathComponent(f)
            if isAlive(sock) {
                if let d = try? String(contentsOfFile: namePath(socket: sock), encoding: .utf8) {
                    out.append(d.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } else {
                clearFiles(socket: sock)
            }
        }
        return out
    }

    /// Remove a socket and the files beside it.
    public static func clearFiles(socket: String) {
        // Not the lock: removing a lock file another process holds is how
        // two of them end up thinking they have it.
        for p in [socket, pidPath(socket: socket), namePath(socket: socket), launchPath(socket: socket)] {
            try? FileManager.default.removeItem(atPath: p)
        }
    }

    /// The held shell's pid, if the holder recorded one.
    public static func heldPid(desk: String, root: String = Holder.root) -> Int32? {
        let p = pidPath(socket: socketPath(desk: desk, root: root))
        return (try? String(contentsOfFile: p, encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Ask a holder to end its desk: the shell and everything in it get a
    /// hangup, then a kill if they linger, and the holder exits. Returns
    /// whether the request was delivered.
    @discardableResult
    public static func end(desk: String, root: String = Holder.root) -> Bool {
        let sock = socketPath(desk: desk, root: root)
        guard let fd = connect(sock) else { return false }
        defer { close(fd) }
        let frame = Wire.encode(.end, [])
        return frame.withUnsafeBytes { write(fd, $0.baseAddress, frame.count) } == frame.count
    }

    /// Follow a desk rename: the socket and the files beside it move to the
    /// new name's paths. A unix socket keeps working when renamed, so the
    /// held agent never notices.
    /// Returns whether the held desk now answers at the new name.
    @discardableResult
    public static func rename(from old: String, to new: String, root: String = Holder.root) -> Bool {
        let a = socketPath(desk: old, root: root), b = socketPath(desk: new, root: root)
        guard a != b, isAlive(a) else { return false }
        // Something left at the new path that nobody answers on is debris.
        if FileManager.default.fileExists(atPath: b) {
            guard !isAlive(b) else { return false }
            clearFiles(socket: b)
        }
        let fm = FileManager.default
        try? fm.moveItem(atPath: a, toPath: b)
        try? fm.moveItem(atPath: pidPath(socket: a), toPath: pidPath(socket: b))
        try? fm.moveItem(atPath: launchPath(socket: a), toPath: launchPath(socket: b))
        try? fm.removeItem(atPath: namePath(socket: a))
        try? "\(new)\n".write(toFile: namePath(socket: b), atomically: true, encoding: .utf8)
        return isAlive(b)
    }

    /// End every holder under a root. For a full uninstall.
    @discardableResult
    public static func endAll(root: String = Holder.root) -> [String] {
        let desks = held(root: root)
        for d in desks { end(desk: d, root: root) }
        return desks
    }

    // MARK: - the wire

    /// Frames: one type byte, a 4-byte big-endian length, the payload.
    public enum Kind: UInt8 {
        /// Client to holder, first: version (u32), cols (u16), rows (u16).
        case hello = 0x48       // H
        /// Client to holder: keystrokes. Holder to client: output.
        case input = 0x49       // I
        case output = 0x4F      // O
        /// Client to holder: cols (u16), rows (u16).
        case resize = 0x52      // R
        /// Holder to client: the shell exited, with this status (i32).
        case exit = 0x45        // E
        /// Client to holder: end the desk.
        case end = 0x58         // X
        /// Client to holder, first: watch, don't drive (version, u32). The
        /// holder then sends this connection a copy of the program's output
        /// (`output`) and of the keys the attached terminal sent it (`input`).
        /// It starts with what the holder remembers of the output so far,
        /// then an empty `tap` frame back, then everything live: so a
        /// listener that arrives late still learns the desk's last word
        /// about itself, and can tell old from new. A tap never takes the
        /// terminal, never types, and is let go if it stops reading.
        ///
        /// This is how Coldfall knows what a desk is doing when the terminal
        /// on screen (libghostty) owns its own pty and gives no byte hook.
        /// Holders older than the tap don't know this kind and close the
        /// connection: the desk works, its state marks stay dark.
        case tap = 0x54         // T
    }

    public enum Wire {
        public static let maxPayload = 1 << 20

        public static func encode(_ kind: Kind, _ payload: [UInt8]) -> [UInt8] {
            let n = UInt32(payload.count)
            return [kind.rawValue, UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)] + payload
        }

        public static func size(cols: UInt16, rows: UInt16) -> [UInt8] {
            [UInt8(cols >> 8), UInt8(cols & 0xff), UInt8(rows >> 8), UInt8(rows & 0xff)]
        }

        public static func hello(cols: UInt16, rows: UInt16, version: UInt32 = Holder.protocolVersion) -> [UInt8] {
            [UInt8(version >> 24), UInt8((version >> 16) & 0xff), UInt8((version >> 8) & 0xff), UInt8(version & 0xff)]
                + size(cols: cols, rows: rows)
        }

        /// (cols, rows) from a resize payload, or the last four bytes of a hello.
        public static func readSize(_ p: [UInt8]) -> (cols: UInt16, rows: UInt16)? {
            guard p.count >= 4 else { return nil }
            let s = p.suffix(4).map { UInt16($0) }
            return (s[s.startIndex] << 8 | s[s.startIndex + 1], s[s.startIndex + 2] << 8 | s[s.startIndex + 3])
        }

        public static func tap(version: UInt32 = Holder.protocolVersion) -> [UInt8] {
            [UInt8(version >> 24), UInt8((version >> 16) & 0xff), UInt8((version >> 8) & 0xff), UInt8(version & 0xff)]
        }

        /// The version a hello or a tap was sent with.
        public static func readVersion(_ p: [UInt8]) -> UInt32? {
            guard p.count >= 4 else { return nil }
            return UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
        }

        public static func status(_ code: Int32) -> [UInt8] {
            let u = UInt32(bitPattern: code)
            return [UInt8(u >> 24), UInt8((u >> 16) & 0xff), UInt8((u >> 8) & 0xff), UInt8(u & 0xff)]
        }

        public static func readStatus(_ p: [UInt8]) -> Int32? {
            guard p.count == 4 else { return nil }
            return Int32(bitPattern: UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3]))
        }
    }

    /// Reassembles frames from a byte stream that arrives in arbitrary pieces.
    public struct Decoder {
        private var buf: [UInt8] = []
        public private(set) var broken = false
        public init() {}

        /// Add bytes; returns every frame now complete. An unknown type or an
        /// oversized length marks the stream broken and returns nothing more.
        public mutating func push(_ bytes: [UInt8]) -> [(Kind, [UInt8])] {
            guard !broken else { return [] }
            buf += bytes
            var out: [(Kind, [UInt8])] = []
            var at = 0
            while buf.count - at >= 5 {
                guard let k = Kind(rawValue: buf[at]) else { broken = true; break }
                let n = Int(buf[at + 1]) << 24 | Int(buf[at + 2]) << 16 | Int(buf[at + 3]) << 8 | Int(buf[at + 4])
                guard n <= Wire.maxPayload else { broken = true; break }
                guard buf.count - at - 5 >= n else { break }
                out.append((k, Array(buf[(at + 5)..<(at + 5 + n)])))
                at += 5 + n
            }
            buf.removeFirst(at)
            if broken { buf = [] }
            return out
        }
    }

    // MARK: - what is kept for replay

    /// The last `capacity` bytes the shell wrote, for replay on attach. In
    /// memory only.
    public struct Replay {
        public let capacity: Int
        private var bytes: [UInt8] = []
        /// Whether older output has been dropped to make room.
        public private(set) var trimmed = false
        public init(capacity: Int = 2 << 20) { self.capacity = max(1, capacity) }

        public mutating func append(_ more: [UInt8]) {
            bytes += more
            if bytes.count > capacity + capacity / 4 {
                bytes.removeFirst(bytes.count - capacity)
                trimmed = true
            }
        }

        /// What to send an attaching terminal. Once output has been dropped,
        /// the cut can land inside an escape sequence or a UTF-8 character,
        /// which would paint junk at the top; starting after the first line
        /// break avoids both.
        public var snapshot: [UInt8] {
            let tail = bytes.count > capacity ? Array(bytes.suffix(capacity)) : bytes
            guard trimmed || bytes.count > capacity, let nl = tail.firstIndex(of: 0x0A) else { return tail }
            return Array(tail[(nl + 1)...])
        }
    }
}

/// What to say when Coldfall quits with desks that would keep running.
public enum QuitPrompt {
    public struct Text: Equatable {
        public let title: String
        public let body: String
        public let keep: String
        public let end: String
    }

    /// `desks` are the held desks that are running.
    public static func text(desks: [String]) -> Text {
        let n = desks.count
        let title = n == 1 ? "Keep \(desks[0]) running after Coldfall quits?"
                           : "Keep \(n) desks running after Coldfall quits?"
        let who = n == 1 ? "It keeps" : TextStyle.list(desks) + " keep"
        let body = "\(who) working while Coldfall is closed, and Coldfall picks "
            + (n == 1 ? "it" : "them") + " back up when you open it. "
            + "Each agent holds about 400 to 600 MB of memory while it runs.\n\n"
            + "Ending " + (n == 1 ? "it" : "them") + " frees that memory now. Started again, "
            + (n == 1 ? "it picks" : "they pick") + " up the same conversation."
        return Text(title: title, body: body,
                    keep: n == 1 ? "Keep It Running" : "Keep Them Running",
                    end: n == 1 ? "End It" : "End Them")
    }
}

/// When Coldfall opens and desks that were running last time aren't (a
/// restart of the Mac, a crash, or an ordinary quit of desks that weren't
/// kept running), it offers to start them again, each picking up its
/// conversation. Ending them on purpose with End Them leaves nothing to offer.
public enum RestoreOffer {
    /// The desks to offer: those that were running last time, still in the
    /// list, not hidden, and not already back (held, or started).
    public static func desks(wasRunning: [String], names: [String], hidden: Set<String>,
                             runningNow: Set<String>) -> [String] {
        let known = Set(names)
        var seen = Set<String>()
        return wasRunning.filter { known.contains($0) && !hidden.contains($0) && !runningNow.contains($0) && seen.insert($0).inserted }
    }

    public static func line(_ desks: [String]) -> String? {
        guard !desks.isEmpty else { return nil }
        let n = desks.count
        return (n == 1 ? "\(desks[0]) was running" : "\(n) desks were running")
            + " when Coldfall last closed"
            + (n == 1 ? "" : ": " + TextStyle.list(desks))
            + ". Start " + (n == 1 ? "it" : "them") + " again to pick up where you left off."
    }

    public static func button(_ desks: [String]) -> String {
        desks.count == 1 ? "Start \(desks[0]) Again" : "Start All \(desks.count)"
    }
}
