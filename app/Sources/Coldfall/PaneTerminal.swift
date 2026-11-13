import AppKit
import SwiftTerm
import ColdfallCore

/// What a pane needs from the terminal that draws it, whichever that is.
///
/// Two satisfy it: SwiftTerm (ClassicTerminal, below), which Coldfall has
/// always used, and Ghostty's (GhosttyPaneTerminal, in builds that have
/// it). Everything above this line (panes, desks, the controller) talks to
/// a terminal only through here.
protocol PaneTerminal: AnyObject {
    /// The view to put in the pane's card and give the keyboard to.
    var view: NSView { get }

    /// The program wrote something.
    var onOutput: (() -> Void)? { get set }
    /// Something was typed, pasted or dropped into it.
    var onInput: (([UInt8]) -> Void)? { get set }
    /// The program reported its status (OSC 7501).
    var onStatus: ((ProgramStatus.Report) -> Void)? { get set }
    /// A plain terminal notification (OSC 9, 99, 777), as its message.
    var onNotice: ((String) -> Void)? { get set }
    /// The program set the terminal's title.
    var onTitle: ((String) -> Void)? { get set }
    /// The program ended.
    var onExit: (() -> Void)? { get set }
    /// SwiftTerm reports exits and titles through its own delegate.
    var exitDelegate: LocalProcessTerminalViewDelegate? { get set }

    /// Start a program in it. `held` is the desk whose holder the program
    /// attaches to, for a terminal that learns the desk's state from there.
    func start(executable: String, args: [String], desk: Desk, extraEnv: [String], held: String?)
    /// Text as a person would type it.
    func send(text: String)
    /// Text typed by Coldfall itself (a desk's launch line): not you.
    func sendQuietly(_ text: String)
    func send(bytes: [UInt8])
    /// Painted straight onto the screen, not through the program. A
    /// terminal that can't do this simply doesn't.
    func feed(text: String)
    /// Everything on it, scrollback included.
    func screenText() -> String
    /// The rows on screen now (see ScreenChange.liveRows).
    func liveRows() -> [String]
    /// Coldfall's theme, with the desk's own colour washed in.
    func applyTheme(wash: String?)
    func terminate()
    /// The shell this terminal started, when it knows.
    var shellPid: Int32? { get }
}

/// SwiftTerm, as Coldfall has always used it.
final class ClassicTerminal: PaneTerminal {
    let term: DeskTerminalView
    var view: NSView { term }

    init(listensForStatus: Bool) {
        term = DeskTerminalView(frame: .zero)
        term.translatesAutoresizingMaskIntoConstraints = false
        if listensForStatus { term.listenForStatus() }
        Theme.apply(to: term)
    }

    var onOutput: (() -> Void)? { get { term.onOutput } set { term.onOutput = newValue } }
    var onInput: (([UInt8]) -> Void)? { get { term.onInput } set { term.onInput = newValue } }
    var onStatus: ((ProgramStatus.Report) -> Void)? { get { term.onStatus } set { term.onStatus = newValue } }
    var onNotice: ((String) -> Void)? { get { term.onNotice } set { term.onNotice = newValue } }
    // SwiftTerm's delegate carries these two.
    var onTitle: ((String) -> Void)?
    var onExit: (() -> Void)?
    var exitDelegate: LocalProcessTerminalViewDelegate? {
        get { term.processDelegate }
        set { term.processDelegate = newValue }
    }

    func start(executable: String, args: [String], desk: Desk, extraEnv: [String], held: String?) {
        term.startProcess(executable: executable, args: args, environment: Pane.environment(for: desk) + extraEnv)
    }
    func send(text: String) { term.send(txt: text) }
    func sendQuietly(_ text: String) { term.sendQuietly(text) }
    func send(bytes: [UInt8]) { term.send(source: term, data: bytes[...]) }
    func feed(text: String) { term.feed(text: text) }
    func screenText() -> String { String(decoding: term.getTerminal().getBufferAsData(), as: UTF8.self) }
    func liveRows() -> [String] {
        let t = term.getTerminal()
        return ScreenChange.liveRows(buffer: String(decoding: t.getBufferAsData(), as: UTF8.self), rows: t.rows)
    }
    func applyTheme(wash: String?) { Theme.apply(to: term, wash: wash) }
    func terminate() { term.terminate() }
    var shellPid: Int32? { term.process?.shellPid }
}

/// Which terminal a new pane gets.
enum PaneTerminals {
    /// Whether this build carries Ghostty's terminal at all.
    static var hasGhostty: Bool {
        #if COLDFALL_GHOSTTY
        return GhosttyRuntime.shared != nil
        #else
        return false
        #endif
    }

    static func make(isAgent: Bool, ghostty: Bool) -> PaneTerminal {
        #if COLDFALL_GHOSTTY
        if ghostty, GhosttyRuntime.shared != nil { return GhosttyPaneTerminal() }
        #endif
        return ClassicTerminal(listensForStatus: isAgent)
    }
}
