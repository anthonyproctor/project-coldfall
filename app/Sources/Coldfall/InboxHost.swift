import AppKit
import ColdfallCore

/// The controller's side of the inbox: desks, screens, and the same rules
/// `coldfall-cli send` follows. Always on the main thread.
extension Controller: InboxHost {
    static func activityWord(_ a: DeskActivity?) -> String {
        switch a { case .working?: return "working"; case .ready?: return "ready"; case .blocked?: return "blocked"; default: return "quiet" }
    }

    func inboxRows() -> [Inbox.Row] {
        desks.filter { !$0.hidden }.map { d in
            let s = sessions[d.name]
            let running = s?.started ?? false
            return Inbox.Row(name: d.name, group: d.group, runtime: d.runtime, running: running,
                             activity: Controller.activityWord(s?.activity), lastOutput: s?.lastOutput?.timeIntervalSince1970,
                             detail: running ? s?.detailLine : nil, pinned: d.pinned,
                             asleep: !running && ui.sleeping.contains(d.name), memory: running ? memory[d.name] : nil)
        }
    }

    func inboxDesk(_ name: String, lines: Int) -> Inbox.DeskView? {
        guard let d = desks.first(where: { $0.name == name }), !d.hidden else { return nil }
        let s = sessions[name]
        let running = s?.started ?? false
        let asking = s?.isBlocked == true
        let prompt = asking ? s.flatMap { choices(of: $0, on: $0.screenText(lines: 60)) } : nil
        return Inbox.DeskView(text: running ? (s?.screenText(lines: lines) ?? "") : "", running: running,
                              activity: Controller.activityWord(s?.activity), runtime: d.runtime == "shell" ? "shell" : d.vendorLabel,
                              agent: running && !(s?.agentGone ?? true) && d.runtime != "shell",
                              prompt: prompt,
                              unread: asking && prompt == nil ? s.flatMap { PromptCheck.note(stamp(of: $0), read: ui.choicesRead) } : nil)
    }

    private func inboxTarget(_ name: String) -> RemoteOpen.Target? { sessions[name]?.remoteTarget() }

    func inboxSend(_ name: String, text: String) -> RemoteOpen.Answer {
        let hidden = Set(desks.filter(\.hidden).map(\.name))
        if let no = RemoteOpen.refuseSend(name, names: desks.map(\.name), hidden: hidden, target: inboxTarget(name), text: text) {
            return no
        }
        sessions[name]?.typeOnBehalf(RemoteOpen.keystrokes(text))
        return RemoteOpen.Answer(.sent, "Sent.")
    }

    func inboxPress(_ name: String, keys: [UInt8]) -> RemoteOpen.Answer {
        if desks.first(where: { $0.name == name })?.hidden == true { return RemoteOpen.Answer(.hiddenDesk, "\(name) is hidden in Coldfall.") }
        guard let s = sessions[name], s.agentAlive() else { return RemoteOpen.Answer(.notRunning, "\(name) isn't running.") }
        guard s.isBlocked else { return RemoteOpen.Answer(.notAsking, "\(name) isn't asking anything right now.") }
        s.typeOnBehalf(keys)
        return RemoteOpen.Answer(.pressed, "Pressed.")
    }

    func inboxStop(_ name: String) -> (ok: Bool, message: String) {
        guard let d = desks.first(where: { $0.name == name }), !d.hidden else { return (false, "No such desk.") }
        guard let s = sessions[name], s.started else { return (false, "\(name) isn't running.") }
        endDesk(d)
        refreshRail()
        return (true, "Stopped \(name). Its conversation picks up when you start it again.")
    }

    func inboxPin(_ name: String, on: Bool) -> (ok: Bool, message: String) {
        guard let i = desks.firstIndex(where: { $0.name == name }), !desks[i].hidden else { return (false, "No such desk.") }
        pinDesk(i, on)
        return (true, on ? "Pinned \(name) to the top." : "Unpinned \(name).")
    }

    func inboxPhotoFolder(_ name: String) -> (folder: String?, message: String) {
        guard let d = desks.first(where: { $0.name == name }), !d.hidden else { return (nil, "No such desk.") }
        guard d.runtime != "shell" else { return (nil, "\(name) is a plain terminal, with no agent to look at a photo.") }
        // An agent on another machine can't open a file on this one.
        if let c = d.command?.trimmingCharacters(in: .whitespaces), c.hasPrefix("ssh ") || c == "ssh" {
            return (nil, "\(name) runs on another machine, so it can't open a photo saved on this Mac.")
        }
        return (d.resolvedCwd, "")
    }

    func inboxOpen(_ name: String) -> RemoteOpen.Answer {
        let running = Set(sessions.filter { $0.value.started || $0.value.resolving || $0.value.holding }.keys)
        let a = RemoteOpen.decide(name, names: desks.map(\.name), hidden: Set(desks.filter(\.hidden).map(\.name)), running: running)
        if a.outcome == .started { openRemotely(name, show: false) }
        return a
    }

    // MARK: - as an app on a phone

    /// The mark (the two pipes of the app's icon) on a square with no
    /// corners of its own: a phone's Home Screen cuts the corners itself, and
    /// the Mac icon's rounded tile would sit inside that as a tile in a tile.
    func inboxIcon(_ size: Int) -> Data? {
        // Drawn once per size: anyone on the tailnet can ask for it without
        // the link, and each drawing is work on the main thread.
        if let png = Controller.inboxIcons[size] { return png }
        let png = drawInboxIcon(size)
        Controller.inboxIcons[size] = png
        return png
    }
    static var inboxIcons: [Int: Data] = [:]

    private func drawInboxIcon(_ size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let whole = NSRect(x: 0, y: 0, width: size, height: size)
        NSGradient(starting: NSColor(srgbRed: 0.094, green: 0.094, blue: 0.110, alpha: 1),
                   ending: NSColor(srgbRed: 0.172, green: 0.172, blue: 0.192, alpha: 1))?.draw(in: whole, angle: 90)
        // The svg draws on 1024 with the tile 834 wide; here the tile is the
        // whole square, so the mark grows by the same ratio about the middle.
        let k = CGFloat(size) / 834
        func pipe(x: CGFloat, top: CGFloat) -> NSBezierPath {
            let r = NSRect(x: (x - 512) * k + CGFloat(size) / 2, y: (512 - (top + 430)) * k + CGFloat(size) / 2,
                           width: 87 * k, height: 430 * k)
            return NSBezierPath(roundedRect: r, xRadius: 43.5 * k, yRadius: 43.5 * k)
        }
        NSColor(srgbRed: 0.416, green: 0.804, blue: 0.388, alpha: 1).setFill()
        // Spaced as in the app's own icon (a pipe's width apart).
        pipe(x: 382, top: 251).fill()
        pipe(x: 555, top: 343).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    func inboxPushOn() -> Bool { ui.pushOn }

    func inboxPushTest(_ endpoint: String) -> String {
        guard ui.pushOn else { return "Phone notifications are off in Coldfall's Settings on the Mac." }
        phonePush.send(.test, desk: nil, waiting: 0, only: endpoint)
        return "Sent. It should arrive in a few seconds."
    }

    // MARK: - on and off

    func applyInbox() {
        if ui.inboxOn, !CommandLine.arguments.contains("--snapshot") {
            if inboxServer == nil {
                inboxServer = InboxServer(host: self)
                // Settings shows the https link once Tailscale has answered.
                inboxServer?.onFacts = { NotificationCenter.default.post(name: .coldfallInboxFacts, object: nil) }
            }
            let now = Inbox.tailscaleAddresses() + ["127.0.0.1"]
            // A port held by something else is tried again after a while, not
            // every five seconds (see InboxServer.shouldStart).
            if inboxServer?.shouldStart(addresses: now) == true { inboxServer?.start() }
        } else {
            inboxServer?.stop()
        }
    }
}
