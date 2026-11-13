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
            return Inbox.Row(name: d.name, group: d.group, runtime: d.runtime, running: s?.started ?? false,
                             activity: Controller.activityWord(s?.activity), lastOutput: s?.lastOutput?.timeIntervalSince1970,
                             detail: s?.started == true ? s?.detailLine : nil)
        }
    }

    func inboxDesk(_ name: String, lines: Int) -> Inbox.DeskView? {
        guard let d = desks.first(where: { $0.name == name }), !d.hidden else { return nil }
        let s = sessions[name]
        let running = s?.started ?? false
        return Inbox.DeskView(text: running ? (s?.screenText(lines: lines) ?? "") : "", running: running,
                              activity: Controller.activityWord(s?.activity), runtime: d.runtime == "shell" ? "shell" : d.vendorLabel,
                              agent: running && !(s?.agentGone ?? true) && d.runtime != "shell",
                              prompt: s?.isBlocked == true ? Prompt.parse(screen: s?.screenText(lines: 60) ?? "") : nil)
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

    func inboxOpen(_ name: String) -> RemoteOpen.Answer {
        let running = Set(sessions.filter { $0.value.started || $0.value.resolving || $0.value.holding }.keys)
        let a = RemoteOpen.decide(name, names: desks.map(\.name), hidden: Set(desks.filter(\.hidden).map(\.name)), running: running)
        if a.outcome == .started { openRemotely(name, show: false) }
        return a
    }

    // MARK: - on and off

    func applyInbox() {
        if ui.inboxOn, !CommandLine.arguments.contains("--snapshot") {
            if inboxServer == nil { inboxServer = InboxServer(host: self) }
            let now = Inbox.tailscaleAddresses() + ["127.0.0.1"]
            if !(inboxServer?.isRunning ?? false) || inboxServer?.addresses != now { inboxServer?.start() }
        } else {
            inboxServer?.stop()
        }
    }
}
