import Foundation

/// The inbox: every desk on one small web page, for a phone or another
/// computer, served by Coldfall over Tailscale.
///
/// It reads screens and types into agents that run with this account's
/// access, so it is shut by default and narrow when open:
///
/// - It listens only on this Mac's Tailscale address (and loopback), never on
///   the home network or the internet. Tailscale encrypts the traffic and only
///   devices on your own tailnet can reach that address.
/// - Even there, nothing answers without the secret in the link, which is
///   swapped for a cookie the first time. The secret lives in
///   ~/.config/coldfall/inbox-token, readable by this account only.
/// - A request has to name this Mac as its Host (no DNS rebinding), and
///   anything that changes something has to come from the page itself
///   (a custom header a cross-site form can't send).
/// - Sending follows `coldfall-cli send`: never into a desk stopped on a
///   question, never into a shell, and it waits for a half-typed message.
/// - Agent output is put on the page as text, never as markup.
///
/// HTTP here is the least that works: one request per connection, no
/// keep-alive, bodies by Content-Length. The app owns the socket; this owns
/// every decision, so it can be tested.
public enum Inbox {
    public static let defaultPort: UInt16 = 47100
    public static let cookieName = "cf_inbox"

    public static var tokenPath: String {
        (Limits.configDir as NSString).appendingPathComponent("inbox-token")
    }

    /// The secret, made on first use: 32 random bytes, URL-safe.
    public static func token(path: String = Inbox.tokenPath) -> String? {
        if let t = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           t.count >= 32 { return t }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandom(&bytes) else { return nil }
        let t = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: path, contents: Data(t.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return nil }
        return t
    }

    /// A new secret: every device has to use the new link.
    public static func resetToken(path: String = Inbox.tokenPath) -> String? {
        try? FileManager.default.removeItem(atPath: path)
        return token(path: path)
    }

    static func SecRandom(_ bytes: inout [UInt8]) -> Bool {
        guard let f = fopen("/dev/urandom", "r") else { return false }
        defer { fclose(f) }
        return fread(&bytes, 1, bytes.count, f) == bytes.count
    }

    // MARK: - where it listens

    /// This Mac's Tailscale IPv4 addresses: on a tunnel interface (utun,
    /// which is what Tailscale uses on a Mac) and in the 100.64.0.0/10 range
    /// it hands out. A home network or a carrier that happens to use that
    /// range on an ordinary interface doesn't count.
    public static func tailscaleAddresses() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  isTunnel(String(cString: a.pointee.ifa_name)) else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let v = UInt32(bigEndian: addr)
            let ip = "\(v >> 24).\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
            if isTailscale(ip) { out.append(ip) }
        }
        return Array(Set(out)).sorted()
    }

    public static func isTunnel(_ interface: String) -> Bool { interface.hasPrefix("utun") }

    public static func isTailscale(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 100 && (64...127).contains(p[1])
    }

    // MARK: - HTTP, just enough

    public struct Request: Equatable {
        public var method: String
        public var path: String
        public var query: [String: String]
        /// Names in lower case.
        public var headers: [String: String]
        public var body: Data
        public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
            self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
        }
        public var cookies: [String: String] {
            var c: [String: String] = [:]
            for part in (headers["cookie"] ?? "").split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { c[kv[0]] = kv[1] }
            }
            return c
        }
    }

    public enum Parse: Equatable {
        case incomplete
        case bad
        case request(Request)
    }

    public static let maxBody = 64 * 1024
    public static let maxHead = 16 * 1024

    /// A request from the bytes so far.
    public static func parse(_ data: Data) -> Parse {
        let sep = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: sep) else { return data.count > maxHead ? .bad : .incomplete }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .bad }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .bad }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { return .bad }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBody else { return .bad }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let target = String(first[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        return .request(Request(method: String(first[0]), path: comps?.path ?? target, query: query, headers: headers,
                                body: data.subdata(in: bodyStart..<(bodyStart + length))))
    }

    public struct Response: Equatable {
        public var status: Int
        public var headers: [(String, String)]
        public var body: Data
        public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
            self.status = status; self.headers = headers; self.body = body
        }
        public static func == (a: Response, b: Response) -> Bool {
            a.status == b.status && a.body == b.body && a.headers.map { $0.0 + ":" + $0.1 } == b.headers.map { $0.0 + ":" + $0.1 }
        }
        public func header(_ name: String) -> String? { headers.first { $0.0.lowercased() == name.lowercased() }?.1 }

        static let reasons = [200: "OK", 302: "Found", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                              404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large"]

        public func serialize() -> Data {
            var h = "HTTP/1.1 \(status) \(Response.reasons[status] ?? "Status")\r\n"
            var all = headers
            all.append(("Content-Length", "\(body.count)"))
            all.append(("Connection", "close"))
            // Nothing from here is ever cached, framed, or sniffed.
            all.append(("Cache-Control", "no-store"))
            all.append(("X-Frame-Options", "DENY"))
            all.append(("X-Content-Type-Options", "nosniff"))
            all.append(("Referrer-Policy", "no-referrer"))
            for (k, v) in all { h += "\(k): \(v)\r\n" }
            h += "\r\n"
            return Data(h.utf8) + body
        }

        public static func json(_ obj: Any, status: Int = 200) -> Response {
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
            return Response(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: d)
        }
        public static func text(_ s: String, status: Int) -> Response {
            Response(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(s.utf8))
        }
    }

    // MARK: - who may ask

    public enum Gate: Equatable {
        case allowed
        /// The secret came in the link: set the cookie and drop it from the URL.
        case setCookie(redirectTo: String)
        case denied(Response)
    }

    /// Every request goes through this first.
    public static func gate(_ r: Request, token: String, allowedHosts: [String]) -> Gate {
        // The Host must be this Mac, as reached: no DNS rebinding.
        let host = (r.headers["host"] ?? "").split(separator: ":").first.map(String.init)?.lowercased() ?? ""
        guard allowedHosts.contains(host) else { return .denied(.text("Not here.", status: 403)) }
        if let t = r.query["t"], same(t, token) { return .setCookie(redirectTo: r.path) }
        guard let c = r.cookies[cookieName], same(c, token) else {
            return .denied(.text("This inbox needs its link. Open Coldfall's Settings, General, Inbox, on the Mac.", status: 401))
        }
        // Changes only from the page itself: a form on another site can't
        // add a custom header, and a script there would need CORS, which
        // this never grants.
        if r.method != "GET", r.headers["x-coldfall"] != "1" { return .denied(.text("Not from the inbox.", status: 403)) }
        return .allowed
    }

    /// Compare without leaking how much matched.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in x.indices { d |= x[i] ^ y[i] }
        return d == 0
    }

    public static func cookieHeader(_ token: String) -> (String, String) {
        ("Set-Cookie", "\(cookieName)=\(token); HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000")
    }

    // MARK: - the list

    public struct Row: Equatable {
        public var name: String
        public var group: String?
        public var runtime: String
        public var running: Bool
        /// "blocked", "ready", "working" or "quiet".
        public var activity: String
        public var lastOutput: Double?
        public init(name: String, group: String?, runtime: String, running: Bool, activity: String, lastOutput: Double?) {
            self.name = name; self.group = group; self.runtime = runtime; self.running = running
            self.activity = activity; self.lastOutput = lastOutput
        }
        /// Needs you, done, working, idle, then not started.
        public var rank: Int {
            if !running { return 4 }
            switch activity { case "blocked": return 0; case "ready": return 1; case "working": return 2; default: return 3 }
        }
    }

    public static func ordered(_ rows: [Row]) -> [Row] {
        rows.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            let a = $0.lastOutput ?? 0, b = $1.lastOutput ?? 0
            if a != b { return $0.rank <= 1 ? a < b : a > b }   // waiting longest first; else most recent
            return $0.name < $1.name
        }
    }

    public static func json(_ rows: [Row]) -> [[String: Any]] {
        ordered(rows).map { r in
            var o: [String: Any] = ["name": r.name, "runtime": r.runtime, "running": r.running, "activity": r.activity]
            if let g = r.group { o["group"] = g }
            if let l = r.lastOutput { o["lastOutput"] = l }
            return o
        }
    }

    /// Keys the inbox may press in a desk stopped on a question, to answer
    /// a permission prompt or a choice from a phone. Nothing that interrupts
    /// or edits: no Ctrl-C, no text.
    public static let keys: [String: [UInt8]] = {
        var k: [String: [UInt8]] = ["enter": [13], "esc": [27], "up": [27, 91, 65], "down": [27, 91, 66], "tab": [9]]
        for d in 1...9 { k["\(d)"] = Array("\(d)".utf8) }
        return k
    }()

    /// A request body's fields: JSON object of strings.
    public static func fields(_ body: Data) -> [String: String] {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in o { if let s = v as? String { out[k] = s } }
        return out
    }
}

/// What the inbox needs from the app. Called on the main thread.
public protocol InboxHost: AnyObject {
    func inboxRows() -> [Inbox.Row]
    /// The screen and state of one desk, or nil if there's no such desk.
    func inboxDesk(_ name: String, lines: Int) -> Inbox.DeskView?
    func inboxSend(_ name: String, text: String) -> RemoteOpen.Answer
    /// Press keys in a desk stopped on a question.
    func inboxPress(_ name: String, keys: [UInt8]) -> RemoteOpen.Answer
    func inboxOpen(_ name: String) -> RemoteOpen.Answer
}

extension Inbox {
    public struct DeskView: Equatable {
        public var text: String
        public var running: Bool
        public var activity: String
        public var runtime: String
        /// An agent is in its pane (not a shell): it can take a message.
        public var agent: Bool
        public init(text: String, running: Bool, activity: String, runtime: String, agent: Bool) {
            self.text = text; self.running = running; self.activity = activity; self.runtime = runtime; self.agent = agent
        }
    }

    /// A request that got through the gate, answered.
    public static func route(_ r: Request, host: InboxHost) -> Response {
        func answer(_ a: RemoteOpen.Answer) -> Response { .json(["outcome": a.outcome.rawValue, "message": a.message]) }
        switch (r.method, r.path) {
        case ("GET", "/"):
            return Response(status: 200, headers: [("Content-Type", "text/html; charset=utf-8"),
                                                   ("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'")],
                            body: Data(page.utf8))
        case ("GET", "/api/desks"):
            return .json(["desks": json(host.inboxRows())])
        case ("GET", "/api/read"):
            let lines = min(2000, max(1, Int(r.query["lines"] ?? "") ?? 200))
            guard let name = r.query["desk"], let v = host.inboxDesk(name, lines: lines) else {
                return .json(["message": "No such desk."], status: 404)
            }
            return .json(["text": v.text, "running": v.running, "activity": v.activity, "runtime": v.runtime, "agent": v.agent])
        case ("POST", "/api/send"):
            let f = fields(r.body)
            guard let name = f["desk"], let text = f["text"] else { return .json(["message": "Send needs a desk and text."], status: 400) }
            return answer(host.inboxSend(name, text: text))
        case ("POST", "/api/keys"):
            let f = fields(r.body)
            guard let name = f["desk"], let k = f["key"], let bytes = keys[k] else {
                return .json(["message": "That isn't a key the inbox presses."], status: 400)
            }
            return answer(host.inboxPress(name, keys: bytes))
        case ("POST", "/api/open"):
            guard let name = fields(r.body)["desk"] else { return .json(["message": "Open needs a desk."], status: 400) }
            return answer(host.inboxOpen(name))
        case (_, "/"), (_, "/api/desks"), (_, "/api/read"), (_, "/api/send"), (_, "/api/keys"), (_, "/api/open"):
            return .text("Method not allowed.", status: 405)
        default:
            return .text("Not found.", status: 404)
        }
    }

    /// Bytes in, bytes out: the gate, then the route. What the app's socket
    /// calls once a whole request has arrived.
    public static func respond(_ r: Request, token: String, allowedHosts: [String], host: InboxHost) -> Response {
        switch gate(r, token: token, allowedHosts: allowedHosts) {
        case .denied(let resp): return resp
        case .setCookie(let to):
            return Response(status: 302, headers: [cookieHeader(token), ("Location", to.isEmpty ? "/" : to)])
        case .allowed: return route(r, host: host)
        }
    }
}
