import AppIntents
import AppKit
import ColdfallCore

// Shortcuts and Siri: Coldfall's desks as actions. Ask a desk and get its
// answer back, send it a message, open or start it, or hear what is waiting
// on you. Everything runs on this Mac, through the same roads as the CLI and
// the phone inbox: a send is refused into a desk stopped on a question or
// mid-way through something you're typing, and a hidden desk is never offered.
//
// For Shortcuts to see these, the app bundle carries Metadata.appintents,
// which scripts/build-app.sh makes with Xcode's appintentsmetadataprocessor
// from the constants the compiler extracts (see Package.swift). A build
// without Xcode works the same but offers no actions.

/// A desk, as Shortcuts lists and Siri matches them.
struct DeskEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Desk"
    static var defaultQuery = DeskQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct DeskQuery: EntityStringQuery {
    /// Listed, not hidden, in the order of desks.toml.
    private func all() -> [DeskEntity] { DeskConfig.load().filter { !$0.hidden }.map { DeskEntity(id: $0.name) } }
    func entities(for identifiers: [String]) async throws -> [DeskEntity] { all().filter { identifiers.contains($0.id) } }
    func entities(matching string: String) async throws -> [DeskEntity] {
        let q = string.lowercased().trimmingCharacters(in: .whitespaces)
        return all().filter { $0.id.lowercased().contains(q) }
    }
    func suggestedEntities() async throws -> [DeskEntity] { all() }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case said(String)
    var localizedStringResource: LocalizedStringResource {
        switch self { case .said(let s): return "\(s)" }
    }
}

/// Run the coldfall-cli that ships beside this app, off the main thread.
/// Send and ask go through it so they keep every rule the CLI keeps.
private func cli(_ args: [String]) async -> (code: Int32, out: String) {
    await withCheckedContinuation { done in
        DispatchQueue.global(qos: .userInitiated).async {
            let me = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            let p = Process()
            p.executableURL = me.deletingLastPathComponent().appendingPathComponent("coldfall-cli")
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { done.resume(returning: (1, "Coldfall's command line tool is missing from the app.")); return }
            let r = Subprocess.drain(p, out: out, err: err, timeout: 3600)
            done.resume(returning: (p.terminationStatus, String(decoding: r.out, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }
}

struct AskDeskIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask a Desk"
    static var description = IntentDescription("Send a desk a message, wait for it to finish, and get back what it said.")
    @Parameter(title: "Desk") var desk: DeskEntity
    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true)) var message: String
    @Parameter(title: "Wait up to (seconds)", default: 300, inclusiveRange: (10, 3600)) var timeout: Int

    static var parameterSummary: some ParameterSummary { Summary("Ask \(\.$desk) \(\.$message)") { \.$timeout } }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let r = await cli(["ask", desk.id, message, "--timeout", String(timeout)])
        // 0 answered; 2 stopped on a question for you; 3 still working.
        switch r.code {
        case 0: return .result(value: r.out, dialog: "\(String(r.out.suffix(600)))")
        case 2: return .result(value: r.out, dialog: "\(desk.id) has a question for you. Open it to answer.")
        case 3: return .result(value: r.out, dialog: "\(desk.id) is still working. Ask again later or open the desk.")
        default: throw IntentFailure.said(r.out.isEmpty ? "\(desk.id) couldn't be asked." : r.out)
        }
    }
}

struct SendToDeskIntent: AppIntent {
    static var title: LocalizedStringResource = "Send to a Desk"
    static var description = IntentDescription("Type a message into a desk, as if you'd typed it, without waiting for the answer.")
    @Parameter(title: "Desk") var desk: DeskEntity
    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true)) var message: String

    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$message) to \(\.$desk)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let r = await cli(["send", desk.id, message])
        guard r.code == 0 else { throw IntentFailure.said(r.out) }
        return .result(dialog: "Sent to \(desk.id).")
    }
}

struct OpenDeskIntent: AppIntent {
    static var title: LocalizedStringResource = "Open a Desk"
    static var description = IntentDescription("Bring Coldfall forward on a desk, starting it if it isn't running.")
    static var openAppWhenRun = true
    @Parameter(title: "Desk") var desk: DeskEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$desk)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let c = Controller.shared else { throw IntentFailure.said("Coldfall is still starting. Try again in a moment.") }
        c.showDesk(named: desk.id)
        NSApp.activate(ignoringOtherApps: true)
        return .result()
    }
}

struct StartDeskIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a Desk"
    static var description = IntentDescription("Start a desk in the background, without bringing Coldfall forward.")
    @Parameter(title: "Desk") var desk: DeskEntity

    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$desk)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let c = Controller.shared else { throw IntentFailure.said("Coldfall is still starting. Try again in a moment.") }
        let a = c.inboxOpen(desk.id)
        guard a.outcome == .started || a.outcome == .alreadyRunning else { throw IntentFailure.said(a.message) }
        return .result(dialog: "\(a.message)")
    }
}

struct NeedsMeIntent: AppIntent {
    static var title: LocalizedStringResource = "What Needs Me"
    static var description = IntentDescription("The desks waiting on you: questions, notices and pull requests. Desk names and what they're about only, never their screens.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let c = Controller.shared else { throw IntentFailure.said("Coldfall is still starting. Try again in a moment.") }
        let s = NeedsSummary.text(c.feedItems().map { NeedsSummary.Item(desk: $0.desk, why: $0.prompt?.question.isEmpty == false ? $0.prompt!.question : ($0.reason ?? "is waiting for you")) })
        return .result(value: s, dialog: "\(s)")
    }
}

struct ColdfallShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NeedsMeIntent(), phrases: ["What needs me in \(.applicationName)", "What's waiting in \(.applicationName)"],
                    shortTitle: "What Needs Me", systemImageName: "bell.badge")
        AppShortcut(intent: AskDeskIntent(), phrases: ["Ask a desk in \(.applicationName)"],
                    shortTitle: "Ask a Desk", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: OpenDeskIntent(), phrases: ["Open a desk in \(.applicationName)"],
                    shortTitle: "Open a Desk", systemImageName: "macwindow")
    }
}
