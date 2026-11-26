import Foundation
import Network
import ColdfallCore

/// The socket side of the inbox (see Inbox in the core, which decides
/// everything). Listens on this Mac's Tailscale addresses and loopback only,
/// one request per connection.
final class InboxServer {
    private var listeners: [NWListener] = []
    private let queue = DispatchQueue(label: "coldfall.inbox")
    private weak var host: InboxHost?
    private(set) var addresses: [String] = []
    let port: UInt16
    /// This Mac's name on the tailnet, once Tailscale has said. The inbox
    /// answers to it too: it is the name Tailscale's HTTPS serves under.
    private(set) var name: String?
    /// The inbox behind Tailscale's HTTPS, if the person has set that up.
    private(set) var served: Tailnet.Served?
    /// Called on the main thread when either of those changes.
    var onFacts: (() -> Void)?

    init(host: InboxHost, port: UInt16 = Inbox.defaultPort) {
        self.host = host
        self.port = port
    }

    var isRunning: Bool { !listeners.isEmpty }

    /// After a start that failed (the port held by something else), when to
    /// try again: 5 seconds, doubling to 5 minutes, back to 5 once one works
    /// or the addresses change.
    private(set) var retryAt = Date.distantPast
    private var retryDelay: TimeInterval = 5
    /// The addresses Tailscale was last asked about: retries don't ask again.
    private var factsFor: [String]?

    /// Whether `applyInbox` should start it now.
    func shouldStart(addresses now: [String], at t: Date = Date()) -> Bool {
        if addresses != now { retryDelay = 5; retryAt = .distantPast; return true }
        return !isRunning && t >= retryAt
    }

    private func failed() {
        retryAt = Date().addingTimeInterval(retryDelay)
        retryDelay = min(retryDelay * 2, 300)
    }

    /// The link to open on a phone: the first Tailscale address, with the secret.
    var link: String? {
        guard let ip = addresses.first(where: Inbox.isTailscale), let t = Inbox.token() else { return nil }
        return "http://\(ip):\(port)/?t=\(t)"
    }

    func start() {
        stop()
        guard let token = Inbox.token() else { return }
        addresses = Inbox.tailscaleAddresses() + ["127.0.0.1"]
        for ip in addresses {
            let p = NWParameters.tcp
            // Each address on a port of its own (127.0.0.1 on localPort), with
            // no port sharing: something else on the port makes this fail,
            // rather than both listening and that one catching some requests.
            let at = ip == "127.0.0.1" ? Inbox.localPort : port
            p.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: at)!)
            guard let l = try? NWListener(using: p) else { continue }
            l.newConnectionHandler = { [weak self] c in self?.serve(c, token: token) }
            // A port someone else holds fails here, not at start: drop the
            // listener so the next check (every few seconds) tries again.
            l.stateUpdateHandler = { [weak self, weak l] state in
                switch state {
                case .ready:
                    DispatchQueue.main.async { self?.retryDelay = 5 }
                case .failed:
                    guard let l else { return }
                    l.cancel()
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.listeners.removeAll { $0 === l }
                        if self.listeners.isEmpty { self.failed() }
                    }
                default: break
                }
            }
            l.start(queue: queue)
            listeners.append(l)
        }
        if listeners.isEmpty { failed() }
        // Tailscale is asked about this Mac once per set of addresses, not
        // on every retry (Settings can still ask again by hand).
        if factsFor != addresses { factsFor = addresses; refreshFacts() }
    }

    /// Ask Tailscale for this Mac's name and whether it serves the inbox over
    /// HTTPS. Two read-only commands, off the main thread.
    func refreshFacts() {
        let port = Inbox.localPort      // what `tailscale serve` passes the https address to
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let f = Tailnet.inboxFacts(port: port)
            DispatchQueue.main.async {
                guard let self, f.name != self.name || f.served != self.served else { return }
                self.name = f.name
                self.served = f.served
                self.onFacts?()
            }
        }
    }

    /// Every name a request may call this Mac by.
    var hosts: [String] {
        addresses + ["localhost"] + [name, served?.host].compactMap { $0 }
    }

    func stop() {
        for l in listeners { l.cancel() }
        listeners = []
    }

    /// Connections open now (on `queue`). Each holds up to a request's worth
    /// for 15 seconds; past this many, a new one is closed at once.
    private var open = 0
    static let maxOpen = 32

    private func serve(_ c: NWConnection, token: String) {
        guard open < Self.maxOpen else { c.cancel(); return }
        open += 1
        var counted = true
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                if counted { counted = false; self?.open -= 1 }
            default: break
            }
        }
        c.start(queue: queue)
        var buffer = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
                if let d = data { buffer.append(d) }
                switch Inbox.parse(buffer) {
                case .incomplete where !done && err == nil:
                    read()
                case .request(let r):
                    var resp = Inbox.Response.text("Coldfall isn't ready.", status: 404)
                    // Desks live on the main thread.
                    DispatchQueue.main.sync {
                        if let self, let h = self.host {
                            resp = Inbox.respond(r, token: token, allowedHosts: self.hosts, host: h,
                                                 funnelHost: self.served?.funnel == true ? self.served?.host : nil)
                        }
                    }
                    c.send(content: resp.serialize(), completion: .contentProcessed { _ in c.cancel() })
                default:
                    c.send(content: Inbox.Response.text("Bad request.", status: 400).serialize(),
                           completion: .contentProcessed { _ in c.cancel() })
                }
            }
        }
        read()
        // A connection that never finishes its request doesn't stay.
        queue.asyncAfter(deadline: .now() + 15) { c.cancel() }
    }
}
