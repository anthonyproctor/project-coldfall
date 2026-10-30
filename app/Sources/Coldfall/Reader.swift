import AppKit
import ColdfallCore
import PDFKit

/// Read-only viewer with tabs.
///
/// Two ways a file lands here. You click it in the tree, or an agent writes it
/// and the workspace watcher opens it for you — which is the behaviour worth
/// having: you do not know which file the agent is about to touch, so you
/// cannot have opened it first.
///
/// Agent-opened tabs are marked as transient (italic, like a preview tab) and
/// the oldest is recycled, so a busy agent does not bury you in tabs. Clicking
/// one, or editing what it shows, makes it permanent.
final class ReaderView: NSView {
    private let tabBar = NSStackView()
    private let tabScroll = NSScrollView()
    private let container = NSView()
    private let titleBar = NSTextField(labelWithString: "")
    /// Moves the reader between its pane and its own window.
    private let popBtn = NSButton()
    var onPopToggle: (() -> Void)?
    /// In its own window rather than the pane. Flips the button's icon.
    var poppedOut = false { didSet { updatePopButton() } }

    private struct Tab {
        let url: URL
        var view: NSView
        var transient: Bool
        var watcher: DispatchSourceFileSystemObject?
    }
    private var tabs: [Tab] = []
    private var activeIndex: Int? = nil
    private let maxTransient = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.ui.editor.cgColor

        tabBar.orientation = .horizontal
        tabBar.spacing = 4
        tabBar.alignment = .centerY
        // gravityAreas packs left. The default distribution spreads slack
        // between items, so bolding the active tab shoved the others right.
        tabBar.distribution = .gravityAreas
        tabBar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        tabScroll.documentView = tabBar
        tabScroll.hasHorizontalScroller = false
        tabScroll.drawsBackground = false
        tabScroll.translatesAutoresizingMaskIntoConstraints = false

        titleBar.font = .systemFont(ofSize: 12)
        titleBar.textColor = .secondaryLabelColor
        titleBar.lineBreakMode = .byTruncatingHead
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false

        popBtn.imagePosition = .imageOnly
        popBtn.isBordered = false
        popBtn.bezelStyle = .inline
        popBtn.target = self
        popBtn.action = #selector(popToggled)
        popBtn.translatesAutoresizingMaskIntoConstraints = false
        updatePopButton()

        addSubview(tabScroll); addSubview(popBtn); addSubview(titleBar); addSubview(container)
        NSLayoutConstraint.activate([
            popBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            popBtn.centerYAnchor.constraint(equalTo: tabScroll.centerYAnchor),
            popBtn.widthAnchor.constraint(equalToConstant: 24),
            popBtn.heightAnchor.constraint(equalToConstant: 20),
            tabScroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            tabScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabScroll.trailingAnchor.constraint(equalTo: popBtn.leadingAnchor, constant: -4),
            tabScroll.heightAnchor.constraint(equalToConstant: 30),
            titleBar.topAnchor.constraint(equalTo: tabScroll.bottomAnchor, constant: 2),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 4),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        showPlaceholder()
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    @objc private func popToggled() { onPopToggle?() }

    private func updatePopButton() {
        let (sym, tip) = poppedOut
            ? ("arrow.down.left.square", "Put the reader back beside the terminal")
            : ("arrow.up.forward.square", "Open the reader in its own window — for a second screen")
        popBtn.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
        popBtn.toolTip = tip
        popBtn.contentTintColor = Theme.ui.dimText
    }

    // MARK: - opening

    /// Clicked in the tree: a permanent tab.
    func open(_ url: URL) { openTab(url, transient: false) }

    /// Written by an agent: a transient tab, recycled once there are too many.
    func openFromAgent(_ url: URL) { openTab(url, transient: true) }

    private func openTab(_ url: URL, transient: Bool) {
        if let i = tabs.firstIndex(where: { $0.url == url }) {
            if !transient { tabs[i].transient = false }   // clicking pins it
            select(i)
            return
        }
        guard let v = buildView(for: url) else { return }

        if transient {
            // Keep the flood bounded: recycle the oldest transient tab.
            let transients = tabs.enumerated().filter { $0.element.transient }
            if transients.count >= maxTransient, let oldest = transients.first {
                close(at: oldest.offset, rebuild: false)
            }
        }
        var t = Tab(url: url, view: v, transient: transient, watcher: nil)
        t.watcher = watch(url)
        tabs.append(t)
        select(tabs.count - 1)
    }

    private func select(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        activeIndex = i
        container.subviews.forEach { $0.removeFromSuperview() }
        let v = tabs[i].view
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        titleBar.stringValue = (tabs[i].url.path as NSString).abbreviatingWithTildeInPath
        rebuildTabs()
    }

    private func close(at i: Int, rebuild: Bool = true) {
        guard tabs.indices.contains(i) else { return }
        tabs[i].watcher?.cancel()
        tabs.remove(at: i)
        if tabs.isEmpty { activeIndex = nil; showPlaceholder(); if rebuild { rebuildTabs() }; return }
        select(min(i, tabs.count - 1))
    }

    @objc private func tabClicked(_ s: NSButton) { select(s.tag) }
    @objc private func tabClosed(_ s: NSButton) { close(at: s.tag) }

    private func rebuildTabs() {
        tabBar.arrangedSubviews.forEach { tabBar.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (i, t) in tabs.enumerated() {
            tabBar.addArrangedSubview(chip(index: i, tab: t, active: i == activeIndex))
        }
        // Absorb the slack so tabs stay packed to the left.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        tabBar.addArrangedSubview(spacer)

        tabBar.layoutSubtreeIfNeeded()
        tabBar.frame = NSRect(x: 0, y: 0,
                              width: max(tabBar.fittingSize.width, tabScroll.bounds.width),
                              height: 30)
    }

    /// A tab needs to look like a tab. The first build was bare text on the
    /// window background and was genuinely hard to see.
    private func chip(index i: Int, tab t: Tab, active: Bool) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.backgroundColor = active
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.5).cgColor
        box.layer?.borderWidth = active ? 1 : 0
        box.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor

        let label = NSButton(title: t.url.lastPathComponent, target: self, action: #selector(tabClicked(_:)))
        label.tag = i
        label.bezelStyle = .inline
        label.isBordered = false
        let base = NSFont.systemFont(ofSize: 11.5, weight: active ? .semibold : .regular)
        label.font = t.transient
            ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            : base
        label.contentTintColor = active ? .controlAccentColor : .labelColor
        label.toolTip = t.transient
            ? "\(t.url.path)\n\nOpened by a desk. Click to keep it."
            : t.url.path

        let x = NSButton(title: "×", target: self, action: #selector(tabClosed(_:)))
        x.tag = i; x.bezelStyle = .inline; x.isBordered = false
        x.font = .systemFont(ofSize: 12)
        x.contentTintColor = .tertiaryLabelColor

        let row = NSStackView(views: [label, x])
        row.orientation = .horizontal
        row.spacing = 1
        row.edgeInsets = NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 5)
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: box.topAnchor),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        box.setContentHuggingPriority(.required, for: .horizontal)
        return box
    }

    // MARK: - content

    private func swapPlaceholder(_ v: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    private func showPlaceholder() {
        let l = NSTextField(labelWithString: "Pick a file, or let a desk open one.")
        l.textColor = .secondaryLabelColor
        swapPlaceholder(l)
        titleBar.stringValue = ""
    }

    private func message(_ s: String) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.textColor = .tertiaryLabelColor
        l.alignment = .center
        return l
    }

    private func buildView(for url: URL) -> NSView? {
        let ext = url.pathExtension.lowercased()

        if ext == "pdf", let doc = PDFDocument(url: url) {
            let v = PDFView(); v.document = doc; v.autoScales = true
            v.displayMode = .singlePageContinuous
            return v
        }
        if ["png","jpg","jpeg","gif","heic","webp","tiff","bmp","svg"].contains(ext),
           let img = NSImage(contentsOf: url) {
            let v = NSImageView(); v.image = img
            v.imageScaling = .scaleProportionallyUpOrDown
            return v
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return message("Could not read that file.")
        }
        if data.prefix(8000).contains(0) { return message("Binary file — nothing to show.") }
        guard let text = String(data: data.prefix(2_000_000), encoding: .utf8)
                      ?? String(data: data.prefix(2_000_000), encoding: .isoLatin1) else {
            return message("Could not decode that file as text.")
        }

        // Markdown is prose meant to be rendered, and most of what agents
        // write is markdown. Showing its raw source in a terminal font — `#`
        // before headings, tables as rows of pipes — was the "looks like
        // dogshit" report. Render it instead.
        if ["md", "markdown", "mdown", "mkd"].contains(ext) {
            let v = MarkdownView(markdown: text, fileURL: url)
            v.onOpenFile = { [weak self] u in self?.open(u) }
            return v
        }

        let tv = NSTextView()
        tv.isEditable = false
        tv.drawsBackground = false
        // 13 rather than 12, and the theme's text colour set explicitly.
        // Nothing set a colour before, so plain text inherited a washed-out
        // grey that was hard to read against the dark editor background.
        let f = Theme.current().font.withSize(13)
        tv.font = f
        tv.textColor = Theme.ui.text
        tv.textContainerInset = NSSize(width: 18, height: 14)
        let para = NSMutableParagraphStyle(); para.lineSpacing = 3
        tv.defaultParagraphStyle = para
        if let hl = Highlight.attributed(text, ext: ext, font: f) {
            tv.isRichText = true
            tv.textStorage?.setAttributedString(hl)
        } else {
            tv.isRichText = false
            tv.string = text
            tv.textColor = Theme.ui.text
        }
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    /// Agents rewrite files while you are reading them, so each tab watches its
    /// own file and refreshes in place, keeping scroll position.
    private func watch(_ url: URL) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.refresh(url) }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        return src
    }

    private func refresh(_ url: URL) {
        guard let i = tabs.firstIndex(where: { $0.url == url }) else { return }
        // A rendered page reloads itself in place, keeping the reader's
        // scroll position — rebuilding the view would flicker and jump to top.
        if let md = tabs[i].view as? MarkdownView,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            md.reload(markdown: text)
            tabs[i].watcher?.cancel()
            tabs[i].watcher = watch(url)
            return
        }
        guard let fresh = buildView(for: url) else { return }
        let offset = (tabs[i].view as? NSScrollView)?.contentView.bounds.origin
        tabs[i].view = fresh
        // Replacing by path rather than trusting the descriptor: agents replace
        // files at least as often as they write in place.
        tabs[i].watcher?.cancel()
        tabs[i].watcher = watch(url)
        if activeIndex == i {
            select(i)
            if let o = offset, let sv = tabs[i].view as? NSScrollView {
                sv.contentView.scroll(to: o); sv.reflectScrolledClipView(sv.contentView)
            }
        }
    }
}
