import AppKit
import ColdfallCore

/// The meter: a strip along the bottom of the window showing where the week is
/// going, across vendors. Scanning happens off the main thread and is throttled,
/// so the bar never costs anything while you work.
final class MeterBar: NSView {
    private let summary = NSTextField(labelWithString: "reading usage…")
    private let hint = NSTextField(labelWithString: "")
    private var lastScan = Date.distantPast
    private var timer: Timer?
    var onClick: (() -> Void)?
    /// Which desk is on screen. Context belongs to it, not to the vendor.
    var currentDesk: String? {
        didSet {
            guard currentDesk != oldValue else { return }
            // Only the desk line changes: redraw from the last report rather
            // than re-reading every transcript on every cmd-1..9.
            if let (r, since) = lastRender { render(r, since: since) } else { refresh() }
        }
    }
    private var lastRender: (Usage.Report, Date)?

    override func mouseDown(with e: NSEvent) { onClick?() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.ui.status.cgColor

        summary.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        summary.textColor = Theme.ui.text
        hint.font = .systemFont(ofSize: 11, weight: .semibold)
        hint.textColor = .labelColor          // adapts; orange on light grey was unreadable
        hint.lineBreakMode = .byTruncatingTail
        hint.wantsLayer = true
        hint.layer?.cornerRadius = 4
        hint.drawsBackground = false

        let stack = NSStackView(views: [summary, NSView(), hint])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // 999, not required: cmd-J collapses the meter with a REQUIRED zero
        // height, and two required heights that disagree leave AppKit to break
        // one at random. This way the collapse simply wins while it is on.
        let h = heightAnchor.constraint(equalToConstant: 26)
        h.priority = NSLayoutConstraint.Priority(999)
        h.isActive = true

        refresh()
        timer = Timer.inEveryMode(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.0fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1e3) }
        return "\(n)"
    }

    func refresh() {
        guard Date().timeIntervalSince(lastScan) > 30 else { return }
        lastScan = Date()
        let since = Usage.weekStart()
        DispatchQueue.global(qos: .utility).async {
            let r = Usage.scan(since: since, accounts: ClaudeAccount.known())
            DispatchQueue.main.async { self.render(r, since: since) }
        }
    }

    /// Made-up numbers for a snapshot, shown instead of real usage.
    private var demo: (summary: String, hint: String)?
    func showDemo(summary s: String, hint h: String) {
        demo = (s, h)
        summary.stringValue = s
        hint.stringValue = h
        hint.textColor = .labelColor
    }

    /// Each fresh report, for whoever else reads the week (desk budgets).
    var onReport: ((Usage.Report) -> Void)?

    private func render(_ r: Usage.Report, since: Date) {
        lastRender = (r, since)
        onReport?(r)
        if demo != nil { return }
        var segs: [String] = []
        let limits = Limits.all()

        // Quota first, per vendor. This is the number that changes behaviour.
        for l in limits.sorted(by: { ($0.liveWeekPct ?? 0) > ($1.liveWeekPct ?? 0) }) {
            var s = l.vendor
            if let w = l.liveWeekPct {
                s += String(format: " wk %.0f%%", w)
                if let ra = l.weekResetsAt {
                    let f = DateFormatter(); f.dateFormat = "EEE h a"
                    s += "→" + f.string(from: Date(timeIntervalSince1970: ra)).lowercased()
                }
            }
            if let h = l.liveFiveHourPct { s += String(format: " · 5h %.0f%%", h) }
            if let a = l.ageLabel { s += " (\(a))" }
            segs.append(s)
        }

        // Then consumption, for whoever has no quota signal.
        for (v, b) in r.byVendor.sorted(by: { $0.value.tokens > $1.value.tokens }) {
            if limits.contains(where: { $0.vendor == v }) { continue }
            var s = "\(v) \(fmt(b.tokens))"
            if let usd = b.usd { s += String(format: " $%.0f", usd) }
            if v == "copilot", let p = r.copilotPremium { s += String(format: " · %.0f req this month", p) }
            segs.append(s)
        }

        // The visible desk's own context and spend, which is per session.
        if let d = currentDesk, let st = DeskState.load(d) {
            var s = d
            if let m = st.model { s += " " + m.replacingOccurrences(of: "Claude ", with: "")
                                            .replacingOccurrences(of: " (1M context)", with: "") }
            if let e = st.effort { s += "·" + e }
            if let c = st.ctxPct { s += String(format: "  ctx %.0f%%", c) }
            if let u = st.usd, u > 0 { s += String(format: "  $%.2f", u) }
            segs.append(s)
        }

        if segs.isEmpty { segs = ["no usage recorded this week"] }
        summary.stringValue = segs.joined(separator: "     ")

        // The router: only speak when there is a real gap to act on.
        if let call = Self.routerCall(limits) {
            hint.stringValue = call
            hint.textColor = .labelColor
        } else if let pace = Self.paceCall(limits) {
            hint.stringValue = pace
            hint.textColor = .labelColor
        } else if limits.isEmpty && !Limits.recorderInstalled {
            hint.stringValue = "plan limits off — turn on in Settings"
            hint.textColor = .secondaryLabelColor
        } else if let h = Usage.routerHint(r) {
            hint.stringValue = h
            hint.textColor = .labelColor
        } else {
            hint.stringValue = ""
        }
    }

    /// With real quota on both sides the router stops guessing from token share
    /// and says the actionable thing: who is nearly out, who has room.
    static func routerCall(_ ls: [VendorLimits]) -> String? {
        let withWeek = ls.compactMap { l -> (String, Double)? in l.liveWeekPct.map { (l.vendor, $0) } }
        guard withWeek.count >= 2 else {
            // The pace line says more (when it runs out), so it speaks instead.
            if let one = withWeek.first, one.1 >= 75, paceCall(ls) == nil {
                return String(format: "%@ has used %.0f%% of its week.", one.0, one.1)
            }
            return nil
        }
        let sorted = withWeek.sorted { $0.1 > $1.1 }
        guard let hot = sorted.first, let cold = sorted.last else { return nil }
        if hot.1 >= 60 && hot.1 - cold.1 >= 25 {
            return String(format: "%@ %.0f%% used, %@ only %.0f%% — send the next one to %@.",
                          hot.0, hot.1, cold.0, cold.1, cold.0)
        }
        if hot.1 >= 90 {
            return String(format: "%@ is at %.0f%%.", hot.0, hot.1)
        }
        return nil
    }

    /// The vendor running out soonest before its reset, if any is (WeekPace).
    static func paceCall(_ ls: [VendorLimits]) -> String? {
        let readings = ls.compactMap { l -> (String, WeekPace.Reading)? in
            guard let w = l.liveWeekPct, let r = l.weekResetsAt,
                  let p = WeekPace.assess(usedPct: w, resetsAt: Date(timeIntervalSince1970: r)) else { return nil }
            return (l.vendor, p)
        }
        guard let soonest = readings.min(by: { $0.1.runsOutAt < $1.1.runsOutAt }) else { return nil }
        return WeekPace.line(vendor: soonest.0, soonest.1)
    }

    /// Repaint after a light/dark flip.
    func restyle() {
        layer?.backgroundColor = Theme.ui.status.cgColor
        summary.textColor = Theme.ui.text
        needsDisplay = true
    }
}
