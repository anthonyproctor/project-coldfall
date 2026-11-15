import AppKit
import ColdfallCore

/// Keeps Coldfall's picture of the Family Connector current: one connection
/// that only listens for `changed`, and a short-lived one to re-read the
/// lists when it fires. No timer reads content; while the app isn't there,
/// a cheap check every 30 seconds looks for its socket.
///
/// Everything here lives in memory. Nothing from the Connector is written to
/// disk, and nothing in it is ever typed into a desk.
final class ConnectorWatch {
    enum State: Equatable {
        case absent                // no Connector app on this Mac, or it isn't running
        case notLetIn              // running, but Coldfall hasn't been let in
        case problem(String)       // a path or schema Coldfall can't use
        case connected(fixture: Bool)
    }

    private(set) var state: State = .absent
    private(set) var items: [Connector.Item] = []
    private(set) var circles: [Connector.Circle] = []
    /// Main thread, after any change to state or items.
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "coldfall.connector", qos: .utility)
    private var started = false
    private var generation = 0

    var path: String { Connector.socketPath() }

    func start() {
        guard !started else { return }
        started = true
        queue.async { [weak self] in self?.loop() }
    }

    /// Re-read now (after a press of ours: mark seen, a release request).
    func refresh() { queue.async { [weak self] in self?.reload() } }

    private func publish(_ s: State, _ list: [Connector.Item]?, _ circles: [Connector.Circle]? = nil) {
        DispatchQueue.main.async {
            var changed = false
            if s != self.state { self.state = s; changed = true }
            if let list, list != self.items { self.items = list; changed = true }
            if let circles, circles != self.circles { self.circles = circles; changed = true }
            if changed {
                // COLDFALL_CONNECTOR_DEBUG=1: say what changed (counts only, never words).
                if ProcessInfo.processInfo.environment["COLDFALL_CONNECTOR_DEBUG"] == "1" {
                    FileHandle.standardError.write(Data("connector: \(self.state), \(Connector.count(self.items)) waiting, \(self.circles.count) circles\n".utf8))
                }
                self.onChange?()
            }
        }
    }

    /// One fresh connection: hello, the three lists, the circles.
    @discardableResult
    private func reload() -> Bool {
        do {
            let c = try ConnectorClient(path: path, token: Connector.token())
            let list = try c.snapshot()
            let circ = Connector.circles(try c.call("circles"))
            publish(.connected(fixture: c.isFixture), list, circ)
            return true
        } catch let f as ConnectorClient.Failure {
            publish(Self.state(for: f), [], [])
            return false
        } catch {
            publish(.absent, [], [])
            return false
        }
    }

    static func state(for f: ConnectorClient.Failure) -> State {
        switch f {
        case .absent, .broken: return .absent
        case .notLetIn: return .notLetIn
        case .path(let s), .schema(let s): return .problem(s)
        case .refused(let r, let m): return r == "not_authenticated" ? .notLetIn : .problem(m)
        }
    }

    private func loop() {
        while true {
            // Nothing there: look again in a while, without connecting.
            guard FileManager.default.fileExists(atPath: path) else {
                publish(.absent, [], [])
                Thread.sleep(forTimeInterval: 30)
                continue
            }
            guard reload() else { Thread.sleep(forTimeInterval: 30); continue }
            // Listen. A push says something changed; re-read and listen again.
            do {
                let listen = try ConnectorClient(path: path, token: Connector.token(), timeout: 0)
                _ = try listen.call("subscribe")
                while true {
                    try listen.waitForChange()
                    reload()
                }
            } catch {
                // The app quit or restarted: start over shortly.
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }

    // MARK: - the few things Coldfall asks of it

    /// Run one request off the main thread; the reply's message (or nil on
    /// success) comes back on the main thread.
    func request(_ method: String, _ params: [String: Any], done: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            var note: String?
            do {
                let c = try ConnectorClient(path: self.path, token: Connector.token())
                try c.call(method, params)
            } catch let f as ConnectorClient.Failure {
                note = f.description
            } catch {
                note = "Connector didn't answer."
            }
            self.reload()
            DispatchQueue.main.async { done(note) }
        }
    }

    /// Open the Connector app at this item. Its links only navigate.
    static func open(_ i: Connector.Item?) {
        let url = i.flatMap(Connector.openLink) ?? URL(string: "connector://open")!
        NSWorkspace.shared.open(url)
    }

    /// For snapshots: read once, now, on this thread.
    func loadNow() {
        if let c = try? ConnectorClient(path: path, token: Connector.token()) {
            state = .connected(fixture: c.isFixture)
            items = (try? c.snapshot()) ?? []
            circles = Connector.circles((try? c.call("circles")) ?? [:])
        }
    }

    /// One line for Settings.
    var summary: String {
        switch state {
        case .absent:
            return "Not running on this Mac. The Family Connector is a separate app; when it runs, what's waiting in it shows in Needs You."
        case .notLetIn:
            return "Connector is running, but hasn't let Coldfall in. In Connector: Settings, Agents on this Mac, Let this agent in, and type coldfall."
        case .problem(let s):
            return s
        case .connected(let fixture):
            let n = Connector.count(items)
            return (fixture ? "Connected to the test fixture. " : "Connected. ")
                + (n == 0 ? "Nothing waiting." : "\(n) waiting, in Needs You.")
        }
    }
}

/// A target for a popup's action in a modal alert.
final class CircleChange: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func changed() { run() }
}
