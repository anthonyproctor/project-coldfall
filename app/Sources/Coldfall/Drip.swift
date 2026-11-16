import AppKit
import ColdfallCore

/// Drip: a soft blob that lives in the notch around the camera and shows, at a
/// glance, what the desks are doing (see `Companion` in the core).
///
/// It is a see-through window laid over the notch, a little taller than it so
/// a worried Drip can hang down out of it. It never takes the keys and never
/// activates Coldfall on its own; only a click on it does.
final class DripWindow {
    /// How far below the notch Drip can reach.
    static let below: CGFloat = 30

    private var panel: NSPanel?
    let view = DripView()
    var onClick: (() -> Void)? {
        get { view.onClick } set { view.onClick = newValue }
    }
    private var screenObserver: NSObjectProtocol?

    /// The built-in screen's notch, if this Mac has one.
    static func notch() -> CGRect? {
        for s in NSScreen.screens {
            if let n = Notch.find(screenTop: s.frame.maxY, leftEnds: s.auxiliaryTopLeftArea.map { Double($0.maxX) },
                                  rightStarts: s.auxiliaryTopRightArea.map { Double($0.minX) },
                                  inset: Double(s.safeAreaInsets.top)) {
                return CGRect(x: n.x, y: n.y, width: n.width, height: n.height)
            }
        }
        return nil
    }

    func show() {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.place()
                }
        }
        place()
    }

    func hide() {
        panel?.orderOut(nil)
        view.running = false
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
    }

    func set(_ c: Companion) {
        view.mood = c.mood
        view.toolTip = c.tip
    }

    /// Over the notch, or nowhere on a Mac without one.
    private func place() {
        guard let n = Self.notch() else { panel?.orderOut(nil); view.running = false; return }
        let frame = NSRect(x: n.minX, y: n.minY - Self.below, width: n.width, height: n.height + Self.below)
        let p = panel ?? make()
        p.setFrame(frame, display: true)
        view.notchHeight = n.height
        p.orderFrontRegardless()
        view.running = true
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = view
        panel = p
        return p
    }
}

/// Draws Drip. Flipped, so y runs down from the top of the screen like the
/// notch does; everything is laid out against a 32-point notch and scaled.
final class DripView: NSView {
    var mood: CompanionMood = .asleep { didSet { if mood != oldValue { changedAt = CACurrentMediaTime(); needsDisplay = true } } }
    var notchHeight: CGFloat = 32 { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    /// A fixed moment to draw, for snapshots; nil means the clock.
    var frozenAt: Double?
    var running = false {
        didSet {
            guard running != oldValue else { return }
            timer?.invalidate(); timer = nil
            if running {
                timer = Timer.inEveryMode(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            }
        }
    }
    private var timer: Timer?
    private var changedAt = CACurrentMediaTime()
    private var lastDraw = 0.0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(blobRect, cursor: .pointingHand) }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Asleep, it breathes slowly: no need for thirty frames a second.
    private func tick() {
        let now = CACurrentMediaTime()
        let every = mood == .asleep || reduceMotion ? 1.0 / 8 : 1.0 / 30
        if now - lastDraw >= every { lastDraw = now; needsDisplay = true }
    }

    /// Scale from the 32-point notch the drawing is laid out on.
    private var k: CGFloat { notchHeight / 32 }
    private var mid: CGFloat { bounds.width / 2 }

    /// Roughly where Drip is, for the cursor.
    private var blobRect: NSRect {
        switch mood {
        case .needs: return NSRect(x: mid + 30 * k, y: 0, width: 26 * k, height: bounds.height)
        case .asleep: return NSRect(x: mid - 72 * k, y: 18 * k, width: 40 * k, height: 14 * k)
        default: return NSRect(x: mid + 22 * k, y: 10 * k, width: 54 * k, height: 22 * k)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let t = frozenAt ?? (reduceMotion ? 1.2 : CACurrentMediaTime())
        g.saveGState()
        g.scaleBy(x: k, y: k)
        draw(in: g, t: t, mid: mid / k)
        g.restoreGState()
    }

    /// For snapshots: each mood in a stand-in notch over a stand-in
    /// wallpaper, side by side, at three times size, each at a moment that
    /// shows it well.
    static func sheet() -> NSBitmapImageRep {
        let moods: [(CompanionMood, Double)] = [(.working, 0.3), (.done, 0.15), (.needs, 0.25), (.asleep, 0.5)]
        let cell = NSSize(width: 260, height: 32 + DripWindow.below + 8), scale: CGFloat = 3
        let px = NSSize(width: cell.width * CGFloat(moods.count) * scale, height: cell.height * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: cell.width * CGFloat(moods.count), height: cell.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (i, (m, t)) in moods.enumerated() {
            let x0 = CGFloat(i) * cell.width
            NSColor(calibratedRed: 0.17, green: 0.29, blue: 0.42, alpha: 1).setFill()
            NSRect(x: x0, y: 0, width: cell.width, height: cell.height).fill()
            NSColor(calibratedWhite: 0.05, alpha: 0.35).setFill()
            NSRect(x: x0, y: cell.height - 32, width: cell.width, height: 32).fill()
            let nw: CGFloat = 190, nx = x0 + (cell.width - nw) / 2
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: nx, y: cell.height - 32, width: nw, height: 40), xRadius: 9, yRadius: 9).fill()
            NSRect(x: nx, y: cell.height - 20, width: nw, height: 20).fill()
            NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: nx + nw / 2 - 3.4, y: cell.height - 11 - 3.4, width: 6.8, height: 6.8)).fill()
            let v = DripView(frame: NSRect(x: 0, y: 0, width: nw, height: 32 + DripWindow.below))
            v.mood = m; v.frozenAt = t
            let r = NSRect(x: nx, y: cell.height - 32 - DripWindow.below, width: nw, height: 32 + DripWindow.below)
            NSGraphicsContext.saveGraphicsState()
            let tr = NSAffineTransform()
            tr.translateX(by: r.minX, yBy: r.maxY); tr.scaleX(by: 1, yBy: -1); tr.concat()
            if let cg = NSGraphicsContext.current?.cgContext {
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            }
            v.draw(v.bounds)
            NSGraphicsContext.restoreGraphicsState()
            let label = NSAttributedString(string: m.rawValue, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.7)])
            label.draw(at: NSPoint(x: x0 + 6, y: 4))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: - drawing, in notch points (the notch is 32 tall, the camera at `mid`)

    private static let lilac = CGColor(red: 0.85, green: 0.80, blue: 1.0, alpha: 1)
    private static let amber = CGColor(red: 1.0, green: 0.82, blue: 0.54, alpha: 1)
    private static let ink = CGColor(red: 0.08, green: 0.06, blue: 0.14, alpha: 1)

    private func draw(in g: CGContext, t: Double, mid: CGFloat) {
        let floor: CGFloat = 31
        var x = mid + 46, cy: CGFloat = 22, look: CGFloat = 0
        g.setFillColor(mood == .needs ? Self.amber : Self.lilac)
        switch mood {
        case .working:
            x = mid + 46 + 18 * CGFloat(sin(t * 0.6))
            look = cos(t * 0.6) > 0 ? 1.5 : -1.5
            let w = CGFloat(sin(t * 4))
            let rx = 13 * (1 + 0.06 * w), ry = 9 * (1 - 0.06 * w)
            cy = floor - ry
            dome(g, x: x, cy: cy, rx: rx, ry: ry, floor: floor)
        case .done:
            let p = (t * 1.5).truncatingRemainder(dividingBy: 1)
            let hop = CGFloat(sin(p * .pi)) * 6
            let land = CGFloat(max(0, 1 - p * 5))
            let rx = 13 * (1 + 0.22 * land), ry = 9 * (1 - 0.22 * land)
            cy = floor - ry - hop
            g.addEllipse(in: CGRect(x: x - rx, y: cy - ry, width: rx * 2, height: ry * 2))
            g.fillPath()
        case .needs:
            x = mid + 42
            let sw = CGFloat(sin(t * 2.6))
            let bulbY = 32 + 12 + sw * 2, br = 11 - sw * 0.6
            // Spread along the notch's edge, a narrow neck, then the drop.
            g.move(to: CGPoint(x: x - 13, y: 29.5))
            g.addCurve(to: CGPoint(x: x - 4, y: 35), control1: CGPoint(x: x - 6, y: 30), control2: CGPoint(x: x - 4, y: 32))
            g.addCurve(to: CGPoint(x: x - br, y: bulbY), control1: CGPoint(x: x - 4, y: 38), control2: CGPoint(x: x - br, y: bulbY - br * 0.7))
            g.addArc(center: CGPoint(x: x, y: bulbY), radius: br, startAngle: .pi, endAngle: 0, clockwise: true)
            g.addCurve(to: CGPoint(x: x + 4, y: 35), control1: CGPoint(x: x + br, y: bulbY - br * 0.7), control2: CGPoint(x: x + 4, y: 38))
            g.addCurve(to: CGPoint(x: x + 13, y: 29.5), control1: CGPoint(x: x + 4, y: 32), control2: CGPoint(x: x + 6, y: 30))
            g.closePath(); g.fillPath()
            cy = bulbY - 1
        case .asleep:
            x = mid - 52
            let b = CGFloat(sin(t * 1.4)) * 0.8
            let rx = 17 + b, ry = 4.5 - b * 0.3
            cy = floor - ry
            dome(g, x: x, cy: cy, rx: rx, ry: ry, floor: floor)
        }
        if mood != .asleep {
            g.setFillColor(CGColor(gray: 1, alpha: 0.55))
            g.saveGState()
            g.translateBy(x: x - 6, y: cy - 4); g.rotate(by: -0.5)
            g.addEllipse(in: CGRect(x: -2.6, y: -1.6, width: 5.2, height: 3.2)); g.fillPath()
            g.restoreGState()
        }
        face(g, x: x, cy: cy, look: look, t: t)
        switch mood {
        case .done: sparkles(g, t: t, x: x, y: 36)
        case .needs: bang(g, t: t, x: x + 17, y: 36)
        case .asleep: zs(g, t: t, x: x + 14, y: 30)
        case .working: break
        }
    }

    /// A half-ellipse sitting on the notch's floor.
    private func dome(_ g: CGContext, x: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, floor: CGFloat) {
        g.saveGState()
        g.clip(to: CGRect(x: x - rx - 1, y: cy - ry - 1, width: rx * 2 + 2, height: floor - (cy - ry) + 1))
        g.addEllipse(in: CGRect(x: x - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        g.fillPath()
        g.restoreGState()
        g.fill(CGRect(x: x - rx, y: cy, width: rx * 2, height: floor - cy))
    }

    private func face(_ g: CGContext, x: CGFloat, cy: CGFloat, look: CGFloat, t: Double) {
        g.setFillColor(Self.ink); g.setStrokeColor(Self.ink)
        g.setLineWidth(1.6); g.setLineCap(.round)
        switch mood {
        case .working:
            let blink: CGFloat = t.truncatingRemainder(dividingBy: 3.6) < 0.12 ? 0.3 : 1
            for d: CGFloat in [-4, 4] {
                g.addEllipse(in: CGRect(x: x + d + look - 1.5, y: cy + 1 - 2.1 * blink, width: 3, height: 4.2 * blink))
            }
            g.fillPath()
        case .done:
            for d: CGFloat in [-4, 4] {
                g.addArc(center: CGPoint(x: x + d, y: cy + 2), radius: 2, startAngle: .pi * 1.1, endAngle: .pi * 1.9, clockwise: false)
                g.strokePath()
            }
        case .needs:
            for d: CGFloat in [-4, 4] {
                g.addEllipse(in: CGRect(x: x + d - 1.9, y: cy + 1.5 - 2.6, width: 3.8, height: 5.2))
            }
            g.addEllipse(in: CGRect(x: x - 1.6, y: cy + 6.5 - 1.2, width: 3.2, height: 2.4))
            g.fillPath()
        case .asleep:
            for d: CGFloat in [-5, 5] {
                g.addArc(center: CGPoint(x: x + d, y: cy), radius: 1.8, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
                g.strokePath()
            }
        }
    }

    private func sparkles(_ g: CGContext, t: Double, x: CGFloat, y: CGFloat) {
        g.setFillColor(CGColor(red: 1, green: 0.91, blue: 0.65, alpha: 1))
        for (dx, dy, ph) in [(-18.0, 8.0, 0.0), (16, 12, 1.3), (-4, 20, 2.4), (24, 0, 3.1)] {
            let a = max(0, sin(t * 5 + ph)); if a <= 0 { continue }
            let s = CGFloat(1.5 + a * 2.2), c = CGPoint(x: x + CGFloat(dx), y: y + CGFloat(dy))
            g.setAlpha(CGFloat(a))
            g.move(to: CGPoint(x: c.x, y: c.y - s))
            for (px, py) in [(0.3, -0.3), (1, 0), (0.3, 0.3), (0, 1), (-0.3, 0.3), (-1, 0), (-0.3, -0.3)] {
                g.addLine(to: CGPoint(x: c.x + s * px, y: c.y + s * py))
            }
            g.closePath(); g.fillPath()
        }
        g.setAlpha(1)
    }

    private func bang(_ g: CGContext, t: Double, x: CGFloat, y: CGFloat) {
        g.setAlpha(CGFloat(0.55 + 0.45 * sin(t * 7)))
        g.setFillColor(Self.amber)
        g.fill(CGRect(x: x, y: y, width: 2.4, height: 7))
        g.fill(CGRect(x: x, y: y + 9, width: 2.4, height: 2.4))
        g.setAlpha(1)
    }

    private func zs(_ g: CGContext, t: Double, x: CGFloat, y: CGFloat) {
        for i in 0..<3 {
            let p = (t * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let size = CGFloat(6 + p * 6)
            let s = NSAttributedString(string: "z", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: NSColor(calibratedRed: 0.91, green: 0.93, blue: 0.98, alpha: CGFloat(max(0, 1 - p) * 0.9)),
            ])
            // Drawn unscaled-flipped: NSString drawing respects the flipped view.
            s.draw(at: NSPoint(x: x + CGFloat(p) * 16, y: y + CGFloat(p) * 26 - size))
        }
    }
}
