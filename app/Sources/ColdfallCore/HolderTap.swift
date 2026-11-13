import Foundation

/// Listens to a held desk without driving it (see Holder.Kind.tap): a copy
/// of what its program writes and of the keys its terminal sends.
///
/// This is how Coldfall knows what a desk is doing when the terminal on
/// screen owns its own pty and offers no hook on the bytes (libghostty).
/// Callbacks arrive on the tap's own thread.
public final class HolderTap {
    private let path: String
    private var fd: Int32 = -1
    private var thread: Thread?
    private let lock = NSLock()
    private var stopped = false
    /// Output from before the tap connected: the holder's memory of it.
    /// For learning the desk's standing state, not for "it just spoke".
    public var onReplay: (([UInt8]) -> Void)?
    /// The replay is over; what follows is live.
    public var onLive: (() -> Void)?
    public var onOutput: (([UInt8]) -> Void)?
    public var onInput: (([UInt8]) -> Void)?
    /// The holder went away (the desk ended) or stopped speaking our wire.
    public var onEnd: (() -> Void)?

    /// How long to wait for the holder's "live from here" mark.
    public static let markWait: TimeInterval = 2

    public init(desk: String, root: String = Holder.root) {
        path = Holder.socketPath(desk: desk, root: root)
    }

    /// Connect and start listening. False when there is no holder to hear.
    @discardableResult
    public func start() -> Bool {
        guard fd < 0, let c = Holder.connect(path) else { return false }
        fd = c
        let hello = Holder.Wire.encode(.tap, Holder.Wire.tap())
        let sent = hello.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
        guard sent == hello.count else { close(c); fd = -1; return false }
        let t = Thread { [weak self] in self?.listen(c) }
        t.name = "coldfall.holder.tap"
        t.stackSize = 256 * 1024
        thread = t
        t.start()
        return true
    }

    public func stop() {
        lock.lock(); stopped = true; let c = fd; fd = -1; lock.unlock()
        // Shutting the socket down wakes the read; the thread closes it.
        if c >= 0 { shutdown(c, SHUT_RDWR) }
    }

    private func listen(_ c: Int32) {
        var dec = Holder.Decoder()
        var live = false
        var buf = [UInt8](repeating: 0, count: 65536)
        // A holder from before the replay never sends the mark. A current
        // one sends it within milliseconds, so after this long without it
        // everything is taken as live rather than waited on forever.
        let deadline = Date().addingTimeInterval(HolderTap.markWait)
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while true {
            if !live, Date() >= deadline { live = true; onLive?() }
            let n = read(c, &buf, buf.count)
            if n < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard n > 0 else { break }
            for (kind, payload) in dec.push(Array(buf[0..<n])) {
                switch kind {
                case .output: if live { onOutput?(payload) } else { onReplay?(payload) }
                case .input: if live { onInput?(payload) }
                case .tap: if !live { live = true; onLive?() }
                default: break
                }
            }
            if dec.broken { break }
        }
        close(c)
        lock.lock(); let wasStopped = stopped; lock.unlock()
        if !wasStopped { onEnd?() }
    }
}
