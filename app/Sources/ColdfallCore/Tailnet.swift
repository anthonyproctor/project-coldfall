import Foundation

/// Machines on the Mac's Tailscale network, offered as desks beside the hosts
/// from ~/.ssh/config.
///
/// Read only: the things ever run are `tailscale status --json` and
/// `tailscale serve status --json`. Nothing here changes a tailnet setting,
/// and nothing is kept; the list is read when Settings asks for it.
///
/// A machine's name comes from whoever owns that machine (a node shared in
/// from someone else's tailnet is in the list too), and it ends up in a shell
/// command. So a name is used only if it is a plain DNS name, and the address
/// only if it is a plain IPv4 address; anything else is not offered.
public struct TailnetMachine: Equatable {
    /// The short name: the first label of the MagicDNS name.
    public let name: String
    /// What ssh connects to: the full MagicDNS name, or the address without one.
    public let target: String
    public let os: String
    public let online: Bool

    public init(name: String, target: String, os: String, online: Bool) {
        self.name = name; self.target = target; self.os = os; self.online = online
    }

    /// Phones and TVs are on the network but there is nothing to ssh into.
    public var takesSSH: Bool { !["ios", "android", "tvos"].contains(os.lowercased()) }

    public var command: String { "ssh -t \(Shell.quote(target))" }

    public var blurb: String {
        "tailscale · \(Tailnet.osName(os)) · \(online ? "online" : "offline")"
    }
}

public enum Tailnet {
    /// Where the command lives: the Mac app's own copy first, then the usual
    /// places a standalone install puts it.
    public static let cliPaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    public static func cli(exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        cliPaths.first(where: exists)
    }

    /// A DNS name safe to hand to ssh: labels of letters, digits and hyphens,
    /// never starting with a hyphen (ssh would read that as an option).
    public static func plainName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253 else { return false }
        return s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard let first = label.unicodeScalars.first, label.count <= 63 else { return false }
            let ok: (Unicode.Scalar) -> Bool = {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
            }
            return first != "-" && label.unicodeScalars.allSatisfy(ok)
        }
    }

    public static func plainIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isASCII) && p.allSatisfy(\.isNumber) && Int(p).map { $0 <= 255 } == true
        }
    }

    public static func osName(_ os: String) -> String {
        switch os.lowercased() {
        case "macos": return "macOS"
        case "ios": return "iOS"
        case "tvos": return "tvOS"
        case "linux": return "Linux"
        case "windows": return "Windows"
        case "android": return "Android"
        case "": return "unknown"
        default: return os
        }
    }

    /// The other machines in `tailscale status --json`: not this Mac, not one
    /// whose key has expired, not one with no usable name or address. Online
    /// first, then by name.
    public static func parse(_ data: Data) -> [TailnetMachine] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = root["Peer"] as? [String: Any] else { return [] }
        var out: [TailnetMachine] = []
        for case let p as [String: Any] in peers.values {
            if p["Expired"] as? Bool == true { continue }
            var dns = (p["DNSName"] as? String ?? "")
            while dns.hasSuffix(".") { dns.removeLast() }
            let ip = (p["TailscaleIPs"] as? [String] ?? []).first(where: plainIPv4)
            let target: String
            if plainName(dns), dns.contains(".") { target = dns.lowercased() }
            else if let ip { target = ip }
            else { continue }
            let short = dns.split(separator: ".").first.map(String.init).flatMap { plainName($0) ? $0.lowercased() : nil }
            out.append(TailnetMachine(name: short ?? target, target: target,
                                      os: p["OS"] as? String ?? "", online: p["Online"] as? Bool ?? false))
        }
        return out.sorted {
            $0.online != $1.online ? $0.online : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Ask Tailscale. Empty when it isn't installed, isn't running, or takes
    /// longer than a couple of seconds. Not for the main thread.
    public static func machines(timeout: TimeInterval = 3) -> [TailnetMachine] {
        ask(["status", "--json"], timeout: timeout).map(parse) ?? []
    }

    /// One read-only question to the tailscale command. Not for the main thread.
    static func ask(_ arguments: [String], timeout: TimeInterval) -> Data? {
        guard let path = cli() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let r = Subprocess.drain(p, out: out, err: err, timeout: timeout)
        return r.timedOut ? nil : r.out
    }

    // MARK: - the inbox over HTTPS

    /// This Mac's own name on the tailnet (its MagicDNS name), from
    /// `tailscale status --json`. The inbox answers to it as well as to the
    /// address: it is the name Tailscale's HTTPS serves under.
    public static func selfName(_ status: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
              let me = root["Self"] as? [String: Any], var dns = me["DNSName"] as? String else { return nil }
        while dns.hasSuffix(".") { dns.removeLast() }
        return plainName(dns) && dns.contains(".") ? dns.lowercased() : nil
    }

    /// The inbox as Tailscale serves it over HTTPS, if it does.
    public struct Served: Equatable {
        /// "https://name.tailnet.ts.net", with a port only when it isn't 443.
        public var url: String
        public var host: String
        /// Tailscale Funnel is on for it: reachable from the whole internet.
        public var funnel: Bool
        public init(url: String, host: String, funnel: Bool) { self.url = url; self.host = host; self.funnel = funnel }
    }

    /// Reads `tailscale serve status --json` for an HTTPS name whose whole
    /// site goes to the inbox's port on this Mac. Set up by the person, with
    /// `tailscale serve --bg <port>`; Coldfall only looks.
    public static func served(_ status: Data, port: UInt16) -> Served? {
        guard let root = try? JSONSerialization.jsonObject(with: status) as? [String: Any] else { return nil }
        // A serve left running in a terminal sits under Foreground instead.
        var configs = [root]
        for case let f as [String: Any] in (root["Foreground"] as? [String: Any] ?? [:]).values { configs.append(f) }
        // As Tailscale keeps a target: a full address, host and port, or the port alone.
        let targets = ["127.0.0.1:\(port)", "localhost:\(port)", "\(port)"]
        // Every entry that reaches the inbox: the first gives its address, and
        // Funnel on any of them counts (each is the inbox, open to the internet).
        var found: Served?
        var anyFunnel = false
        for c in configs {
            let funnel = c["AllowFunnel"] as? [String: Any] ?? [:]
            for (hostPort, web) in (c["Web"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let handlers = (web as? [String: Any])?["Handlers"] as? [String: Any],
                      let rootHandler = handlers["/"] as? [String: Any], var to = rootHandler["Proxy"] as? String else { continue }
                while to.hasSuffix("/") { to.removeLast() }
                if to.hasPrefix("http://") { to.removeFirst(7) }
                guard targets.contains(to) else { continue }
                let parts = hostPort.split(separator: ":")
                guard parts.count == 2, plainName(String(parts[0])), let p = Int(parts[1]) else { continue }
                let host = parts[0].lowercased()
                if funnel[hostPort] as? Bool == true { anyFunnel = true }
                if found == nil { found = Served(url: "https://" + host + (p == 443 ? "" : ":\(p)"), host: host, funnel: false) }
            }
        }
        found?.funnel = anyFunnel
        return found
    }

    /// What the inbox needs to know from Tailscale, asked once. Not for the
    /// main thread.
    public static func inboxFacts(port: UInt16, timeout: TimeInterval = 3) -> (name: String?, served: Served?) {
        (ask(["status", "--json"], timeout: timeout).flatMap(selfName),
         ask(["serve", "status", "--json"], timeout: timeout).flatMap { served($0, port: port) })
    }

    /// The one command that puts the inbox behind Tailscale's HTTPS, for the
    /// person to run. Coldfall never runs it.
    public static func serveCommand(port: UInt16, cli path: String? = cli()) -> String {
        Shell.quote(path ?? "tailscale") + " serve --bg \(port)"
    }

    /// The machines worth offering as a desk: ones that take ssh, that no desk
    /// already connects to, and that ~/.ssh/config doesn't already name (that
    /// entry is the better offer: it carries the user and the key).
    public static func undesked(_ machines: [TailnetMachine], desks: [Desk], ssh: [SSHHost]) -> [TailnetMachine] {
        let names = Set(desks.map { $0.name.lowercased() })
        let commands = desks.compactMap { $0.command?.lowercased() }
        let known = Set(ssh.flatMap { [$0.alias, $0.hostName ?? ""] }.map { $0.lowercased() })
        return machines.filter { m in
            guard m.takesSSH else { return false }
            let ids = [m.name, m.target]
            if ids.contains(where: names.contains) || ids.contains(where: known.contains) { return false }
            return !commands.contains { c in ids.contains { mentions(c, $0) } }
        }
    }

    /// Whether a command names this host as a whole word: "ssh pi" names
    /// "pi", "ssh pipeline" does not.
    static func mentions(_ command: String, _ host: String) -> Bool {
        let stops = CharacterSet(charactersIn: " \t'\"@:")
        return command.components(separatedBy: stops).contains(host)
    }

    public static func desk(from m: TailnetMachine) -> Desk {
        Desk(name: m.name, cwd: NSHomeDirectory(), command: m.command, group: "remote")
    }
}
