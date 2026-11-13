import AppKit
import ColdfallCore

/// Runs the daily update check (see ColdfallCore/UpdateCheck.swift for what
/// it sends and why) and tells the title strip when a release is out.
final class Updates {
    /// Called with the newer version, or nil when there is none.
    var onChange: ((String?) -> Void)?
    private var timer: Timer?
    private var inFlight = false

    /// The newer release to point at, if the last reply named one.
    var available: (version: String, url: String?)? {
        let s = UpdateState.load()
        guard let l = s.latest, UpdateCheck.isNewer(l, than: SelfUpdate.version) else { return nil }
        return (l, s.latestURL.flatMap(UpdateCheck.releaseURL))
    }

    /// A first run shows the check on the Welcome screen, with its switch,
    /// and nothing is sent until that screen is done. An install from before
    /// the check existed is not stopped with a dialog: like most apps, it is
    /// disclosed in the README, the release notes and Settings, and off is
    /// one click away there.
    func start(firstRun: Bool) {
        onChange?(available?.version)
        var s = UpdateState.load()
        if !firstRun, !s.noticeShown { s.noticeShown = true; s.save() }
        // Hourly look at whether a day has passed; the check itself is daily.
        timer = Timer.inEveryMode(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkIfDue() }
    }

    func checkIfDue() {
        guard !inFlight, UpdateCheck.due(UpdateState.load()), let url = URL(string: UpdateCheck.endpoint) else { return }
        inFlight = true
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = UpdateCheck.body(UpdateState.load(), appVersion: SelfUpdate.version)
        // No cookies, no cache: the request is the three fields and nothing else.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        URLSession(configuration: cfg).dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                // Offline or the server is down: say nothing, try next hour.
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                      let reply = UpdateCheck.parse(data) else { return }
                var s = UpdateState.load()
                s.lastCheck = Date()
                s.latest = reply.latest
                s.latestURL = reply.url
                s.save()
                self.onChange?(self.available?.version)
            }
        }.resume()
    }

    func openRelease() {
        let fallback = "https://github.com/anthonyproctor/project-coldfall/releases/latest"
        if let u = URL(string: available?.url ?? fallback) { NSWorkspace.shared.open(u) }
    }
}
