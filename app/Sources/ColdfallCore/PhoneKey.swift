// Face ID before answering from the phone.
//
// The inbox's link is a secret, and anyone holding it could answer a desk's
// question, which can mean approving what an agent runs. A passkey closes
// that: the phone makes a key pair in its Secure Enclave, unlocked only by
// Face ID (or the phone's passcode), and gives Coldfall the public half.
// From then on answering, sending or starting a desk from a phone needs a
// fresh signature from that key: a leaked link alone answers nothing.
//
// - A phone is added only while pairing is open, which only Settings on the
//   Mac can do, for five minutes. So the link alone can't add its own key.
// - One Face ID unlocks answering for five minutes on that page.
// - This is WebAuthn with "none" attestation and ES256 keys, verified here
//   with CryptoKit. Passkeys need https (Tailscale's serve) or localhost.

import Foundation
import CryptoKit

public enum PhoneKey {

    // MARK: - what is kept

    public struct Key: Codable, Equatable {
        public var id: String          // credential id, base64url
        public var x: String           // P-256 public key, base64url
        public var y: String
        public var rpId: String        // the name the phone used (its https address)
        public var count: UInt32       // the authenticator's signature counter
        public var added: Double
    }

    nonisolated(unsafe) public static var path = (Inbox.tokenPath as NSString).deletingLastPathComponent + "/phone-keys.json"
    private static let lock = NSLock()

    public static func keys() -> [Key] {
        guard let d = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([Key].self, from: d)) ?? []
    }
    static func save(_ k: [Key]) -> Bool {
        guard let d = try? JSONEncoder().encode(k) else { return false }
        Secret.folder((path as NSString).deletingLastPathComponent)
        return Secret.write(d, to: path)
    }
    /// Answering needs Face ID once any phone has a key.
    public static var required: Bool { !keys().isEmpty }
    /// Forget every phone (Settings). Answering no longer asks.
    public static func forgetAll() { try? FileManager.default.removeItem(atPath: path) }

    // MARK: - pairing, challenges, unlocks (in memory)

    nonisolated(unsafe) private static var pairUntil = Date.distantPast
    nonisolated(unsafe) private static var challenges: [String: Date] = [:]
    nonisolated(unsafe) private static var unlocks: [String: Date] = [:]
    public static let pairMinutes = 5.0
    public static let unlockSeconds: TimeInterval = 300
    static let challengeSeconds: TimeInterval = 120

    /// Settings' "Set Up a Phone…": the next five minutes may add a key.
    public static func openPairing(now: Date = Date()) { lock.lock(); pairUntil = now.addingTimeInterval(pairMinutes * 60); lock.unlock() }
    public static func closePairing() { lock.lock(); pairUntil = .distantPast; lock.unlock() }
    public static func pairing(now: Date = Date()) -> Bool { lock.lock(); defer { lock.unlock() }; return now < pairUntil }
    public static func pairingLeft(now: Date = Date()) -> TimeInterval { lock.lock(); defer { lock.unlock() }; return max(0, pairUntil.timeIntervalSince(now)) }

    static func random(_ n: Int = 32) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return b64url(Data(b))
    }
    /// A one-time challenge for the phone to sign.
    public static func challenge(now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        challenges = challenges.filter { $0.value > now }
        if challenges.count > 64 { challenges.removeAll() }
        let c = random()
        challenges[c] = now.addingTimeInterval(challengeSeconds)
        return c
    }
    /// Used up on first use, whatever the outcome.
    static func take(_ c: String, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = challenges.removeValue(forKey: c) else { return false }
        return until > now
    }
    /// Whether this unlock (from a Face ID moments ago) still stands.
    public static func unlocked(_ ticket: String?, now: Date = Date()) -> Bool {
        guard let t = ticket, !t.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        unlocks = unlocks.filter { $0.value > now }
        return unlocks[t] != nil
    }
    static func grant(now: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        if unlocks.count > 64 { unlocks.removeAll() }
        let t = random()
        unlocks[t] = now.addingTimeInterval(unlockSeconds)
        return t
    }

    // MARK: - checking what the phone sent

    public enum Failure: Error, Equatable {
        case notPairing, badData, wrongType, staleChallenge, wrongOrigin, wrongName, noFaceID, unsupportedKey, unknownKey, badSignature, replayed
        public var message: String {
            switch self {
            case .notPairing: return "Adding a phone has to be started on the Mac: Settings, General, Face ID, Set Up a Phone."
            case .badData: return "That wasn't a passkey answer Coldfall can read."
            case .wrongType: return "That passkey answer was for something else."
            case .staleChallenge: return "That took too long, or was used already. Try again."
            case .wrongOrigin, .wrongName: return "That passkey answer came from another address."
            case .noFaceID: return "The phone didn't confirm it was you (Face ID or passcode)."
            case .unsupportedKey: return "This phone made a kind of key Coldfall doesn't take."
            case .unknownKey: return "This phone isn't set up for Face ID here. Set it up from Settings on the Mac."
            case .badSignature: return "The Face ID signature didn't check out."
            case .replayed: return "That signature was seen before."
            }
        }
    }

    /// What the page must send was made for: the address as the phone sees it.
    public struct Expect {
        public var origin: String       // "https://mac.tailnet.ts.net"
        public var rpId: String         // "mac.tailnet.ts.net"
        public init(origin: String, rpId: String) { self.origin = origin; self.rpId = rpId }
    }

    /// The address a request was made to, for checking its passkey answer.
    /// Nil for an IP address: passkeys don't work there.
    public static func expect(host hostHeader: String, secure: Bool) -> Expect? {
        let h = hostHeader.lowercased()
        let name = h.split(separator: ":").first.map(String.init) ?? h
        guard !name.isEmpty, name.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")) != nil else { return nil }
        if !secure && name != "localhost" { return nil }
        return Expect(origin: (secure ? "https://" : "http://") + h, rpId: name)
    }

    /// The client data every answer carries, checked.
    static func clientData(_ b64: String, type: String, expect e: Expect, now: Date) throws -> Data {
        guard let raw = unb64url(b64), let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw Failure.badData }
        guard o["type"] as? String == type else { throw Failure.wrongType }
        guard let c = o["challenge"] as? String, take(c, now: now) else { throw Failure.staleChallenge }
        guard o["origin"] as? String == e.origin else { throw Failure.wrongOrigin }
        return raw
    }

    /// Authenticator data: the name's hash and the flags, checked; the rest returned.
    static func authData(_ d: Data, rpId: String) throws -> (flags: UInt8, count: UInt32, rest: Data) {
        guard d.count >= 37 else { throw Failure.badData }
        let b = [UInt8](d)
        guard Data(b[0..<32]) == Data(SHA256.hash(data: Data(rpId.utf8))) else { throw Failure.wrongName }
        let flags = b[32]
        // User present (0x01) and verified (0x04): Face ID or the passcode, not a tap.
        guard flags & 0x01 != 0, flags & 0x04 != 0 else { throw Failure.noFaceID }
        let count = UInt32(b[33]) << 24 | UInt32(b[34]) << 16 | UInt32(b[35]) << 8 | UInt32(b[36])
        return (flags, count, Data(b[37...]))
    }

    /// Adding a phone: its new key, from `navigator.credentials.create`.
    public static func register(clientDataJSON: String, attestationObject: String, expect e: Expect,
                                now: Date = Date()) -> Result<Key, Failure> {
        do {
            guard pairing(now: now) else { throw Failure.notPairing }
            _ = try clientData(clientDataJSON, type: "webauthn.create", expect: e, now: now)
            guard let att = unb64url(attestationObject), case .map(let m)? = CBOR.decode(att),
                  case .bytes(let ad)? = m[.text("authData")] else { throw Failure.badData }
            let (flags, count, rest) = try authData(ad, rpId: e.rpId)
            guard flags & 0x40 != 0, rest.count >= 18 else { throw Failure.badData }      // a key follows
            let r = [UInt8](rest)
            let idLen = Int(r[16]) << 8 | Int(r[17])
            guard r.count >= 18 + idLen else { throw Failure.badData }
            let credId = Data(r[18..<(18 + idLen)])
            guard case .map(let cose)? = CBOR.decode(Data(r[(18 + idLen)...])),
                  cose[.int(1)] == .int(2), cose[.int(3)] == .int(-7), cose[.int(-1)] == .int(1),
                  case .bytes(let x)? = cose[.int(-2)], case .bytes(let y)? = cose[.int(-3)],
                  x.count == 32, y.count == 32,
                  (try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)) != nil else { throw Failure.unsupportedKey }
            let k = Key(id: b64url(credId), x: b64url(x), y: b64url(y), rpId: e.rpId, count: count, added: now.timeIntervalSince1970)
            lock.lock()
            var all = keys().filter { $0.id != k.id }
            all.append(k)
            let saved = save(all)
            pairUntil = .distantPast        // one phone per opening
            lock.unlock()
            return saved ? .success(k) : .failure(.badData)
        } catch let f as Failure { return .failure(f) } catch { return .failure(.badData) }
    }

    /// Face ID on a phone that has a key: an unlock good for five minutes.
    public static func verify(id: String, clientDataJSON: String, authenticatorData: String, signature: String,
                              expect e: Expect, now: Date = Date()) -> Result<String, Failure> {
        do {
            lock.lock(); let all = keys(); lock.unlock()
            guard let k = all.first(where: { $0.id == id }) else { throw Failure.unknownKey }
            guard k.rpId == e.rpId else { throw Failure.wrongName }
            let cd = try clientData(clientDataJSON, type: "webauthn.get", expect: e, now: now)
            guard let ad = unb64url(authenticatorData), let sigData = unb64url(signature) else { throw Failure.badData }
            let (_, count, _) = try authData(ad, rpId: e.rpId)
            guard let x = unb64url(k.x), let y = unb64url(k.y),
                  let pub = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y),
                  let sig = try? P256.Signing.ECDSASignature(derRepresentation: sigData) else { throw Failure.badSignature }
            guard pub.isValidSignature(sig, for: ad + Data(SHA256.hash(data: cd))) else { throw Failure.badSignature }
            // A counter that doesn't move on (Apple's passkeys always send 0) is fine;
            // one that goes backwards means a copied key.
            if count != 0 || k.count != 0 {
                guard count > k.count else { throw Failure.replayed }
                lock.lock()
                var updated = keys()
                if let i = updated.firstIndex(where: { $0.id == id }) { updated[i].count = count; _ = save(updated) }
                lock.unlock()
            }
            return .success(grant(now: now))
        } catch let f as Failure { return .failure(f) } catch { return .failure(.badData) }
    }

    // MARK: - base64url

    public static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    public static func unb64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

/// Just enough CBOR (RFC 8949) for a passkey: maps, arrays, integers, byte
/// and text strings, and simple values. Lengths are bounded by the input.
public indirect enum CBOR: Hashable {
    case int(Int), bytes(Data), text(String), array([CBOR]), map([CBOR: CBOR]), simple(UInt8)

    public static func decode(_ d: Data) -> CBOR? {
        var i = 0
        return item([UInt8](d), &i, depth: 0)
    }

    private static func item(_ b: [UInt8], _ i: inout Int, depth: Int) -> CBOR? {
        guard depth < 16, i < b.count else { return nil }
        let major = b[i] >> 5, info = b[i] & 0x1f
        i += 1
        var n: UInt64 = 0
        switch info {
        case 0..<24: n = UInt64(info)
        case 24, 25, 26, 27:
            let len = 1 << Int(info - 24)
            guard i + len <= b.count else { return nil }
            for _ in 0..<len { n = n << 8 | UInt64(b[i]); i += 1 }
        default: return nil       // no indefinite lengths in a passkey
        }
        switch major {
        case 0: return n <= UInt64(Int.max) ? .int(Int(n)) : nil
        case 1: return n < UInt64(Int.max) ? .int(-1 - Int(n)) : nil
        case 2, 3:
            guard n <= UInt64(b.count - i) else { return nil }
            let s = Data(b[i..<(i + Int(n))]); i += Int(n)
            if major == 2 { return .bytes(s) }
            guard let t = String(data: s, encoding: .utf8) else { return nil }
            return .text(t)
        case 4:
            guard n <= UInt64(b.count - i) else { return nil }
            var a: [CBOR] = []
            for _ in 0..<n { guard let x = item(b, &i, depth: depth + 1) else { return nil }; a.append(x) }
            return .array(a)
        case 5:
            guard n <= UInt64(b.count - i) else { return nil }
            var m: [CBOR: CBOR] = [:]
            for _ in 0..<n {
                guard let k = item(b, &i, depth: depth + 1), let v = item(b, &i, depth: depth + 1) else { return nil }
                m[k] = v
            }
            return .map(m)
        case 7: return info < 24 ? .simple(info) : nil
        default: return nil      // tags aren't used in a passkey
        }
    }

    /// The other way, for tests and for nothing else.
    public func encoded() -> Data {
        func head(_ major: UInt8, _ n: Int) -> Data {
            if n < 24 { return Data([major << 5 | UInt8(n)]) }
            if n < 256 { return Data([major << 5 | 24, UInt8(n)]) }
            if n < 65536 { return Data([major << 5 | 25, UInt8(n >> 8), UInt8(n & 0xff)]) }
            return Data([major << 5 | 26, UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        }
        switch self {
        case .int(let v): return v >= 0 ? head(0, v) : head(1, -1 - v)
        case .bytes(let d): return head(2, d.count) + d
        case .text(let s): return head(3, s.utf8.count) + Data(s.utf8)
        case .array(let a): return a.reduce(head(4, a.count)) { $0 + $1.encoded() }
        case .map(let m): return m.reduce(head(5, m.count)) { $0 + $1.key.encoded() + $1.value.encoded() }
        case .simple(let v): return Data([7 << 5 | v])
        }
    }
}
