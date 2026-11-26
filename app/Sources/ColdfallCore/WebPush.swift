import Foundation
// Not a UI framework: the standard's own cryptography, which is what makes
// this testable against the standard's worked example.
import CryptoKit

/// Notifications to a phone that has the inbox on its Home Screen.
///
/// The phone's browser subscribes with its maker's notification service
/// (Apple's for an iPhone) and hands the inbox an address there. When a desk
/// needs you, Coldfall posts a small message to that address, and the service
/// wakes the phone. This is Web Push: RFC 8030 for the post, RFC 8291 for the
/// encryption, RFC 8292 (VAPID) for saying who is sending.
///
/// It is the one place Coldfall calls out on its own, so it is narrow:
///
/// - Off unless turned on in Settings, and then only to devices that asked
///   from the inbox page, which needs the inbox's secret.
/// - Only to the notification services of the browser makers (see
///   `services`): a subscription can't point Coldfall at any other address.
/// - The message is encrypted for that one device; the service in the middle
///   sees when and how big, never what. The words shown are fixed: that a
///   desk needs you or is done, never which desk, never why. The desk's name
///   travels only inside the encrypted message, so tapping the notification
///   opens that desk; it isn't shown, on the lock screen or anywhere else.
/// - Nothing identifies you to the service. The sender's contact is the
///   project's public site, the same for every copy of Coldfall.
public enum WebPush {
    public static var root: String = ProcessInfo.processInfo.environment["COLDFALL_PUSH_DIR"]
        ?? NSString(string: "~/.local/share/coldfall/push").expandingTildeInPath
    static var keyPath: String { (root as NSString).appendingPathComponent("sender.key") }
    static var subsPath: String { (root as NSString).appendingPathComponent("devices.json") }

    /// Who is sending, as the services ask for it: a URL to reach the software's
    /// maker at. Never the person using it.
    public static let subject = "https://project-coldfall.vercel.app"
    public static let maxDevices = 8

    // MARK: - base64url

    public static func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func unb64(_ s: String) -> Data? {
        var t = s.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard t.count % 4 != 1 else { return nil }
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    // MARK: - where a device may ask to be reached

    /// The notification services of the browser makers, and their names.
    public static let services: [(suffix: String, name: String)] = [
        ("push.apple.com", "Apple"), ("fcm.googleapis.com", "Google"),
        ("push.services.mozilla.com", "Mozilla"), ("notify.windows.com", "Microsoft"),
    ]

    static func host(_ endpoint: String) -> String? {
        guard endpoint.utf8.count <= 2048, let u = URLComponents(string: endpoint), u.scheme == "https",
              u.user == nil, u.password == nil, u.port == nil || u.port == 443,
              let h = u.host?.lowercased(), !h.isEmpty else { return nil }
        return h
    }

    /// A subscription's address is used only if it is one of those services.
    /// Anything else would let whoever holds the inbox's secret make this Mac
    /// post to an address of their choosing.
    public static func endpointAllowed(_ endpoint: String) -> Bool { service(endpoint) != nil }

    /// "Apple", "Google"…, or nil for an address that isn't one of them.
    public static func service(_ endpoint: String) -> String? {
        guard let h = host(endpoint) else { return nil }
        return services.first { h == $0.suffix || h.hasSuffix("." + $0.suffix) }?.name
    }

    /// Who the signed note is for: the service's origin.
    public static func audience(_ endpoint: String) -> String? { host(endpoint).map { "https://" + $0 } }

    // MARK: - devices

    public struct Device: Codable, Equatable {
        public var endpoint: String
        /// The device's public key and shared secret, as the browser gave them.
        public var p256dh: String
        public var auth: String
        /// Where this device opens the inbox, for the link a notification opens.
        public var origin: String
        public var added: Double
        /// How the service answered the last send (201 is taken), and when.
        public var lastStatus: Int?
        public var lastAt: Double?
        /// The service's one word for a refusal ("BadJwtToken"), if it gave one.
        public var lastReason: String?
        public init(endpoint: String, p256dh: String, auth: String, origin: String, added: Double) {
            self.endpoint = endpoint; self.p256dh = p256dh; self.auth = auth; self.origin = origin; self.added = added
        }
    }

    public static func devices() -> [Device] {
        Secret.ownerOnly(subsPath)
        guard let d = FileManager.default.contents(atPath: subsPath) else { return [] }
        return (try? JSONDecoder().decode([Device].self, from: d)) ?? []
    }

    static func save(_ list: [Device]) {
        Secret.privateFolder(root)
        guard let d = try? JSONEncoder().encode(list) else { return }
        Secret.write(d, to: subsPath)
    }

    /// The inbox's own address as a device may give it: https at one of this
    /// Mac's names, or plain http on the Mac itself (for trying it out).
    public static func originAllowed(_ origin: String, hosts: [String]) -> Bool {
        guard let u = URLComponents(string: origin), let h = u.host?.lowercased(), hosts.contains(h),
              u.path.isEmpty, u.query == nil, u.fragment == nil, u.user == nil else { return false }
        if u.scheme == "https" { return true }
        return u.scheme == "http" && (h == "localhost" || h == "127.0.0.1")
    }

    /// Remember a device. Nil when it's kept; otherwise why not.
    public static func add(endpoint: String, p256dh: String, auth: String, origin: String, hosts: [String],
                           now: Double = Date().timeIntervalSince1970) -> String? {
        guard endpointAllowed(endpoint) else { return "That isn't a notification service Coldfall sends to." }
        guard let k = unb64(p256dh), k.count == 65, k.first == 4, (try? P256.KeyAgreement.PublicKey(x963Representation: k)) != nil,
              let a = unb64(auth), a.count == 16 else { return "That device's keys don't read." }
        guard originAllowed(origin, hosts: hosts) else { return "Notifications need the inbox opened at its https address." }
        var list = devices().filter { $0.endpoint != endpoint }
        guard list.count < maxDevices else { return "\(maxDevices) devices already get notifications. Forget some in Coldfall's Settings first." }
        list.append(Device(endpoint: endpoint, p256dh: p256dh, auth: auth, origin: origin, added: now))
        save(list)
        return nil
    }

    public static func remove(endpoint: String) { save(devices().filter { $0.endpoint != endpoint }) }
    public static func removeAll() { save([]) }

    /// Whether the service's answer means the device is gone for good (it
    /// unsubscribed, or the app was deleted): 404 and 410, per RFC 8030.
    public static func gone(_ status: Int) -> Bool { status == 404 || status == 410 }

    /// Keep how a send went. A device the service says is gone is forgotten.
    public static func note(endpoint: String, status: Int, reason: String? = nil, at: Double = Date().timeIntervalSince1970) {
        var list = devices()
        guard let i = list.firstIndex(where: { $0.endpoint == endpoint }) else { return }
        if gone(status) { list.remove(at: i) }
        else { list[i].lastStatus = status; list[i].lastAt = at; list[i].lastReason = reason }
        save(list)
    }

    /// The service's word for why it refused, from its answer: {"reason":"…"}.
    /// Kept only if it is one plain word, since it goes on the page.
    public static func reason(_ body: Data?) -> String? {
        guard let body, body.count <= 2048, let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let r = o["reason"] as? String, !r.isEmpty, r.count <= 40,
              r.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) }) else { return nil }
        return r
    }

    /// The last send, in words for the page.
    public static func lastWords(_ d: Device) -> String? {
        guard let s = d.lastStatus, let who = service(d.endpoint) else { return nil }
        if (200..<300).contains(s) { return "\(who) took the last one." }
        if s == 0 { return "The last one didn't reach \(who): this Mac couldn't connect." }
        return "\(who) refused the last one (\(s)\(d.lastReason.map { ", " + $0 } ?? ""))."
    }

    // MARK: - the sender's key

    /// This Mac's signing key, made on first use. Devices subscribe against its
    /// public half, so losing it means each device turns notifications on again.
    public static func signingKey() -> P256.Signing.PrivateKey? {
        if let raw = try? String(contentsOfFile: keyPath, encoding: .utf8), let d = unb64(raw),
           let k = try? P256.Signing.PrivateKey(rawRepresentation: d) {
            Secret.privateFolder(root)
            Secret.ownerOnly(keyPath)
            return k
        }
        let k = P256.Signing.PrivateKey()
        Secret.privateFolder(root)
        guard Secret.write(Data(b64(k.rawRepresentation).utf8), to: keyPath) else { return nil }
        return k
    }

    /// The public half, as a browser's subscribe() takes it.
    public static func publicKey() -> String? { signingKey().map { b64($0.publicKey.x963Representation) } }

    // MARK: - saying who sends (VAPID, RFC 8292)

    /// A signed note for one service, good for twelve hours.
    public static func jwt(audience: String, key: P256.Signing.PrivateKey, now: Double) -> String? {
        func part(_ o: [String: Any]) -> String? {
            (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).map(b64)
        }
        guard let h = part(["typ": "JWT", "alg": "ES256"]),
              let c = part(["aud": audience, "exp": Int(now) + 12 * 3600, "sub": subject]),
              let sig = try? key.signature(for: Data((h + "." + c).utf8)) else { return nil }
        return h + "." + c + "." + b64(sig.rawRepresentation)
    }

    private static var notes: [String: (jwt: String, made: Double)] = [:]

    /// The Authorization header. The note is reused for a few hours: the
    /// services ask senders not to mint a new one for every message.
    public static func authorization(endpoint: String, key: P256.Signing.PrivateKey, now: Double) -> String? {
        guard let aud = audience(endpoint) else { return nil }
        let pub = b64(key.publicKey.x963Representation)
        let id = aud + " " + pub
        if let n = notes[id], now - n.made < 6 * 3600, now >= n.made { return "vapid t=\(n.jwt), k=\(pub)" }
        guard let t = jwt(audience: aud, key: key, now: now) else { return nil }
        notes[id] = (t, now)
        return "vapid t=\(t), k=\(pub)"
    }

    // MARK: - encryption (RFC 8291, aes128gcm)

    /// The message, sealed for one device. `salt` is 16 random bytes and
    /// `sender` a key made for this message alone; both are parameters so the
    /// standard's worked example can be checked byte for byte.
    public static func encrypt(_ plain: Data, p256dh: Data, auth: Data, salt: Data,
                               sender: P256.KeyAgreement.PrivateKey) -> Data? {
        guard salt.count == 16, auth.count == 16, plain.count <= 3900,
              let device = try? P256.KeyAgreement.PublicKey(x963Representation: p256dh),
              let shared = try? sender.sharedSecretFromKeyAgreement(with: device) else { return nil }
        let senderPublic = sender.publicKey.x963Representation
        let secret = shared.withUnsafeBytes { Data($0) }
        let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: auth,
                                         info: Data("WebPush: info\u{0}".utf8) + p256dh + senderPublic, outputByteCount: 32)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                         info: Data("Content-Encoding: aes128gcm\u{0}".utf8), outputByteCount: 16)
        let nonceKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                              info: Data("Content-Encoding: nonce\u{0}".utf8), outputByteCount: 12)
        let nonceBytes = nonceKey.withUnsafeBytes { Data($0) }
        // One record, so it ends with the last-record mark.
        guard let nonce = try? AES.GCM.Nonce(data: nonceBytes),
              let box = try? AES.GCM.seal(plain + Data([2]), using: key, nonce: nonce) else { return nil }
        // salt, record size 4096, the sender's public key and its length.
        return salt + Data([0, 0, 16, 0, UInt8(senderPublic.count)]) + senderPublic + box.ciphertext + box.tag
    }

    // MARK: - what is sent

    public enum Kind: String { case needs, done, test }

    /// Title and body. Fixed words: a notification can show on a locked
    /// screen, and passes (sealed) through someone else's service.
    public static func text(_ k: Kind) -> (title: String, body: String) {
        switch k {
        case .needs: return ("A desk needs you", "It's waiting for your answer.")
        case .done: return ("A desk is done", "It finished while you were away.")
        case .test: return ("Coldfall can reach this device", "Notifications are working.")
        }
    }

    /// A short stand-in for a desk's name, different on every Mac, so a newer
    /// notification about a desk replaces the older one without naming it.
    public static func topic(desk: String, publicKey: String) -> String {
        String(b64(Data(SHA256.hash(data: Data(("coldfall:" + publicKey + ":" + desk).utf8)))).prefix(24))
    }

    /// The message itself, in the declarative form (the device shows it
    /// without running the page's code); the page's worker reads the same
    /// form on browsers that hand it over instead.
    public static func payload(_ kind: Kind, desk: String?, origin: String, waiting: Int, topic: String?) -> Data {
        let t = text(kind)
        var open = origin + "/"
        if let d = desk, let e = d.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { open += "#desk=" + e }
        var n: [String: Any] = ["title": t.title, "body": t.body, "navigate": open, "lang": "en", "silent": false]
        if let topic { n["tag"] = topic }
        if kind != .test { n["app_badge"] = String(max(0, waiting)) }
        let o: [String: Any] = ["web_push": 8030, "notification": n]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }

    public struct Outgoing: Equatable {
        public var url: String
        public var headers: [String: String]
        public var body: Data
    }

    /// One post to one device's service, ready to send.
    public static func outgoing(to d: Device, kind: Kind, desk: String?, waiting: Int, key: P256.Signing.PrivateKey,
                                now: Double = Date().timeIntervalSince1970) -> Outgoing? {
        guard endpointAllowed(d.endpoint), let dh = unb64(d.p256dh), let auth = unb64(d.auth),
              let authz = authorization(endpoint: d.endpoint, key: key, now: now) else { return nil }
        let topic = desk.map { self.topic(desk: $0, publicKey: b64(key.publicKey.x963Representation)) }
        var salt = [UInt8](repeating: 0, count: 16)
        guard Inbox.SecRandom(&salt),
              let body = encrypt(payload(kind, desk: desk, origin: d.origin, waiting: waiting, topic: topic),
                                 p256dh: dh, auth: auth, salt: Data(salt), sender: P256.KeyAgreement.PrivateKey()) else { return nil }
        var h = ["Authorization": authz, "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream",
                 // Held four hours for a phone that's off, then dropped: old news.
                 "TTL": "14400", "Urgency": kind == .needs ? "high" : "normal"]
        if let topic { h["Topic"] = topic }
        return Outgoing(url: d.endpoint, headers: h, body: body)
    }
}

/// When a phone hears about a desk.
///
/// A phone is for when you're away, so nothing is sent while you're at the
/// Mac: the rail and the Mac's own banner already said it. Once the Mac has
/// gone untouched for `awayAfter`, each report still standing is sent once.
/// That also covers the desk that finished a moment before you walked off.
public enum PhoneRule {
    public static let awayAfter: TimeInterval = 120

    /// - event: when the agent made the report the state rests on.
    /// - alerted: the report this desk's phone notice last went out for.
    /// - idle: how long the Mac has gone without a key or the mouse.
    /// - endedAsked: the turn that last ended was one you asked for.
    public static func decide(activity: DeskActivity, signaled: Bool, endedAsked: Bool, event: Date?, alerted: Date?,
                              idle: TimeInterval, now: Date = Date()) -> WebPush.Kind? {
        guard signaled, idle >= awayAfter, let event, event != alerted else { return nil }
        switch activity {
        case .blocked: return .needs
        case .ready: return .done
        case .quiet:
            // The desk left on screen reads as quiet when it finishes, because
            // you could see it. You couldn't if you'd already gone: done, if
            // the Mac hasn't been touched since.
            return endedAsked && now.addingTimeInterval(-idle) < event ? .done : nil
        case .working: return nil
        }
    }
}
