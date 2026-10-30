import AppKit
import ColdfallCore

/// Click the meter to open this: quota per vendor, then where it went.
final class MeterPanel: NSWindowController {
    private let stack = NSStackView()
    /// The scrolling content, for `--usage`: a snapshot of the window itself
    /// would stop at the window's height and miss everything below the fold.
    private(set) var content: NSView?
    private var report = Usage.Report()
    /// Desks with a weekly budget, read when the window opens.
    private var budgetDesks: [Desk] = []
    /// When the numbers were read, and for which week, so reopening the
    /// window later rescans instead of showing last week under a new date.
    private var scannedAt = Date.distantPast
    private var scannedSince = Date.distantPast

    /// One window, three questions: what is left, where it went this week,
    /// and why. They were one column, and the answer you wanted was always
    /// three scrolls away.
    enum Tab: Int, CaseIterable {
        case plans, week, why
        var title: String {
            switch self {
            case .plans: return "Plans"
            case .week:  return "This week"
            case .why:   return "Where it went"
            }
        }
        /// For `--usage <name>`.
        static func named(_ s: String) -> Tab? {
            let want = s.lowercased()
            return Tab.allCases.first { $0.title.lowercased().contains(want) }
        }
    }
    private(set) var tab: Tab = .plans
    private let picker = NSSegmentedControl()
    /// Scanned once when the window opens; switching tabs redraws from this
    /// rather than reading 800MB of transcripts again.
    private var tokens = Tokenomics()
    private var servers: [String: Int] = [:]
    private var scanned = false
    private var since = Usage.weekStart()

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.init(window: w)
        w.title = "Usage"
        w.backgroundColor = Theme.ui.editor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        // An NSStackView used as a documentView has no size of its own. Without
        // these it lays out at zero and the window renders blank.
        // AppKit lays out from the bottom unless the documentView is flipped,
        // which is why the content sat at the foot of an empty window.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        picker.segmentStyle = .automatic
        picker.trackingMode = .selectOne
        picker.segmentCount = Tab.allCases.count
        for t in Tab.allCases {
            picker.setLabel(t.title, forSegment: t.rawValue)
            picker.setWidth(150, forSegment: t.rawValue)
        }
        picker.selectedSegment = tab.rawValue
        picker.target = self
        picker.action = #selector(tabPicked)
        picker.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(picker)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(header)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            picker.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            picker.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        w.contentView = root
        content = doc
        w.center()
        reload()
    }

    private func caps(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: TextStyle.sentence(s))
        l.font = .systemFont(ofSize: 12, weight: .medium); l.textColor = .secondaryLabelColor
        return l
    }
    private func mono(_ s: String, _ size: CGFloat = 11.5, _ w: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .monospacedSystemFont(ofSize: size, weight: w)
        return l
    }
    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1e3) }
        return "\(n)"
    }
    /// A bar drawn in text keeps this readable in both themes with no colour tricks.
    /// Swift-native padding. String(format: "%-8s", ...) needs a C string and
    /// silently emits garbage when handed a Swift String — that is where the
    /// `¯ÊH˘` in the first build came from.
    private func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
    private func lpad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }

    private func bar(_ pct: Double, width: Int = 34) -> String {
        let f = max(0, min(width, Int((pct / 100.0 * Double(width)).rounded())))
        return String(repeating: "█", count: f) + String(repeating: "░", count: width - f)
    }

    func reload() {
        since = Usage.weekStart()
        // Rescan when the week rolled over or the last scan is a while old.
        if scanned, since != scannedSince || Date().timeIntervalSince(scannedAt) > 120 { scanned = false }
        draw()
        guard !scanned else { return }
        stack.addArrangedSubview(caps("SCANNING…"))
        let since = self.since
        DispatchQueue.global(qos: .userInitiated).async {
            let accounts = ClaudeAccount.known()
            let r = Usage.scan(since: since, accounts: accounts)
            let t = Tokenomics.scan(since: since, accounts: accounts)
            // How many MCP servers each desk starts, so the advice can point
            // at the ones a desk doesn't need.
            // Keyed by the title the desk's conversation carries, which is
            // what the usage records are keyed by.
            let desks = DeskConfig.load()
            var servers: [String: Int] = [:]
            for d in desks where d.runtime == "claude" || d.runtime == "codex" {
                let n = Inventory.of(d).mcp.filter { !$0.off }.count
                if n > 0 { servers[Reopen.title(of: d)] = n }
            }
            let budgeted = desks.filter { $0.budget != nil }
            DispatchQueue.main.async {
                self.report = r
                self.tokens = t
                self.servers = servers
                self.budgetDesks = budgeted
                self.scanned = true
                self.scannedAt = Date()
                self.scannedSince = since
                self.draw()
            }
        }
    }

    @objc private func tabPicked() {
        guard let t = Tab(rawValue: picker.selectedSegment) else { return }
        show(t)
    }

    /// Switch tabs. Nothing is re-read: the scan is already in hand.
    func show(_ t: Tab) {
        tab = t
        picker.selectedSegment = t.rawValue
        draw()
    }

    private func draw() {
        stack.subviews.forEach { $0.removeFromSuperview() }
        switch tab {
        case .plans: drawPlans()
        case .week:  if scanned { renderUsage(since: since) } else { stack.addArrangedSubview(caps("SCANNING…")) }
        case .why:   if scanned { renderTokenomics(tokens, servers: servers) } else { stack.addArrangedSubview(caps("SCANNING…")) }
        }
    }

    /// What is left of each plan: the number that changes what you do next.
    private func drawPlans() {
        let df = DateFormatter(); df.dateFormat = "EEE h a"
        stack.addArrangedSubview(caps("PLAN REMAINING"))
        let limits = Limits.all()
        if limits.isEmpty {
            stack.addArrangedSubview(mono("no live quota — turn it on in Settings"))
        }
        for l in limits.sorted(by: { ($0.liveWeekPct ?? 0) > ($1.liveWeekPct ?? 0) }) {
            var line = pad(l.vendor, 15)
            if let w = l.liveWeekPct {
                line += "week  \(bar(w))  " + String(format: "%5.1f%%", w)
                if let r = l.weekResetsAt {
                    line += "  resets " + df.string(from: Date(timeIntervalSince1970: r)).lowercased()
                }
            }
            if l.liveWeekPct == nil && l.liveFiveHourPct == nil {
                line += "no live window — reading is from a cycle that has reset"
            }
            if let p = l.planType { line += "   (\(p))" }
            if let a = l.ageLabel { line += "   \(a)" }
            stack.addArrangedSubview(mono(line, 12, .medium))
            if let h = l.liveFiveHourPct {
                var s = pad("", 9) + "5h    \(bar(h))  " + lpad(String(format: "%.1f%%", h), 6)
                if let r = l.fiveHourResetsAt {
                    let m = Int(max(0, Date(timeIntervalSince1970: r).timeIntervalSinceNow) / 60)
                    s += "  \(m / 60)h\(String(format: "%02d", m % 60))m"
                }
                let f = mono(s); f.textColor = .secondaryLabelColor
                stack.addArrangedSubview(f)
            }
        }
        if let call = MeterBar.routerCall(limits) {
            let c = NSTextField(labelWithString: "→ " + call)
            c.font = .systemFont(ofSize: 12, weight: .semibold)
            stack.addArrangedSubview(c)
        }
        let note = NSTextField(wrappingLabelWithString:
            "Claude and Codex report what is left of a plan; the other vendors keep it on their own "
          + "side, so they appear under This week as consumption only.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = 700
        stack.addArrangedSubview(caps(""))
        stack.addArrangedSubview(note)
    }

    private func renderUsage(since: Date) {
        let df = DateFormatter(); df.dateFormat = "EEE h a"
        let total = report.byVendor.values.reduce(0) { $0 + $1.tokens }

        stack.addArrangedSubview(caps("THIS WEEK, SINCE \(df.string(from: since))"))
        for (v, b) in report.byVendor.sorted(by: { $0.value.tokens > $1.value.tokens }) {
            let share = total > 0 ? Double(b.tokens) / Double(total) * 100 : 0
            var s = pad(v, 15) + lpad(fmt(b.tokens), 9) + " tokens  "
                  + bar(share, width: 20) + lpad(String(format: "%.1f%%", share), 7)
            if let usd = b.usd { s += String(format: "   $%.0f", usd) }
            stack.addArrangedSubview(mono(s))
        }
        if report.byVendor.isEmpty { stack.addArrangedSubview(mono("nothing recorded this week")) }
        if let p = report.copilotPremium {
            stack.addArrangedSubview(mono(pad("copilot", 15) + String(format: "%9.0f premium requests this month", p)
                + "  (your plan's allowance is on github.com, not on this Mac)"))
        }

        // ---- per desk: only Claude names its sessions, so say so rather than
        // silently showing a partial picture.
        if !report.byDesk.isEmpty {
            stack.addArrangedSubview(caps("BY DESK  (claude sessions that were given a name)"))
            let deskTotal = report.byDesk.values.reduce(0) { $0 + $1.tokens }
            for (d, b) in report.byDesk.sorted(by: { $0.value.tokens > $1.value.tokens }).prefix(15) {
                let share = deskTotal > 0 ? Double(b.tokens) / Double(deskTotal) * 100 : 0
                var s = pad(d, 15) + lpad(fmt(b.tokens), 9) + "  "
                      + bar(share, width: 18) + lpad(String(format: "%.1f%%", share), 7)
                      + lpad("\(b.calls)", 7) + " calls"
                if let usd = b.usd { s += String(format: "  $%.0f", usd) }
                // Against its weekly budget, for a desk that has one.
                let desk = budgetDesks.first { ($0.conversation ?? $0.name) == d }
                let st = DeskBudget.status(spent: b.usd, budget: desk?.budget)
                if let cap = desk?.budget { s += String(format: " of $%.0f", cap) }
                let line = mono(s)
                if case .over = st { line.textColor = .systemRed }
                if case .near = st { line.textColor = .systemOrange }
                stack.addArrangedSubview(line)
            }
        }

        // ---- last 14 days
        stack.addArrangedSubview(caps("EACH DAY THIS WEEK"))
        let days = report.byDay.keys.sorted().suffix(14)
        let peak = report.byDay.values.map { $0.values.reduce(0, +) }.max() ?? 1
        let fin = DateFormatter(); fin.dateFormat = "yyyy-MM-dd"
        let fout = DateFormatter(); fout.dateFormat = "EEE dd"
        for k in days {
            let byV = report.byDay[k] ?? [:]
            let t = byV.values.reduce(0, +)
            let label = fin.date(from: k).map { fout.string(from: $0) } ?? k
            let width = max(1, Int(Double(t) / Double(peak) * 44))
            let breakdown = byV.sorted { $0.value > $1.value }
                .map { "\($0.key) \(fmt($0.value))" }.joined(separator: " · ")
            stack.addArrangedSubview(mono(
                pad(label, 8) + pad(String(repeating: "▇", count: width), 46) + " " + breakdown))
        }

        let foot = NSTextField(wrappingLabelWithString:
            "Read from files the CLIs already write. Claude records are deduplicated on message.id — "
          + "a streamed reply is written more than once and counting every record roughly doubles the total. "
          + "Dollar figures are Claude list prices; no price is guessed for other vendors. "
          + "Copilot counts a premium request per turn you start, times the model's multiplier.")
        foot.font = .systemFont(ofSize: 10.5)
        foot.textColor = .tertiaryLabelColor
        foot.preferredMaxLayoutWidth = 760
        stack.addArrangedSubview(caps(""))
        stack.addArrangedSubview(foot)
    }

    /// Where the week went, and what to change about it. The numbers are the
    /// same records the rest of this panel reads; the difference is that this
    /// half is about cause.
    private func renderTokenomics(_ t: Tokenomics, servers: [String: Int]) {
        guard t.all.turns > 0 else { return }
        stack.addArrangedSubview(caps("WHERE IT WENT"))

        stack.addArrangedSubview(mono(
            pad("turns", 15) + lpad("\(t.all.turns)", 9)
            + "   " + String(format: "%.0f%% of input read from cache, at a small fraction of the price",
                             t.cacheReadShare * 100)))
        if !t.modelMix.isEmpty {
            let mix = t.modelMix.filter { $0.share >= 0.01 }
                .map { String(format: "%@ %.0f%%", $0.model, $0.share * 100) }
                .joined(separator: " · ")
            stack.addArrangedSubview(mono(pad("models", 15) + mix))
        }
        if t.all.usd > 0 {
            stack.addArrangedSubview(mono(
                pad("this week", 15) + String(format: "$%.0f", t.all.usd)
                + String(format: "   ·   estimate: the same tokens on Sonnet, about $%.0f", t.savingsOnSonnet())))
        }

        // What each desk pays before it says anything.
        let floors = t.byDesk.filter { $0.value.turns >= 5 && $0.value.floor > 0 }
            .sorted { $0.value.floor > $1.value.floor }.prefix(6)
        if !floors.isEmpty {
            stack.addArrangedSubview(caps("SMALLEST TURN OF THE WEEK, PER DESK"))
            for (name, s) in floors {
                var line = pad(name, 15) + lpad(Tokenomics.short(s.floor), 9) + " tokens"
                if let n = servers[name] { line += "   \(n) MCP server\(n == 1 ? "" : "s")" }
                stack.addArrangedSubview(mono(line))
            }
        }

        // What's filling the conversations: tool output, by desk.
        let filling = t.byDesk.filter { $0.value.toolTotal > 0 }
            .sorted { $0.value.toolTotal > $1.value.toolTotal }.prefix(6)
        if !filling.isEmpty {
            stack.addArrangedSubview(caps("WHAT'S FILLING THE CONVERSATIONS  (tool output, estimated)"))
            for (name, s) in filling {
                let top = s.toolTokens.filter { $0.key != Tokenomics.subagentKind }
                    .sorted { $0.value > $1.value }.first
                var line = pad(name, 15) + lpad(Tokenomics.short(s.toolTotal), 9)
                if let (k, _) = top { line += "   mostly \(k)" }
                line += s.subagents > 0 ? "   · \(s.subagents) subagent\(s.subagents == 1 ? "" : "s")" : "   · no subagents"
                stack.addArrangedSubview(mono(line))
            }
        }

        // Coming back to a big conversation after its cache lapsed.
        let rebuilt = t.byDesk.filter { $0.value.rebuilds > 0 }
            .sorted { $0.value.rebuildUsd > $1.value.rebuildUsd }.prefix(6)
        if !rebuilt.isEmpty {
            stack.addArrangedSubview(caps("COMING BACK AFTER A BREAK  (the cache lasts an hour; rebuilding it costs 20 to 40 times a warm turn)"))
            for (name, s) in rebuilt {
                stack.addArrangedSubview(mono(
                    pad(name, 15) + lpad("\(s.rebuilds)", 9) + (s.rebuilds == 1 ? " time " : " times")
                    + String(format: "   about $%.0f", s.rebuildUsd)))
            }
        }

        let notes = t.notes(servers: servers)
        guard !notes.isEmpty else { return }
        stack.addArrangedSubview(caps("WHAT TO CHANGE"))
        for n in notes {
            let head = NSTextField(wrappingLabelWithString: (n.measured ? "" : "estimate — ") + n.finding)
            head.font = .systemFont(ofSize: 12.5, weight: .semibold)
            head.textColor = n.measured ? .labelColor : .secondaryLabelColor
            head.preferredMaxLayoutWidth = 760
            stack.addArrangedSubview(head)
            let body = NSTextField(wrappingLabelWithString: n.advice)
            body.font = .systemFont(ofSize: 12)
            body.textColor = .secondaryLabelColor
            body.preferredMaxLayoutWidth = 760
            stack.addArrangedSubview(body)
        }
    }
}


/// AppKit's default coordinate system puts the origin at the bottom left, so an
/// unflipped documentView stacks its content upward from the foot of the window.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
