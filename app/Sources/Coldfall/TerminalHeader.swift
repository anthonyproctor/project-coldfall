// A slim header over the terminal, the way VS Code heads its terminal panel:
//
//   hub  claude home                              ⊟  ⊞  ✕
//   the desk on screen                      split right, split down, close pane
//
// Splits only existed behind cmd-D and cmd-shift-D, which means nobody who had
// not read the README would ever find them. Buttons make them discoverable,
// and the name says which desk the terminal below belongs to — useful the
// moment the rail is hidden.

import AppKit

final class TerminalHeader: NSView {

    var onSplitRight: (() -> Void)?
    var onSplitDown: (() -> Void)?
    var onClosePane: (() -> Void)?
    var onPromptHelper: (() -> Void)?
    private let prompt = NSButton(title: "Write a prompt…", target: nil, action: nil)

    private let name = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let right = TerminalHeader.button("rectangle.split.2x1", tip: "Split right  ⌘D")
    private let down = TerminalHeader.button("rectangle.split.1x2", tip: "Split down  ⇧⌘D")
    private let close = TerminalHeader.button("xmark", tip: "Close pane  ⌘W")

    static let height: CGFloat = 30

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        right.target = self; right.action = #selector(splitR)
        down.target = self;  down.action = #selector(splitD)
        close.target = self; close.action = #selector(closeP)

        for v in [name, sub] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        prompt.target = self; prompt.action = #selector(writePrompt)
        prompt.bezelStyle = .inline
        prompt.isBordered = false
        prompt.font = .systemFont(ofSize: 11)
        prompt.toolTip = "Build and copy a prompt. Nothing is sent."
        let buttons = NSStackView(views: [prompt, right, down, close])
        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            sub.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            sub.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    /// Show the desk on screen. Close is disabled with one pane, since closing
    /// the last pane would leave a desk with no terminal.
    func set(desk: String, detail: String, panes: Int) {
        name.stringValue = desk
        sub.stringValue = detail
        close.isEnabled = panes > 1
        close.alphaValue = panes > 1 ? 1 : 0.35
    }

    func restyle() {
        let ui = Theme.ui
        layer?.backgroundColor = ui.editor.cgColor
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = ui.text
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = ui.dimText
        for b in [prompt, right, down, close] { b.contentTintColor = ui.dimText }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        // A hairline under the header, separating it from the terminal.
        Theme.ui.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func splitR() { onSplitRight?() }
    @objc private func splitD() { onSplitDown?() }
    @objc private func closeP() { onClosePane?() }
    @objc private func writePrompt() { onPromptHelper?() }

    private static func button(_ symbol: String, tip: String) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.bezelStyle = .inline
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }
}
