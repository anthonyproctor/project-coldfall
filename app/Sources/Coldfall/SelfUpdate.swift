import AppKit
import ColdfallCore

/// Rebuild and update Coldfall from inside Coldfall.
///
/// You cannot replace a running binary in place — macOS keeps the executable
/// mapped — but you do not need to. Build, then relaunch.
///
/// A relaunch is still not free. Desks Coldfall launches itself reopen their
/// conversation (see `Resume`), and desks with their own command decide for
/// themselves, but anything a desk is in the middle of is cut off. So the
/// sheet names the desks it is about to end.
///
/// For an open-source app this is the difference between "upgrade by opening a
/// terminal and remembering three commands" and "press Update".
enum SelfUpdate {

    /// Where this bundle was built from. Recorded at build time rather than
    /// guessed, and absent for a bundle shipped without source — in which case
    /// the app says so instead of inventing a path.
    static var sourceRoot: String? {
        guard let p = Bundle.main.object(forInfoDictionaryKey: "DWSourceRoot") as? String,
              !p.isEmpty,
              FileManager.default.fileExists(atPath: (p as NSString).appendingPathComponent("app/Package.swift"))
        else { return nil }
        return p
    }

    static var builtAt: String? {
        Bundle.main.object(forInfoDictionaryKey: "DWBuiltAt") as? String
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Run a command in the source root, streaming output to a handler.
    static func run(_ argv: [String], cwd: String,
                    onLine: @escaping (String) -> Void,
                    done: @escaping (Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", argv.map(Shell.quote).joined(separator: " ")]
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            var env = ProcessInfo.processInfo.environment
            // A build launched from inside an agent session inherits its
            // markers; strip them for the same reason desks do.
            ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"].forEach { env[$0] = "" }
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            p.standardInput = FileHandle.nullDevice

            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    s.split(separator: "\n").forEach { onLine(String($0)) }
                }
            }
            do { try p.run() } catch {
                DispatchQueue.main.async { onLine("could not start: \(error)"); done(1) }
                return
            }
            p.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { done(p.terminationStatus) }
        }
    }

    /// Which desks have a live process right now. Set by the controller, which
    /// is the only thing that knows; a closure rather than a reference so this
    /// window does not reach back into the app to ask.
    static var runningDesks: () -> [String] = { [] }

    /// Replace the running app with the one just built.
    ///
    /// Relaunching has to outlive this process, so it is handed to a detached
    /// shell that waits for us to exit first. Doing it from inside the app
    /// races the very binary being replaced.
    /// Where the rebuilt app lands: next to the running one, under the
    /// current name.
    ///
    /// Two faults this avoids. Relaunching `Bundle.main.bundlePath` reopens
    /// whatever is running, so anyone updating across the rename from
    /// Deskwork.app would rebuild `Project Coldfall.app` and then relaunch the
    /// old, un-rebuilt bundle — back in the stale version with no sign why.
    /// And building into a fixed ~/Applications meant an app kept in
    /// /Applications updated a second copy it never opened.
    static var installDir: String {
        (Bundle.main.bundlePath as NSString).deletingLastPathComponent
    }
    static var rebuiltBundle: String {
        (installDir as NSString).appendingPathComponent("Project Coldfall.app")
    }

    /// Set while an update relaunches Coldfall: held desks keep running
    /// without asking.
    static var relaunching = false

    static func relaunch() {
        relaunching = true
        // Prefer the bundle the build just produced; fall back to the running
        // one only if the build somehow put nothing there.
        let path = FileManager.default.fileExists(atPath: rebuiltBundle)
            ? rebuiltBundle : Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \(Shell.quote(path))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", script]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// A small window that shows the build as it happens, because a progress
/// spinner on a two-minute compile tells you nothing about whether it is stuck.
final class UpdateWindow: NSWindowController {
    private let log = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let goBtn = NSButton()
    private let running = NSTextField(wrappingLabelWithString: "")
    private let pullToggle = NSButton(checkboxWithTitle: "Pull latest changes first", target: nil, action: nil)
    private var root: String
    private var busy = false

    init(root: String) {
        self.root = root
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: w)
        w.title = "Update Project Coldfall"
        build()
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let c = window?.contentView else { return }
        log.isEditable = false
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        log.textContainerInset = NSSize(width: 8, height: 6)
        log.isVerticallyResizable = true
        log.autoresizingMask = [.width]
        log.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = log
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let head = NSTextField(wrappingLabelWithString:
            "Version \(SelfUpdate.version)"
            + (SelfUpdate.builtAt.map { ", built \($0)" } ?? "")
            + "\nSource: \((root as NSString).abbreviatingWithTildeInPath)"
            + "\n\nBuilds from source, then relaunches.")
        head.font = .systemFont(ofSize: 11.5)
        head.textColor = .secondaryLabelColor

        // Name what is about to be ended, and be honest that it is not free.
        running.font = .systemFont(ofSize: 11.5)
        running.preferredMaxLayoutWidth = 660
        let live = SelfUpdate.runningDesks().sorted()
        if live.isEmpty {
            running.stringValue = "No desks are running, so nothing is lost."
            running.textColor = .secondaryLabelColor
        } else {
            running.stringValue = "Relaunching ends \(live.count) running "
                + "desk\(live.count == 1 ? "" : "s") — \(live.joined(separator: ", ")) — "
                + "and anything they are in the middle of stops. Desks Coldfall starts "
                + "itself pick up the same conversation; desks with their own command "
                + "run it again."
            running.textColor = .systemOrange
        }
        head.preferredMaxLayoutWidth = 660

        pullToggle.state = .on
        goBtn.title = "Update and relaunch"
        goBtn.bezelStyle = .rounded
        goBtn.keyEquivalent = "\r"
        goBtn.target = self; goBtn.action = #selector(go)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        let row = NSStackView(views: [pullToggle, NSView(), status, goBtn])
        row.orientation = .horizontal; row.spacing = 10
        let stack = NSStackView(views: [head, running, scroll, row])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: c.topAnchor),
            stack.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
    }

    private func say(_ s: String) {
        log.string += s + "\n"
        log.scrollToEndOfDocument(nil)
    }

    @objc private func go() {
        guard !busy else { return }
        busy = true; goBtn.isEnabled = false
        log.string = ""

        let steps: [(String, [String])] = (pullToggle.state == .on
            ? [("pulling", ["git", "pull", "--ff-only"])] : [])
            + [("building", ["./scripts/build-app.sh", SelfUpdate.installDir])]

        func next(_ i: Int) {
            guard i < steps.count else {
                status.stringValue = "relaunching"
                say("\nrelaunching…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { SelfUpdate.relaunch() }
                return
            }
            let (label, argv) = steps[i]
            status.stringValue = label
            say("$ " + argv.joined(separator: " "))
            SelfUpdate.run(argv, cwd: root, onLine: { [weak self] in self?.say("  " + $0) }) { [weak self] code in
                guard let self else { return }
                if code != 0 {
                    // A failed build must not relaunch: that would replace a
                    // working app with nothing.
                    self.status.stringValue = "\(label) failed — nothing was changed"
                    self.say("\n\(label) exited \(code). The running app is untouched.")
                    self.busy = false; self.goBtn.isEnabled = true
                    return
                }
                next(i + 1)
            }
        }
        next(0)
    }
}
