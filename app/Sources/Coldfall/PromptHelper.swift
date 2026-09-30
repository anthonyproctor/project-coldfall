import AppKit
import ColdfallCore

/// Nothing is read from a desk, sent to a model, or typed into a terminal.
/// The controller retains this window so closing it does not lose a draft.
final class PromptHelper: NSWindowController, NSTextViewDelegate {
    private var inputs: [NSTextView] = []
    private let preview = NSTextView()
    private let status = NSTextField(labelWithString: "Start with the result you want. The other fields are optional.")
    private let buildButton = NSButton(title: "Build draft", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy draft", target: nil, action: nil)
    private var previewEdited = false

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 700),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: w)
        w.title = "Write a prompt"
        w.minSize = NSSize(width: 620, height: 680)
        w.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        w.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -20)
        ])
        let intro = NSTextField(wrappingLabelWithString:
            "A clear ask beats a long prompt. Use this with any agent. Only include details that matter.")
        stack.addArrangedSubview(intro)
        let fields = [
            ("1. What do you want?", "Name the outcome: explain, compare, review, write, or build."),
            ("2. What should the agent know? · optional", "Add relevant background, audience, or exact files to inspect."),
            ("3. What are the boundaries? · optional", "Say what to avoid, what can change, and what needs your approval."),
            ("4. What does a good result look like? · optional", "Specify format, tone, length, or how to check the work.")
        ]
        for (title, hint) in fields {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            stack.addArrangedSubview(label)
            let guidance = NSTextField(labelWithString: hint)
            guidance.font = .systemFont(ofSize: 11)
            guidance.textColor = .secondaryLabelColor
            stack.addArrangedSubview(guidance)
            let text = NSTextView()
            inputs.append(text)
            let scroll = editor(text, label: title)
            stack.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 48).isActive = true
        }
        buildButton.target = self
        buildButton.action = #selector(buildDraft)
        buildButton.bezelStyle = .rounded
        buildButton.isEnabled = false
        stack.addArrangedSubview(buildButton)
        let review = NSTextField(labelWithString: "Your draft · edit it before copying")
        review.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(review)
        let result = editor(preview, label: "Editable prompt draft")
        stack.addArrangedSubview(result)
        result.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        result.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        copyButton.target = self
        copyButton.action = #selector(copyDraft)
        copyButton.bezelStyle = .rounded
        copyButton.isEnabled = false
        let privacy = NSTextField(labelWithString: "Local only. No AI calls. Nothing sent automatically.")
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [copyButton, privacy])
        footer.spacing = 12
        stack.addArrangedSubview(footer)
        w.center()
        w.makeFirstResponder(inputs[0])
    }

    required init?(coder: NSCoder) { nil }

    private func editor(_ text: NSTextView, label: String) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        text.isRichText = false
        text.allowsUndo = true
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 7, height: 5)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 660, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel(label)
        text.delegate = self
        scroll.documentView = text
        return scroll
    }

    func textDidChange(_ notification: Notification) {
        if notification.object as? NSTextView === preview {
            previewEdited = true
            status.stringValue = "Draft edited. Copy uses exactly the text above."
        } else if !preview.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status.stringValue = "Inputs changed. Build again to update the draft, or keep your edited version."
        }
        buildButton.isEnabled = !inputs[0].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        copyButton.isEnabled = !preview.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func buildDraft() {
        if previewEdited {
            let alert = NSAlert()
            alert.messageText = "Replace your edited draft?"
            alert.informativeText = "Building again replaces the draft with the four fields above."
            alert.addButton(withTitle: "Keep my edits")
            alert.addButton(withTitle: "Replace draft")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        preview.string = PromptDraft.build(goal: inputs[0].string, context: inputs[1].string,
                                           constraints: inputs[2].string, success: inputs[3].string)
        preview.undoManager?.removeAllActions()
        previewEdited = false
        copyButton.isEnabled = !preview.string.isEmpty
        status.stringValue = "Review for accuracy. Copy, then paste into the agent you choose."
    }

    @objc private func copyDraft() {
        guard !preview.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(preview.string, forType: .string)
        status.stringValue = copied ? "Copied. Nothing was sent. Paste into your agent when ready." : "Could not copy. Try again."
    }
}
