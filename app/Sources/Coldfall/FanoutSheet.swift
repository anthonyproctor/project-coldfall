// Fan out one question across several directories at once.
//
// The interesting part of this sheet is not the list of checkboxes, it is the
// two numbers above the Run button: how many slices, and what they will cost
// against the vendor's real remaining week. Coldfall is the only thing in the
// loop that knows that number, and a fan-out that quietly spends the rest of
// your week is a bug rather than a feature.
//
// The second thing it does is tighten the privacy boundary rather than widen
// it. One responder pointed at a whole tree reads everything; twelve
// responders each pointed at one subdirectory read one twelfth each. Slicing
// is the safer shape, and the sheet says so.

import AppKit
import ColdfallCore

final class FanoutSheet: NSWindowController {

    private var root: String
    private let rt: Bridge.Runtime
    private let box: Mailbox
    private let fromName: String
    private let question: String
    private var onDone: (String, String) -> Void = { _, _ in }

    private var rows: [(dir: String, check: NSButton)] = []
    private let rootLabel = NSTextField(labelWithString: "")
    private let listStack = NSStackView()
    private let exposureLine = NSTextField(wrappingLabelWithString: "")
    private let budgetLine = NSTextField(labelWithString: "")
    private let adviceLine = NSTextField(wrappingLabelWithString: "")
    private let runBtn = NSButton()
    private let spinner = NSProgressIndicator()
    private let progress = NSTextField(labelWithString: "")

    // Live state for the run. All N processes launch at once, so every slice is
    // "running" from the first moment and the only thing that changes for
    // minutes is the clock — which is exactly why there has to BE a clock. A
    // spinner that never moves is indistinguishable from a hang.
    private enum SliceState { case waiting, running, done, failed }
    private var state: [String: SliceState] = [:]
    private var startedAt: [String: Date] = [:]
    private var finishedAt: [String: Date] = [:]
    private var ticker: Timer?
    private var mergeRow: NSTextField?
    private var mergeStarted: Date?
    /// Live handle on the running processes. Cancel used to close the window
    /// and leave them running invisibly, which is worse than no button at all.
    private var live: FanoutCancel?

    /// Directories that are never worth a slice: build output, dependencies and
    /// version control. Sending an agent into `node_modules` costs a full
    /// invocation to be told there is nothing there.
    private static let skip: Set<String> = [
        "node_modules", ".git", ".build", "build", "dist", "target", ".next",
        "vendor", "Pods", ".venv", "venv", "__pycache__", ".cache", "DerivedData",
    ]

    init(root: String, runtime: Bridge.Runtime, box: Mailbox, from: String,
         question: String, onDone: @escaping (String, String) -> Void) {
        self.root = root
        self.rt = runtime
        self.box = box
        self.fromName = from
        self.question = question
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 580),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: w)
        self.onDone = onDone
        w.title = "Fan out across directories"
        build()
    }
    required init?(coder: NSCoder) { nil }

    private func candidates() -> [String] {
        let fm = FileManager.default
        let kids = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        return kids.filter { name in
            guard !name.hasPrefix("."), !FanoutSheet.skip.contains(name) else { return false }
            var isDir: ObjCBool = false
            let p = (root as NSString).appendingPathComponent(name)
            return fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    private func build() {
        guard let w = window else { return }
        let dirs = candidates()

        _ = dirs
        let head = NSTextField(wrappingLabelString:
            "Ask \(rt.name) the same question of each directory separately, then once "
            + "more with every answer as context.")
        head.font = .systemFont(ofSize: 11.5)
        head.textColor = .secondaryLabelColor

        // The root is the privacy boundary, so it is shown and it is changeable.
        // Defaulting to the desk's cwd is right for a desk that sits on one
        // project and badly wrong for a desk that sits on a home directory —
        // and the sheet cannot tell which it has.
        rootLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        rootLabel.lineBreakMode = .byTruncatingMiddle
        let pick = NSButton(title: "Choose…", target: self, action: #selector(chooseRoot))
        pick.bezelStyle = .rounded
        pick.controlSize = .small
        let rootRow = NSStackView(views: [lbl("IN"), rootLabel, NSView(), pick])
        rootRow.orientation = .horizontal
        rootRow.distribution = .gravityAreas

        exposureLine.font = .systemFont(ofSize: 11)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 3
        let list = listStack

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 4),
            list.trailingAnchor.constraint(lessThanOrEqualTo: flipped.trailingAnchor),
            flipped.bottomAnchor.constraint(greaterThanOrEqualTo: list.bottomAnchor, constant: 4),
        ])
        scroll.documentView = flipped

        budgetLine.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        adviceLine.font = .systemFont(ofSize: 11.5)
        adviceLine.textColor = .secondaryLabelColor
        progress.font = .systemFont(ofSize: 11.5)
        progress.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        runBtn.title = "Run"
        runBtn.bezelStyle = .rounded
        runBtn.keyEquivalent = "\r"
        runBtn.target = self
        runBtn.action = #selector(run)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelRun))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let all = NSButton(title: "All", target: self, action: #selector(selectAll_))
        let none = NSButton(title: "None", target: self, action: #selector(selectNone))
        for b in [all, none] { b.bezelStyle = .inline; b.controlSize = .small }

        let buttons = NSStackView(views: [all, none, NSView(), spinner, progress, cancel, runBtn])
        buttons.orientation = .horizontal
        buttons.distribution = .gravityAreas

        let stack = NSStackView(views: [head, rootRow, scroll, exposureLine,
                                        budgetLine, adviceLine, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rootRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            exposureLine.widthAnchor.constraint(equalTo: stack.widthAnchor),
            adviceLine.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        reloadList()
    }

    private func lbl(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 10, weight: .semibold)
        t.textColor = .tertiaryLabelColor
        return t
    }

    /// Re-read the root's subdirectories. Called on open and whenever the root
    /// changes, so the checkbox list and the exposure warning never describe a
    /// directory other than the one that will actually be read.
    private func reloadList() {
        for v in listStack.arrangedSubviews { v.removeFromSuperview() }
        rows.removeAll()
        rootLabel.stringValue = (root as NSString).abbreviatingWithTildeInPath

        let dirs = candidates()
        for d in dirs {
            let b = NSButton(checkboxWithTitle: d, target: self, action: #selector(recount))
            b.state = .on
            listStack.addArrangedSubview(b)
            rows.append((d, b))
        }
        if dirs.isEmpty {
            listStack.addArrangedSubview(NSTextField(labelWithString:
                "No subdirectories here to slice across."))
        }

        // A home or workspace root is almost never what was meant, and getting
        // it wrong hands another vendor everything you own. Say so loudly
        // rather than relying on the person to read the paths.
        let home = NSHomeDirectory()
        let broad = root == home
            || dirs.count > 12
            || dirs.contains(where: { ["Documents", "Desktop", "Library", "documents"].contains($0) })
        if broad && !rt.isLocal {
            exposureLine.stringValue = "\(rt.name) would read every file under this whole "
                + "tree. That is almost certainly wider than you meant — point it at one "
                + "project."
            exposureLine.textColor = .systemRed
        } else if rt.isLocal {
            exposureLine.stringValue = "\(rt.name) runs on this machine; nothing is sent to a vendor."
            exposureLine.textColor = .secondaryLabelColor
        } else {
            exposureLine.stringValue = "Each slice reads only its own directory, so this "
                + "exposes less than one question pointed at the whole tree."
            exposureLine.textColor = .secondaryLabelColor
        }
        recount()
    }

    @objc private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: root)
        panel.prompt = "Use as root"
        panel.message = "Pick the directory to slice across. "
            + "Everything under it is readable by \(rt.name)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url.path
        reloadList()
    }

    /// Repaint every row's title with where that slice is and how long it has
    /// been there. Called once a second, and again on every state change.
    private func redrawStatuses() {
        for (d, r) in rows {
            let st = state[d] ?? .waiting
            let glyph: String
            var clock = ""
            switch st {
            case .waiting: glyph = "○"
            case .running:
                glyph = "◐"
                if let s = startedAt[d] { clock = "  " + Self.elapsed(since: s) }
            case .done:
                glyph = "✓"
                if let s = startedAt[d], let f = finishedAt[d] {
                    clock = "  " + Self.elapsed(since: s, to: f)
                }
            case .failed: glyph = "✗"
            }
            r.title = "\(glyph)  \(d)\(clock)"
            r.contentTintColor = st == .failed ? .systemRed
                : (st == .done ? .systemGreen : nil)
        }

        // The merge is the longest single step and used to look exactly like
        // nothing happening, because every slice was already ticked off.
        if let started = mergeStarted {
            if mergeRow == nil {
                let t = NSTextField(labelWithString: "")
                t.font = .systemFont(ofSize: 12)
                listStack.addArrangedSubview(t)
                mergeRow = t
            }
            mergeRow?.stringValue = "◐  merge — reconciling the answers  "
                + Self.elapsed(since: started)
        }
    }

    private static func elapsed(since: Date, to: Date = Date()) -> String {
        let s = Int(to.timeIntervalSince(since))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Stop everything this run started, then close. Closing the window alone
    /// leaves N headless agents running with nothing tracking them.
    @objc private func cancelRun() {
        live?.cancel()
        live = nil
        ticker?.invalidate(); ticker = nil
        spinner.stopAnimation(nil)
        close()
    }

    /// Closing the sheet by any route — the red button, escape — must also stop
    /// the run, for the same reason.
    override func close() {
        live?.cancel(); live = nil
        ticker?.invalidate(); ticker = nil
        super.close()
    }

    @objc private func selectAll_() { for r in rows { r.check.state = .on }; recount() }
    @objc private func selectNone() { for r in rows { r.check.state = .off }; recount() }

    private var chosen: [String] { rows.filter { $0.check.state == .on }.map(\.dir) }

    /// Re-price whenever the selection changes. The number is always on screen
    /// before Run is pressed, never discovered afterwards.
    @objc private func recount() {
        let n = chosen.count
        let b = Fanout.budget(vendor: rt.name, slices: n, limits: Limits.all())
        budgetLine.stringValue = n == 0
            ? "nothing selected"
            : "\(n) slice\(n == 1 ? "" : "s") + 1 merge = \(n + 1) calls to \(rt.name)"
        adviceLine.stringValue = b.advice ?? ""
        switch b.verdict {
        case .refuse:   adviceLine.textColor = .systemRed
        case .tight:    adviceLine.textColor = .systemOrange
        default:        adviceLine.textColor = .secondaryLabelColor
        }
        runBtn.isEnabled = n > 0 && b.allowsRun
    }

    @objc private func run() {
        let dirs = chosen
        guard !dirs.isEmpty else { return }
        let slices = dirs.map {
            Slice(label: $0, cwd: (root as NSString).appendingPathComponent($0))
        }
        runBtn.isEnabled = false
        spinner.startAnimation(nil)
        progress.stringValue = "0/\(slices.count)"

        // Every slice is launched at once, so they all start running now.
        let now = Date()
        for d in dirs { state[d] = .running; startedAt[d] = now }
        for r in rows { r.check.isEnabled = false }
        ticker = Timer.inEveryMode(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.redrawStatuses()
        }
        redrawStatuses()

        live = box.fanout(from: fromName, to: rt, question: question, slices: slices,
                   topic: "review",
                   onProgress: { [weak self] done, total, label in
                       guard let self else { return }
                       // A slice that produced nothing is recorded as failed by
                       // the caller; here we only know it finished. The merge
                       // reports the real count.
                       self.state[label] = .done
                       self.finishedAt[label] = Date()
                       self.progress.stringValue = "\(done)/\(total)"
                       self.redrawStatuses()
                   },
                   onMerge: { [weak self] in
                       guard let self else { return }
                       self.mergeStarted = Date()
                       self.redrawStatuses()
                   },
                   completion: { [weak self] result in
                       guard let self else { return }
                       self.spinner.stopAnimation(nil)
                       self.ticker?.invalidate(); self.ticker = nil
                       switch result {
                       case .success(let (_, merged, dir)):
                           self.close()
                           self.onDone(merged, dir)
                       case .failure(let e):
                           self.runBtn.isEnabled = true
                           self.progress.stringValue = ""
                           let a = NSAlert()
                           a.messageText = "The fan-out did not finish"
                           a.informativeText = e.message
                           a.runModal()
                       }
                   })
    }
}

private extension NSTextField {
    convenience init(wrappingLabelString s: String) {
        self.init(wrappingLabelWithString: s)
    }
}
