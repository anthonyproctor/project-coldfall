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

    init(host: InboxHost, port: UInt16 = Inbox.defaultPort) {
        self.host = host
        self.port = port
    }

    var isRunning: Bool { !listeners.isEmpty }

    /// The link to open on a phone: the first Tailscale address, with the secret.
    var link: String? {
        guard let ip = addresses.first(where: Inbox.isTailscale), let t = Inbox.token() else { return nil }
        return "http://\(ip):\(port)/?t=\(t)"
    }

    func start() {
        stop()
        guard let token = Inbox.token() else { return }
        addresses = Inbox.tailscaleAddresses() + ["127.0.0.1"]
        let allowed = addresses + ["localhost"]
        for ip in addresses {
            let p = NWParameters.tcp
            p.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!)
            p.allowLocalEndpointReuse = true
            guard let l = try? NWListener(using: p) else { continue }
            l.newConnectionHandler = { [weak self] c in self?.serve(c, token: token, allowed: allowed) }
            // A port someone else holds fails here, not at start: drop the
            // listener so the next check (every few seconds) tries again.
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard case .failed = state, let l else { return }
                l.cancel()
                DispatchQueue.main.async { self?.listeners.removeAll { $0 === l } }
            }
            l.start(queue: queue)
            listeners.append(l)
        }
    }

    func stop() {
        for l in listeners { l.cancel() }
        listeners = []
    }

    private func serve(_ c: NWConnection, token: String, allowed: [String]) {
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
                        if let h = self?.host { resp = Inbox.respond(r, token: token, allowedHosts: allowed, host: h) }
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
