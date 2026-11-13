// Quick open, VS Code's cmd-P: one box that finds a desk OR a file.
//
// Two problems it solves. A workspace with hundreds of files is slow to walk
// through a tree. And cmd-1 to cmd-9 reach only the first nine desks, while a
// real setup has more — the author's has fifteen. Typing part of a name and
// pressing return reaches either.
//
// cmd-P rather than cmd-K on purpose: in most terminals, Ghostty included,
// cmd-K clears the screen, and a terminal user presses it by reflex.
//
// Desks appear at once. Files are indexed on a background queue and merged in
// when ready, so opening the palette never stalls on a large tree. Matching and
// ranking live in ColdfallCore (Fuzzy, FileIndex), under test.

import AppKit
import ColdfallCore

enum PaletteItem {
    case desk(index: Int, name: String, detail: String)
    case file(url: URL, rel: String)
    /// A menu command (see Commands): typed after ">".
    case command(Commands.Entry, NSMenuItem)

    var key: String {
        switch self {
        case .desk(_, let n, _): return n
        case .file(_, let r): return r
        case .command(let e, _): return e.searchKey
        }
    }
}

/// Draws the selected row in the theme's colour, always.
///
/// The system highlight did not draw against the palette's clear background,
/// so the selected row was invisible — arrowing down gave no clue what return
/// would open, which defeats a keyboard-driven box entirely.
private final class PaletteRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Theme.ui.selected.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
    // Keep the highlight whether or not the panel is the key window.
    override var isEmphasized: Bool { get { true } set {} }
}

/// A borderless panel has to opt in to taking the keyboard.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Palette: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    var onPickDesk: ((Int) -> Void)?
    var onPickFile: ((URL) -> Void)?

    private let panel: KeyPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let hint = NSTextField(labelWithString: "")
    private var desks: [PaletteItem] = []
    private var files: [PaletteItem] = []
    private var commands: [PaletteItem] = []
    private var shown: [PaletteItem] = []
    private var root = ""
    private var indexing = false

    static let width: CGFloat = 560
    static let rowH: CGFloat = 26

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 380),
                         styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 9
        box.layer?.borderWidth = 1
        panel.contentView = box

        field.placeholderString = "Go to a desk or file"
        field.font = .systemFont(ofSize: 14)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: .init("r"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = Self.rowH
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activate)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hint.font = .systemFont(ofSize: 11)
        hint.translatesAutoresizingMaskIntoConstraints = false

        let rule = NSBox(); rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        for v in [field, rule, scroll, hint] { box.addSubview(v) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            rule.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            rule.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            hint.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        restyle()
    }

    private func restyle() {
        let ui = Theme.ui
        panel.contentView?.layer?.backgroundColor = ui.sidebar.cgColor
        panel.contentView?.layer?.borderColor = ui.border.cgColor
        field.textColor = ui.text
        hint.textColor = ui.dimText
    }

    var isOpen: Bool { panel.isVisible }

    /// Open over `window`, listing `deskList` now and the files under `root`
    /// once they are indexed.
    /// The desk on screen and its right-click menu, offered as commands.
    var deskMenu: (() -> (name: String, menu: NSMenu)?)?

    func open(over window: NSWindow, desks deskList: [Desk], root: String, query: String = "") {
        restyle()
        desks = deskList.enumerated().map { i, d in
            .desk(index: i, name: d.name,
                  detail: d.runtime == "shell" ? "shell" : d.vendorLabel + (d.isDefault ? " home" : ""))
        }
        if root != self.root { files = []; self.root = root }
        commands = Palette.menuCommands(desk: deskMenu?())
        field.stringValue = query
        refilter()

        let f = window.frame
        let h: CGFloat = 380
        panel.setFrame(NSRect(x: f.midX - Self.width / 2, y: f.maxY - 28 - 14 - h,
                              width: Self.width, height: h), display: true)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)

        if files.isEmpty && !indexing { index(root) }
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func index(_ root: String) {
        indexing = true
        hint.stringValue = "Indexing files…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rel = FileIndex.files(under: root)
            let base = URL(fileURLWithPath: root)
            let items = rel.map { PaletteItem.file(url: base.appendingPathComponent($0), rel: $0) }
            DispatchQueue.main.async {
                guard let self, self.root == root else { return }
                self.files = items
                self.indexing = false
                self.refilter()
            }
        }
    }

    /// Every enabled command in the app's menus, read now so it reflects the
    /// desk on screen (what's enabled depends on it).
    static func menuCommands(desk: (name: String, menu: NSMenu)? = nil) -> [PaletteItem] {
        var found: [(Commands.Entry, NSMenuItem)] = []
        func walk(_ menu: NSMenu, _ path: [String]) {
            menu.update()        // let each item say whether it applies right now
            for it in menu.items where !it.isSeparatorItem && !it.isHidden {
                if let sub = it.submenu {
                    // A menu bar item made without a title carries its name
                    // on the submenu.
                    let name = (it.title.isEmpty || it.title == "NSMenuItem") ? sub.title : it.title
                    walk(sub, path + [name].filter { !$0.isEmpty })
                } else if it.action != nil {
                    found.append((Commands.Entry(path: path + [it.title], key: it.keyEquivalent,
                                                 modifiers: it.keyEquivalentModifierMask.rawValue,
                                                 enabled: it.isEnabled), it))
                }
            }
        }
        // The desk on screen first: stopping or renaming it is the common case.
        if let d = desk { walk(d.menu, [d.name]) }
        if let main = NSApp.mainMenu {
            // The app menu's own title is the app's name; leave it out of paths.
            for top in main.items {
                guard let s = top.submenu else { continue }
                let name = (top.title.isEmpty || top.title == "NSMenuItem") ? s.title : top.title
                walk(s, top == main.items.first ? [] : [name])
            }
        }
        let keep = Commands.offer(found.map(\.0))
        var used = Set<String>()
        return found.compactMap { e, it in
            guard keep.contains(e), used.insert(e.title).inserted else { return nil }
            return .command(e, it)
        }
    }

    private func refilter() {
        let q = field.stringValue
        if let cq = Commands.commandQuery(q) {
            shown = Fuzzy.rank(cq, commands, limit: cq.isEmpty ? commands.count : 40, key: \.key)
            table.reloadData()
            if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
            hint.stringValue = shown.isEmpty ? "No command matches" : "\(shown.count) commands  ·  ⏎ to run  ·  esc to close"
            return
        }
        // Desks first — there are few, and jumping between them is the common
        // case — then files. Each ranked on its own so a strong file match
        // cannot push every desk off the list.
        let d = Fuzzy.rank(q, desks, limit: q.isEmpty ? desks.count : 6, key: \.key)
        let f = q.isEmpty ? [] : Fuzzy.rank(q, files, limit: 40, key: \.key)
        shown = d + f
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        if indexing {
            hint.stringValue = "Indexing files…"
        } else if q.isEmpty {
            hint.stringValue = "Type to search \(files.count) files and \(desks.count) desks  ·  > for commands  ·  ⏎ to open  ·  esc to close"
        } else {
            hint.stringValue = shown.isEmpty ? "Nothing matches" : "\(shown.count) matches  ·  ⏎ to open"
        }
    }

    @objc private func activate() {
        let r = table.selectedRow
        guard shown.indices.contains(r) else { return }
        let item = shown[r]
        close()
        switch item {
        case .desk(let i, _, _): onPickDesk?(i)
        case .file(let u, _): onPickFile?(u)
        case .command(_, let it):
            // After the panel has gone, so the command reaches the window
            // underneath, the way choosing it from the menu would.
            DispatchQueue.main.async {
                guard let a = it.action else { return }
                NSApp.sendAction(a, to: it.target, from: it)
            }
        }
    }

    // MARK: - typing and keys

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): activate(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        guard !shown.isEmpty else { return }
        let r = max(0, min(shown.count - 1, table.selectedRow + d))
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRow() }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let ui = Theme.ui
        let item = shown[row]
        let v = NSView()
        let icon = NSImageView()
        let name = NSTextField(labelWithString: "")
        let detail = NSTextField(labelWithString: "")
        for x in [icon, name, detail] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        name.font = .systemFont(ofSize: 13)
        name.textColor = ui.text
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = ui.dimText
        detail.lineBreakMode = .byTruncatingHead
        switch item {
        case .desk(_, let n, let d):
            icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Desk")
            icon.contentTintColor = ui.accent
            name.stringValue = n
            detail.stringValue = d
        case .file(_, let rel):
            icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "File")
            icon.contentTintColor = ui.dimText
            name.stringValue = (rel as NSString).lastPathComponent
            let dir = (rel as NSString).deletingLastPathComponent
            detail.stringValue = dir.isEmpty ? "" : dir
        case .command(let e, _):
            icon.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Command")
            icon.contentTintColor = ui.accent
            name.stringValue = e.title
            let menu = e.path.dropLast().joined(separator: " ▸ ")
            detail.stringValue = [menu, e.shortcut].filter { !$0.isEmpty }.joined(separator: "   ")
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 10),
            detail.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -8),
        ])
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        return v
    }

    /// For --snapshot: the panel's content, to render into an image.
    var contentView: NSView? { panel.contentView }
    func setQueryForSnapshot(_ q: String) { field.stringValue = q; refilter() }
}
