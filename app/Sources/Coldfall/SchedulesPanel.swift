import AppKit
import ColdfallCore

/// Schedules: prompts sent to desks at set times (see Schedule).
///
/// The schedules live in a file you edit, as shortcuts do; this window
/// shows what the file says, what each one last did, and runs one now.
final class SchedulesPanel: NSObject {
    private let panel: NSPanel
    private let heading = NSTextField(labelWithString: "Schedules")
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let edit = NSButton(title: "Edit Schedules…", target: nil, action: nil)
    var deskNames: (() -> [String])?
    /// Run this schedule now, whatever the time.
    var onRunNow: ((Schedule) -> Void)?

    var isOpen: Bool { panel.isVisible }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 480, height: 300)
        let ui = Theme.ui
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = ui.editor.cgColor
        panel.contentView = root
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = ui.text
        note.font = .systemFont(ofSize: 11.5)
        note.textColor = ui.dimText
        note.stringValue = "A schedule sends its prompt the way you would. A run is skipped, and says so, when the desk is "
            + "asking something, you're typing in it, or it isn't running. Nothing runs while Coldfall is closed; a time "
            + "that passes then is recorded as missed, not run late."
        edit.target = self; edit.action = #selector(editFile)
        edit.bezelStyle = .rounded
        let refresh = NSButton(title: "Reload", target: self, action: #selector(reload))
        refresh.bezelStyle = .rounded
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let foot = NSStackView(views: [note, refresh, edit])
        foot.orientation = .horizontal
        foot.alignment = .bottom
        foot.spacing = 10
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [heading, scroll, foot] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: foot.topAnchor, constant: -10),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor, constant: 2),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -8),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -6),
            foot.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            foot.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            foot.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
    }

    func open(over window: NSWindow) {
        let f = window.frame
        let w = min(720, f.width * 0.62), h = min(560, f.height * 0.74)
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        reload()
    }
    func close() { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }

    /// For --snapshot.
    func show(_ schedules: [Schedule], runs: [Schedule.Run], desks: [String], size: NSSize) {
        panel.setContentSize(size)
        render(schedules, runs: runs, desks: desks, broken: false)
        panel.contentView?.layoutSubtreeIfNeeded()
    }
    var contentView: NSView? { panel.contentView }

    @objc func reload() {
        render(Schedule.load(), runs: Schedule.runs(), desks: deskNames?() ?? [], broken: Schedule.broken())
    }

    private func render(_ schedules: [Schedule], runs: [Schedule.Run], desks: [String], broken: Bool) {
        for v in list.arrangedSubviews { list.removeArrangedSubview(v); v.removeFromSuperview() }
        let ui = Theme.ui
        func line(_ s: String, color: NSColor = ui.dimText) -> NSTextField {
            let t = NSTextField(wrappingLabelWithString: s)
            t.font = .systemFont(ofSize: 12.5)
            t.textColor = color
            return t
        }
        if broken {
            list.addArrangedSubview(line("schedules.json can't be read as schedules. Open it with Edit Schedules… and check its commas and quotes; nothing runs until it reads.", color: .systemRed))
            return
        }
        if schedules.isEmpty {
            list.addArrangedSubview(line("No schedules yet. Edit Schedules… opens the file with one example in it, switched off."))
            return
        }
        heading.stringValue = "Schedules  ·  \(schedules.count)"
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        for sc in schedules {
            let last = runs.last { $0.name == sc.name }
            let card = ScheduleCard(sc, problem: sc.problem(desks: desks),
                                    last: last.map { "\($0.outcome.words), \(df.string(from: Date(timeIntervalSince1970: $0.at)))" + ($0.note.map { ". \($0)" } ?? "") })
            card.onRun = { [weak self] in self?.onRunNow?(sc); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.reload() } }
            list.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    @objc private func editFile() {
        let p = Schedule.path
        if !FileManager.default.fileExists(atPath: p) {
            try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? Schedule.template.write(toFile: p, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }
}

private final class ScheduleCard: NSView {
    var onRun: (() -> Void)?
    init(_ sc: Schedule, problem: String?, last: String?) {
        super.init(frame: .zero)
        let ui = Theme.ui
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = ui.border.cgColor
        layer?.backgroundColor = ui.sidebar.cgColor
        let name = NSTextField(labelWithString: sc.name)
        name.font = .systemFont(ofSize: 13.5, weight: .semibold)
        name.textColor = sc.isOn ? ui.text : ui.dimText
        let when = NSTextField(labelWithString: "\(sc.desk)  ·  \(sc.when)" + (sc.isOn ? "" : "  ·  off"))
        when.font = .systemFont(ofSize: 12)
        when.textColor = ui.dimText
        let run = NSButton(title: "Run Now", target: self, action: #selector(runIt))
        run.bezelStyle = .rounded
        run.controlSize = .small
        run.isEnabled = problem == nil
        let head = NSStackView(views: [name, when, NSView(), run])
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.spacing = 10
        let prompt = NSTextField(wrappingLabelWithString: sc.prompt)
        prompt.font = .systemFont(ofSize: 12.5)
        prompt.textColor = ui.text.withAlphaComponent(0.85)
        prompt.maximumNumberOfLines = 3
        var rules: [String] = []
        if let p = sc.precheck, !p.trimmingCharacters(in: .whitespaces).isEmpty { rules.append("only if `\(p)` succeeds") }
        if let q = sc.skipOverWeekPct { rules.append("skipped past \(Int(q))% of the week") }
        var views: [NSView] = [head, prompt]
        if !rules.isEmpty {
            let r = NSTextField(labelWithString: rules.joined(separator: "  ·  "))
            r.font = .systemFont(ofSize: 11.5); r.textColor = ui.dimText
            views.append(r)
        }
        let foot = NSTextField(wrappingLabelWithString: problem ?? (last.map { "Last: \($0)" } ?? "Hasn't run yet."))
        foot.font = .systemFont(ofSize: 11.5)
        foot.textColor = problem != nil ? .systemRed : ui.dimText
        views.append(foot)
        let col = NSStackView(views: views)
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            head.widthAnchor.constraint(equalTo: col.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }
    @objc private func runIt() { onRun?() }
}
