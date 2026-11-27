import AppKit
import ColdfallCore

/// One theme in the Appearance tab: a small picture of it (the rail, a
/// terminal with its colours, the accent) over its name. Clicking it is
/// choosing it; there is no separate Apply.
final class ThemeCard: NSView {
    let family: Themes.Family
    var onPick: ((Themes.Family) -> Void)?
    var isChosen = false { didSet { needsDisplay = true } }
    private let dark: Bool

    init(_ f: Themes.Family, dark: Bool) {
        family = f
        self.dark = dark
        super.init(frame: NSRect(x: 0, y: 0, width: 196, height: 150))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 196).isActive = true
        heightAnchor.constraint(equalToConstant: 150).isActive = true
        toolTip = f.blurb + (f.credit.map { "\n" + $0 } ?? "")
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(f.title) theme")
    }
    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { onPick?(family) }
    override func accessibilityPerformPress() -> Bool { onPick?(family); return true }

    override func draw(_ dirty: NSRect) {
        let s = Themes.skin(family, dark: dark)
        let c = s.chrome, t = s.terminal
        func col(_ h: String) -> NSColor { Theme.hex(h) }
        let pic = NSRect(x: 0, y: 40, width: bounds.width, height: bounds.height - 40)
        let frame = NSBezierPath(roundedRect: pic.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        col(t.background).setFill(); pic.fill()
        // The rail, with three desk rows, the middle one chosen.
        let rail = NSRect(x: pic.minX, y: pic.minY, width: 58, height: pic.height)
        col(c.sidebar).setFill(); rail.fill()
        col(c.border).setFill(); NSRect(x: rail.maxX, y: pic.minY, width: 1, height: pic.height).fill()
        for (i, y) in [pic.maxY - 22, pic.maxY - 40, pic.maxY - 58].enumerated() {
            if i == 1 { col(c.selected).setFill(); NSBezierPath(roundedRect: NSRect(x: 6, y: y - 5, width: 46, height: 14), xRadius: 4, yRadius: 4).fill() }
            col(i == 1 ? c.text : c.dimText).setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: y, width: i == 1 ? 30 : 24, height: 4), xRadius: 2, yRadius: 2).fill()
        }
        // The terminal: a prompt line, a reply, and its colours.
        let tx = rail.maxX + 12
        col(t.foreground).setFill(); NSBezierPath(roundedRect: NSRect(x: tx, y: pic.maxY - 22, width: 80, height: 4), xRadius: 2, yRadius: 2).fill()
        col(t.foreground).withAlphaComponent(0.55).setFill(); NSBezierPath(roundedRect: NSRect(x: tx, y: pic.maxY - 34, width: 100, height: 4), xRadius: 2, yRadius: 2).fill()
        for (k, i) in [1, 2, 3, 4, 5, 6].enumerated() {
            col(t.ansi[s.isDark ? i + 8 : i]).setFill()
            NSBezierPath(ovalIn: NSRect(x: tx + CGFloat(k) * 17, y: pic.minY + 30, width: 11, height: 11)).fill()
        }
        // What you can press.
        col(c.accent).setFill(); NSBezierPath(roundedRect: NSRect(x: tx, y: pic.minY + 10, width: 46, height: 10), xRadius: 5, yRadius: 5).fill()
        NSGraphicsContext.restoreGraphicsState()
        (isChosen ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        frame.lineWidth = isChosen ? 3 : 1
        frame.stroke()
        // Its name, and a tick when it's the one.
        let name = (isChosen ? "✓ " : "") + family.title
        name.draw(at: NSPoint(x: 2, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let sub = family.light == nil ? "Dark only" : "Light and dark"
        sub.draw(at: NSPoint(x: 2, y: 3), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }
}
