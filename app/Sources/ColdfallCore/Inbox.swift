import Foundation
import CryptoKit

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
///   ~/.config/coldfall/inbox-token, readable by this account only. (The
///   icon and the few lines that let a phone put it on its Home Screen are
///   the exception: a phone fetches those without the cookie, and they say
///   only "Coldfall".)
/// - It can be put behind Tailscale's own HTTPS (`tailscale serve`), which a
///   phone needs before it will treat the page as an app. Never behind
///   Funnel, Tailscale's public kind: a request that came that way is refused.
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
    /// On 127.0.0.1 the inbox has a port of its own: what `tailscale serve`
    /// passes the https address on to. One port on two addresses needed port
    /// sharing, which another account on the Mac could have used to listen
    /// beside Coldfall.
    public static let localPort: UInt16 = testPort ?? 47101
    /// `COLDFALL_INBOX_TEST_PORT`: for a throwaway Coldfall beside a real one.
    /// The inbox then listens on 127.0.0.1 at this port and nowhere else, so
    /// it never meets the real one's ports or the tailnet.
    public static let testPort: UInt16? = ProcessInfo.processInfo.environment["COLDFALL_INBOX_TEST_PORT"].flatMap { UInt16($0) }
    /// The port the inbox listens on at this address.
    public static func port(for address: String) -> UInt16 { address == "127.0.0.1" ? localPort : defaultPort }
    public static let cookieName = "cf_inbox"

    public static var tokenPath: String {
        (Limits.configDir as NSString).appendingPathComponent("inbox-token")
    }

    /// The secret, made on first use: 32 random bytes, URL-safe.
    public static func token(path: String = Inbox.tokenPath) -> String? {
        if let t = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           t.count >= 32 {
            // Readable by you alone, even if something loosened it since.
            Secret.ownerOnly(path)
            return t
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandom(&bytes) else { return nil }
        let t = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        // A folder made here is yours alone; one that already exists (it holds
        // desks.toml) is left as it is.
        Secret.folder((path as NSString).deletingLastPathComponent)
        // Made owner-only from the first byte: never readable by others, not
        // even for the moment between writing it and setting its mode.
        try? FileManager.default.removeItem(atPath: path)
        guard Secret.write(Data(t.utf8), to: path) else { return nil }
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
    /// A photo from the phone, base64 in JSON: the one request allowed more.
    public static let maxUploadBody = 12 * 1024 * 1024
    /// The photo itself, once decoded.
    public static let maxPhoto = 8 * 1024 * 1024
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
        let limit = first[0] == "POST" && first[1] == "/api/upload" ? maxUploadBody : maxBody
        guard length >= 0, length <= limit else { return .bad }
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
                              404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 503: "Service Unavailable"]

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
    public static func gate(_ r: Request, token: String, allowedHosts: [String], funnelHost: String? = nil) -> Gate {
        // The Host must be this Mac, as reached: no DNS rebinding.
        let host = (r.headers["host"] ?? "").split(separator: ":").first.map(String.init)?.lowercased() ?? ""
        guard allowedHosts.contains(host) else { return .denied(.text("Not here.", status: 403)) }
        // With Funnel on for the inbox's https name, that name is on the open
        // internet: nothing is answered under it, whatever headers came with
        // the request (the check below depends on Tailscale adding one).
        if let f = funnelHost?.lowercased(), host == f {
            return .denied(.text("Not over Tailscale Funnel. The inbox is for your own devices only.", status: 403))
        }
        // Tailscale marks what came in from the internet through Funnel.
        // The inbox is for your own devices: that is never answered.
        if r.headers["tailscale-funnel-request"] != nil {
            return .denied(.text("Not over Tailscale Funnel. The inbox is for your own devices only.", status: 403))
        }
        if r.method == "GET", publicPaths.contains(r.path) { return .allowed }
        if let t = r.query["t"], same(t, token) { return .setCookie(redirectTo: r.path) }
        guard let c = r.cookies[cookieName], same(c, cookieValue(token)) else {
            // Opened as a page (an app on a Home Screen has no address bar to
            // put the link in): somewhere to paste it.
            if r.method == "GET", r.path == "/" {
                return .denied(Response(status: 401, headers: [("Content-Type", "text/html; charset=utf-8"), pagePolicy],
                                        body: Data(askPage.utf8)))
            }
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

    /// What the cookie holds: worked out from the secret, not the secret
    /// itself, so a cookie that leaks (or a listener that catches one) isn't
    /// the link. A new link changes it too.
    public static func cookieValue(_ token: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("coldfall-inbox-cookie".utf8), using: SymmetricKey(data: Data(token.utf8)))
        return Data(mac).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `secure` when the request came over HTTPS: the browser then sends the
    /// cookie only over HTTPS.
    public static func cookieHeader(_ token: String, secure: Bool = false) -> (String, String) {
        ("Set-Cookie", "\(cookieName)=\(cookieValue(token)); HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000" + (secure ? "; Secure" : ""))
    }

    /// Whether the request says Tailscale's HTTPS passed it on. Anyone can
    /// send this header over plain HTTP; the only thing it decides is the
    /// cookie's Secure flag, and a browser given a Secure cookie over plain
    /// HTTP just doesn't keep it.
    public static func cameSecure(_ r: Request) -> Bool { r.headers["x-forwarded-proto"]?.lowercased() == "https" }

    /// What a phone fetches without the cookie when it puts the inbox on its
    /// Home Screen. Nothing here says more than "Coldfall".
    public static let publicPaths: Set<String> = ["/manifest.webmanifest", "/icon-180.png", "/icon-192.png", "/icon-512.png"]
    static let iconSizes = ["/icon-180.png": 180, "/icon-192.png": 192, "/icon-512.png": 512]

    /// Scripts run only if they are exactly the page's own: each inline
    /// script is allowed by its SHA-256, not by 'unsafe-inline', so text that
    /// found its way into the page could never run as a script.
    public static let pagePolicy = ("Content-Security-Policy",
                             "default-src 'none'; script-src " + (scriptHashes(page) + scriptHashes(askPage)).map { "'\($0)'" }.joined(separator: " ")
                             + "; style-src 'unsafe-inline'; connect-src 'self'; "
                             + "img-src 'self' blob:; manifest-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'none'")

    /// "sha256-…" for each <script> in a page, over its text exactly.
    public static func scriptHashes(_ html: String) -> [String] {
        var out: [String] = []
        var rest = html[...]
        while let open = rest.range(of: "<script>"), let close = rest.range(of: "</script>", range: open.upperBound..<rest.endIndex) {
            let body = rest[open.upperBound..<close.lowerBound]
            out.append("sha256-" + Data(SHA256.hash(data: Data(body.utf8))).base64EncodedString())
            rest = rest[close.upperBound...]
        }
        return out
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
        /// Why it is waiting, or what it is doing (see DeskDetail).
        public var detail: String?
        /// Pinned to the top of the desk list, as in the app.
        public var pinned: Bool = false
        /// Put to sleep (stopped to save memory, picks up when started).
        public var asleep: Bool = false
        /// What it holds in memory now, as the app's rail says it ("820 MB").
        public var memory: String? = nil
        public init(name: String, group: String?, runtime: String, running: Bool, activity: String, lastOutput: Double?,
                    detail: String? = nil, pinned: Bool = false, asleep: Bool = false, memory: String? = nil) {
            self.name = name; self.group = group; self.runtime = runtime; self.running = running
            self.activity = activity; self.lastOutput = lastOutput; self.detail = detail
            self.pinned = pinned; self.asleep = asleep; self.memory = memory
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
            if let d = r.detail { o["detail"] = d }
            if r.pinned { o["pinned"] = true }
            if r.asleep { o["asleep"] = true }
            if let m = r.memory { o["memory"] = m }
            return o
        }
    }

    /// The notices up (see Notice), for desks the inbox lists: a hidden desk's stays off the phone.
    public static func notices(for rows: [Row], now: Date = Date()) -> [[String: Any]] {
        let names = Set(rows.map(\.name))
        return Notice.all(now: now).filter { names.contains($0.desk) }.map { ["desk": $0.desk, "text": $0.text, "time": $0.time] }
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
    /// The most a page may ask for at once: what a phone scrolls back through.
    public static let maxReadLines = 5000

    /// FNV-1a over the text, so the page can say which copy it has.
    public static func textHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 36)
    }

    /// What kind of picture these bytes are, by their first bytes; nil for
    /// anything else, whatever it claims to be.
    public static func photoKind(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(16))
        guard b.count >= 12 else { return nil }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b[0...7].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if b[0...3].elementsEqual(Array("GIF8".utf8)) { return "gif" }
        if b[0...3].elementsEqual(Array("RIFF".utf8)), b[8...11].elementsEqual(Array("WEBP".utf8)) { return "webp" }
        if b[4...7].elementsEqual(Array("ftyp".utf8)) {
            let brand = String(decoding: b[8...11], as: UTF8.self)
            if ["heic", "heix", "mif1", "msf1", "heim", "heis"].contains(brand) { return "heic" }
        }
        return nil
    }

    /// The folder photos go in, inside a desk's folder. It ignores itself in
    /// git, so a photo never ends up in a commit.
    public static let photoFolder = ".coldfall-photos"

    /// Save a photo for a desk; returns its full path. The name is made here,
    /// from the time, never from anything the phone said.
    public static func savePhoto(_ data: Data, folder: String, now: Date = Date()) -> String? {
        guard let kind = photoKind(data), FileManager.default.fileExists(atPath: folder) else { return nil }
        let dir = (folder as NSString).appendingPathComponent(photoFolder)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        }
        let ignore = (dir as NSString).appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: ignore) { try? "*\n".write(toFile: ignore, atomically: true, encoding: .utf8) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var path = (dir as NSString).appendingPathComponent("photo-\(f.string(from: now)).\(kind)")
        var n = 2
        while fm.fileExists(atPath: path) {
            path = (dir as NSString).appendingPathComponent("photo-\(f.string(from: now))-\(n).\(kind)"); n += 1
        }
        guard fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        return path
    }

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
    /// The app's icon as a square PNG, for a phone's Home Screen.
    func inboxIcon(_ size: Int) -> Data?
    /// Whether notifications to phones are turned on in Settings.
    func inboxPushOn() -> Bool
    /// Send a test notification to one device. What to tell the person.
    func inboxPushTest(_ endpoint: String) -> String
    /// Stop a running desk, as Stop in the app does, without its dialog
    /// (the phone asked first).
    func inboxStop(_ name: String) -> (ok: Bool, message: String)
    /// Pin a desk to the top of the list, or take it off.
    func inboxPin(_ name: String, on: Bool) -> (ok: Bool, message: String)
    /// Where a photo for this desk may go: its folder on this Mac, or why not.
    func inboxPhotoFolder(_ name: String) -> (folder: String?, message: String)
}

extension InboxHost {
    public func inboxIcon(_ size: Int) -> Data? { nil }
    public func inboxPushOn() -> Bool { false }
    public func inboxPushTest(_ endpoint: String) -> String { "Notifications aren't available here." }
    public func inboxStop(_ name: String) -> (ok: Bool, message: String) { (false, "Stopping isn't available here.") }
    public func inboxPin(_ name: String, on: Bool) -> (ok: Bool, message: String) { (false, "Pinning isn't available here.") }
    public func inboxPhotoFolder(_ name: String) -> (folder: String?, message: String) { (nil, "Photos aren't available here.") }
}

extension Inbox {
    public struct DeskView: Equatable {
        public var text: String
        public var running: Bool
        public var activity: String
        public var runtime: String
        /// An agent is in its pane (not a shell): it can take a message.
        public var agent: Bool
        /// The question it has stopped on, read off its screen, if any.
        public var prompt: Prompt?
        /// Said when it is asking and no choices could be read: whether
        /// Coldfall has read choices from this agent's version (PromptCheck).
        public var unread: String?
        public init(text: String, running: Bool, activity: String, runtime: String, agent: Bool, prompt: Prompt? = nil,
                    unread: String? = nil) {
            self.text = text; self.running = running; self.activity = activity; self.runtime = runtime; self.agent = agent
            self.prompt = prompt; self.unread = unread
        }
    }

    /// Once a phone has a passkey, what acts on a desk needs a fresh Face ID.
    static func needsFaceID(_ f: [String: String]) -> Response? {
        guard PhoneKey.required, !PhoneKey.unlocked(f["unlock"]) else { return nil }
        return .json(["needsFaceID": true, "message": "Face ID first."], status: 403)
    }

    /// A request that got through the gate, answered.
    public static func route(_ r: Request, host: InboxHost, allowedHosts: [String] = []) -> Response {
        func answer(_ a: RemoteOpen.Answer) -> Response { .json(["outcome": a.outcome.rawValue, "message": a.message]) }
        switch (r.method, r.path) {
        case ("GET", "/"):
            return Response(status: 200, headers: [("Content-Type", "text/html; charset=utf-8"), pagePolicy],
                            body: Data(page.utf8))
        case ("GET", "/manifest.webmanifest"):
            return Response(status: 200, headers: [("Content-Type", "application/manifest+json; charset=utf-8")],
                            body: Data(manifest.utf8))
        case ("GET", "/sw.js"):
            return Response(status: 200, headers: [("Content-Type", "text/javascript; charset=utf-8")], body: Data(worker.utf8))
        case ("GET", "/icon-180.png"), ("GET", "/icon-192.png"), ("GET", "/icon-512.png"):
            guard let size = iconSizes[r.path], let png = host.inboxIcon(size) else { return .text("Not found.", status: 404) }
            return Response(status: 200, headers: [("Content-Type", "image/png")], body: png)
        case ("POST", "/api/push/state"):
            // Asked by POST so a device's address never sits in a URL.
            let mine = fields(r.body)["endpoint"].flatMap { e in WebPush.devices().first { $0.endpoint == e } }
            var o: [String: Any] = ["on": host.inboxPushOn(), "subscribed": mine != nil, "key": WebPush.publicKey() ?? ""]
            if let l = mine.flatMap(WebPush.lastWords) { o["last"] = l }
            return .json(o)
        case ("POST", "/api/push/subscribe"):
            let f = fields(r.body)
            guard host.inboxPushOn() else {
                return .json(["ok": false, "message": "Phone notifications are off in Coldfall's Settings on the Mac."])
            }
            guard let e = f["endpoint"], let k = f["p256dh"], let a = f["auth"], let o = f["origin"] else {
                return .json(["ok": false, "message": "That isn't a subscription."], status: 400)
            }
            if let why = WebPush.add(endpoint: e, p256dh: k, auth: a, origin: o, hosts: allowedHosts) {
                return .json(["ok": false, "message": why])
            }
            return .json(["ok": true, "message": "Notifications are on for this device."])
        case ("POST", "/api/push/unsubscribe"):
            if let e = fields(r.body)["endpoint"] { WebPush.remove(endpoint: e) }
            return .json(["ok": true, "message": "Notifications are off for this device."])
        case ("POST", "/api/push/test"):
            guard let e = fields(r.body)["endpoint"], WebPush.devices().contains(where: { $0.endpoint == e }) else {
                return .json(["message": "This device isn't getting notifications yet."], status: 400)
            }
            return .json(["message": host.inboxPushTest(e)])
        case ("GET", "/api/desks"):
            let rows = host.inboxRows()
            return .json(["desks": json(rows), "notices": notices(for: rows)])
        case ("GET", "/api/read"):
            let lines = min(maxReadLines, max(1, Int(r.query["lines"] ?? "") ?? 200))
            guard let name = r.query["desk"], let v = host.inboxDesk(name, lines: lines) else {
                return .json(["message": "No such desk."], status: 404)
            }
            // The screen goes only when it has changed since the copy the
            // page already has: a phone polling a long scrollback every two
            // seconds would otherwise carry it all each time.
            let hash = textHash(v.text)
            var o: [String: Any] = ["running": v.running, "activity": v.activity, "runtime": v.runtime, "agent": v.agent,
                                    "hash": hash, "lines": v.text.isEmpty ? 0 : v.text.split(separator: "\n", omittingEmptySubsequences: false).count]
            if r.query["have"] != hash { o["text"] = v.text }
            if let p = v.prompt {
                o["question"] = p.question
                o["options"] = p.options.map { ["key": $0.key, "label": Prompt.short($0.label, max: 60)] }
            } else if let u = v.unread {
                o["unread"] = u
            }
            if let n = Notice.all().first(where: { $0.desk == name }) { o["notice"] = n.text; o["noticeAt"] = n.time }
            return .json(o)
        case ("POST", "/api/notice/clear"):
            // Taking a notice down acts on nothing in the desk: no Face ID.
            guard let name = fields(r.body)["desk"], host.inboxRows().contains(where: { $0.name == name }) else {
                return .json(["message": "No such desk."], status: 404)
            }
            return .json(["message": Notice.clear(desk: name) ? "Dismissed." : "It was already gone."])
        case ("POST", "/api/send"):
            let f = fields(r.body)
            if let no = needsFaceID(f) { return no }
            guard let name = f["desk"], let text = f["text"] else { return .json(["message": "Send needs a desk and text."], status: 400) }
            return answer(host.inboxSend(name, text: text))
        case ("POST", "/api/keys"):
            let f = fields(r.body)
            if let no = needsFaceID(f) { return no }
            guard let name = f["desk"], let k = f["key"], let bytes = keys[k] else {
                return .json(["message": "That isn't a key the inbox presses."], status: 400)
            }
            return answer(host.inboxPress(name, keys: bytes))
        case ("POST", "/api/open"):
            let f = fields(r.body)
            if let no = needsFaceID(f) { return no }
            guard let name = f["desk"] else { return .json(["message": "Open needs a desk."], status: 400) }
            return answer(host.inboxOpen(name))
        case ("POST", "/api/stop"):
            // Ends an agent, maybe mid-turn: Face ID, like anything that acts on a desk.
            let f = fields(r.body)
            if let no = needsFaceID(f) { return no }
            guard let name = f["desk"], host.inboxRows().contains(where: { $0.name == name }) else {
                return .json(["ok": false, "message": "No such desk."], status: 404)
            }
            let a = host.inboxStop(name)
            return .json(["ok": a.ok, "message": a.message])
        case ("POST", "/api/pin"):
            // Where a desk sits in the list, nothing in the desk: no Face ID.
            let f = fields(r.body)
            guard let name = f["desk"], host.inboxRows().contains(where: { $0.name == name }) else {
                return .json(["ok": false, "message": "No such desk."], status: 404)
            }
            let a = host.inboxPin(name, on: f["on"] != "false")
            return .json(["ok": a.ok, "message": a.message])
        case ("POST", "/api/upload"):
            // A photo for a desk to look at: saved on the Mac beside the
            // desk, under a name Coldfall makes, and the path handed back
            // for the message. Face ID, since it writes a file there.
            let f = fields(r.body)
            if let no = needsFaceID(f) { return no }
            guard let name = f["desk"], host.inboxRows().contains(where: { $0.name == name }) else {
                return .json(["ok": false, "message": "No such desk."], status: 404)
            }
            guard let b64 = f["data"], let data = Data(base64Encoded: b64), !data.isEmpty else {
                return .json(["ok": false, "message": "That photo didn't arrive whole."], status: 400)
            }
            guard data.count <= maxPhoto else { return .json(["ok": false, "message": "That photo is over 8 MB."], status: 413) }
            guard photoKind(data) != nil else { return .json(["ok": false, "message": "Only photos: JPEG, PNG, HEIC, GIF or WebP."], status: 400) }
            let place = host.inboxPhotoFolder(name)
            guard let folder = place.folder else { return .json(["ok": false, "message": place.message], status: 400) }
            guard let path = savePhoto(data, folder: folder) else {
                return .json(["ok": false, "message": "Couldn't save the photo in \(name)'s folder."], status: 500)
            }
            return .json(["ok": true, "path": path, "message": "Attached."])
        case ("POST", "/api/faceid/state"):
            let e = PhoneKey.expect(host: r.headers["host"] ?? "", secure: cameSecure(r))
            return .json(["required": PhoneKey.required, "pairing": PhoneKey.pairing(), "here": e != nil,
                          "ids": PhoneKey.keys().filter { $0.rpId == e?.rpId }.map(\.id)])
        case ("POST", "/api/faceid/begin"):
            guard let e = PhoneKey.expect(host: r.headers["host"] ?? "", secure: cameSecure(r)) else {
                return .json(["message": "Face ID needs the https address (Tailscale's serve), not this one."], status: 400)
            }
            return .json(["challenge": PhoneKey.challenge(), "rpId": e.rpId, "pairing": PhoneKey.pairing(),
                          "ids": PhoneKey.keys().filter { $0.rpId == e.rpId }.map(\.id)])
        case ("POST", "/api/faceid/register"):
            let f = fields(r.body)
            guard let e = PhoneKey.expect(host: r.headers["host"] ?? "", secure: cameSecure(r)),
                  let cd = f["clientDataJSON"], let att = f["attestationObject"] else {
                return .json(["ok": false, "message": PhoneKey.Failure.badData.message], status: 400)
            }
            switch PhoneKey.register(clientDataJSON: cd, attestationObject: att, expect: e) {
            case .success: return .json(["ok": true, "message": "Face ID is set up. Answering from a phone now asks for it."])
            case .failure(let why): return .json(["ok": false, "message": why.message], status: 403)
            }
        case ("POST", "/api/faceid/verify"):
            let f = fields(r.body)
            guard let e = PhoneKey.expect(host: r.headers["host"] ?? "", secure: cameSecure(r)),
                  let id = f["id"], let cd = f["clientDataJSON"], let ad = f["authenticatorData"], let sig = f["signature"] else {
                return .json(["ok": false, "message": PhoneKey.Failure.badData.message], status: 400)
            }
            switch PhoneKey.verify(id: id, clientDataJSON: cd, authenticatorData: ad, signature: sig, expect: e) {
            case .success(let t): return .json(["ok": true, "unlock": t, "seconds": Int(PhoneKey.unlockSeconds)])
            case .failure(let why): return .json(["ok": false, "message": why.message], status: 403)
            }
        case (_, "/"), (_, "/api/desks"), (_, "/api/read"), (_, "/api/send"), (_, "/api/keys"), (_, "/api/open"),
             (_, "/manifest.webmanifest"), (_, "/sw.js"), (_, "/api/push/state"), (_, "/api/push/subscribe"),
             (_, "/api/push/unsubscribe"), (_, "/api/push/test"), (_, "/api/faceid/state"), (_, "/api/faceid/begin"),
             (_, "/api/faceid/register"), (_, "/api/faceid/verify"), (_, "/api/notice/clear"), (_, "/api/stop"), (_, "/api/pin"),
             (_, "/api/upload"):
            return .text("Method not allowed.", status: 405)
        default:
            return .text("Not found.", status: 404)
        }
    }

    /// Bytes in, bytes out: the gate, then the route. What the app's socket
    /// calls once a whole request has arrived.
    public static func respond(_ r: Request, token: String, allowedHosts: [String], host: InboxHost,
                               funnelHost: String? = nil) -> Response {
        switch gate(r, token: token, allowedHosts: allowedHosts, funnelHost: funnelHost) {
        case .denied(let resp): return resp
        case .setCookie(let to):
            return Response(status: 302, headers: [cookieHeader(token, secure: cameSecure(r)), ("Location", to.isEmpty ? "/" : to)])
        case .allowed: return route(r, host: host, allowedHosts: allowedHosts)
        }
    }
}

/// Files only you can read: the inbox's secret, the phone sender's key, the
/// list of phones. Written owner-only from the first byte, so there is no
/// moment when another account on the Mac could read them.
public enum Secret {
    /// Makes the folder, yours alone, when it doesn't exist. An existing one
    /// is left as it is (~/.config/coldfall also holds desks.toml).
    public static func folder(_ path: String) {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// A folder that is only for secrets: yours alone, made or not.
    public static func privateFolder(_ path: String) {
        folder(path)
        ownerOnly(path, mode: 0o700)
    }

    /// Set the mode back if something loosened it.
    public static func ownerOnly(_ path: String, mode: Int = 0o600) {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let m = a[.posixPermissions] as? Int, m & 0o777 != mode else { return }
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    /// Writes `data` to `path` through a file created owner-only, then
    /// renamed into place (whole or not at all).
    @discardableResult
    public static func write(_ data: Data, to path: String) -> Bool {
        let tmp = path + ".tmp-\(getpid())-\(UInt32.random(in: 0 ... .max))"
        let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = Foundation.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        close(fd)
        guard ok, rename(tmp, path) == 0 else { unlink(tmp); return false }
        return true
    }
}
