import AppKit
import ColdfallCore

/// Drip: a soft blob that lives at the notch and shows, at a glance, what the
/// desks are doing (see `Companion` in the core).
///
/// The notch is a hole in the screen: nothing drawn inside it shows. So Drip
/// lives in a black wing that extends the notch to the right along the menu
/// bar, roaming in it and tucking back into the notch at the end. When a desk
/// needs you, it hangs down below the wing as an amber drop.
///
/// It is a see-through window laid over the notch and the wing. It never
/// takes the keys and never activates Coldfall on its own; only a click on
/// it does.
final class DripWindow {
    /// How far right of the notch the window reaches, in notch-layout points
    /// (the wing at its widest, and room for sparkles past it).
    static let side: CGFloat = 112
    /// How far below the notch: room for the drop.
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
        if view.mood != c.mood { view.mood = c.mood }
        if view.toolTip != c.tip { view.toolTip = c.tip }     // set each tick otherwise
    }

    /// Over the notch and its wing, or nowhere on a Mac without one.
    private func place() {
        guard let n = Self.notch() else { panel?.orderOut(nil); view.running = false; return }
        let k = n.height / 32
        let frame = NSRect(x: n.minX, y: n.minY - Self.below * k,
                           width: n.width + Self.side * k, height: n.height + Self.below * k)
        let p = panel ?? make()
        p.setFrame(frame, display: true)
        view.notchHeight = n.height
        view.notchWidth = n.width
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
        // Stays when Coldfall is hidden (Cmd-H), in the background, or its
        // window is minimized: the notch is the one place still on screen.
        p.canHide = false
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = view
        panel = p
        return p
    }
}

/// Draws Drip. Flipped, so y runs down from the top of the screen; the notch
/// spans x from 0 to `notchWidth`, and everything is laid out against a
/// 32-point notch and scaled.
final class DripView: NSView {
    var mood: CompanionMood = .asleep { didSet { if mood != oldValue { needsDisplay = true } } }
    var notchHeight: CGFloat = 32 { didSet { needsDisplay = true } }
    var notchWidth: CGFloat = 190 { didSet { needsDisplay = true } }
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
    private var lastDraw = 0.0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(blobRect, cursor: .pointingHand) }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Asleep, it breathes slowly: no need for thirty frames a second.
    private func tick() {
        // Nobody can see it (display asleep, screen locked, covered): no frames.
        guard window?.occlusionState.contains(.visible) ?? false else { return }
        let now = CACurrentMediaTime()
        let every = mood == .asleep || reduceMotion ? 1.0 / 8 : 1.0 / 30
        if now - lastDraw >= every { lastDraw = now; needsDisplay = true }
    }

    /// Scale from the 32-point notch the drawing is laid out on.
    private var k: CGFloat { notchHeight / 32 }
    /// The notch's right edge, in layout points.
    private var edge: CGFloat { notchWidth / k }

    /// Where Drip is, for the cursor: the wing, and the drop below it.
    private var blobRect: NSRect {
        NSRect(x: notchWidth - 8 * k, y: 0, width: (wing + 8) * k,
               height: mood == .needs ? bounds.height : 32 * k)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let t = frozenAt ?? (reduceMotion ? 1.2 : CACurrentMediaTime())
        g.saveGState()
        g.scaleBy(x: k, y: k)
        draw(in: g, t: t, edge: edge)
        g.restoreGState()
    }

    /// For snapshots: each mood beside a stand-in notch over a stand-in
    /// wallpaper, side by side, at three times size, each at a moment that
    /// shows it well. The notch is painted over last, as the real one hides
    /// whatever is drawn there.
    static func sheet() -> NSBitmapImageRep {
        let moods: [(CompanionMood, Double)] = [(.working, 0.3), (.done, 0.15), (.needs, 0.25), (.asleep, 0.5)]
        let nw: CGFloat = 190
        let cell = NSSize(width: nw + DripWindow.side + 40, height: 32 + DripWindow.below + 10), scale: CGFloat = 3
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
            // Stand-in menu bar icons right of the notch, to see what the wing covers.
            let nx = x0 + 20
            NSColor(calibratedWhite: 1, alpha: 0.75).setFill()
            for j in 0..<6 { NSRect(x: nx + nw + 14 + CGFloat(j) * 22, y: cell.height - 20, width: 10, height: 8).fill() }
            let v = DripView(frame: NSRect(x: 0, y: 0, width: nw + DripWindow.side, height: 32 + DripWindow.below))
            v.notchWidth = nw
            v.mood = m; v.frozenAt = t
            let r = NSRect(x: nx, y: cell.height - 32 - DripWindow.below, width: v.frame.width, height: v.frame.height)
            NSGraphicsContext.saveGraphicsState()
            let tr = NSAffineTransform()
            tr.translateX(by: r.minX, yBy: r.maxY); tr.scaleX(by: 1, yBy: -1); tr.concat()
            if let cg = NSGraphicsContext.current?.cgContext {
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            }
            v.draw(v.bounds)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: nx, y: cell.height - 32, width: nw, height: 40), xRadius: 9, yRadius: 9).fill()
            NSRect(x: nx, y: cell.height - 20, width: nw, height: 20).fill()
            NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: nx + nw / 2 - 3.4, y: cell.height - 11 - 3.4, width: 6.8, height: 6.8)).fill()
            let label = NSAttributedString(string: m.rawValue, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.7)])
            label.draw(at: NSPoint(x: x0 + 6, y: 4))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: - drawing, in notch points (the notch is 32 tall and ends at `edge`)

    private static let lilac = CGColor(red: 0.85, green: 0.80, blue: 1.0, alpha: 1)
    private static let amber = CGColor(red: 1.0, green: 0.82, blue: 0.54, alpha: 1)
    private static let ink = CGColor(red: 0.08, green: 0.06, blue: 0.14, alpha: 1)

    /// How far the wing reaches past the notch: narrower while Drip sleeps.
    private var wing: CGFloat = 46

    /// The notch, carried on to the right along the menu bar: square at the
    /// screen's top edge, its bottom in line with the notch's, rounded at the
    /// far end with the same outward flare the notch has at the top.
    private func drawWing(_ g: CGContext, edge: CGFloat, width w: CGFloat) {
        let r: CGFloat = 9, f: CGFloat = 6, h: CGFloat = 32
        let xr = edge + w
        g.setFillColor(.black)
        g.move(to: CGPoint(x: edge - 14, y: 0))
        g.addLine(to: CGPoint(x: xr + f, y: 0))
        g.addQuadCurve(to: CGPoint(x: xr, y: f), control: CGPoint(x: xr, y: 0))
        g.addLine(to: CGPoint(x: xr, y: h - r))
        g.addQuadCurve(to: CGPoint(x: xr - r, y: h), control: CGPoint(x: xr, y: h))
        g.addLine(to: CGPoint(x: edge - 14, y: h))
        g.closePath(); g.fillPath()
    }

    private func draw(in g: CGContext, t: Double, edge: CGFloat) {
        let target: CGFloat = mood == .asleep ? 46 : 80
        wing = frozenAt != nil ? target : wing + (target - wing) * 0.12
        drawWing(g, edge: edge, width: wing)
        let floor: CGFloat = 30, mid = edge + wing / 2
        var x = mid, cy: CGFloat = floor - 9, look: CGFloat = 0
        g.setFillColor(mood == .needs ? Self.amber : Self.lilac)
        switch mood {
        case .working:
            // Across the wing and back, tucking half into the notch at the end.
            let reach = (wing - 6) / 2
            x = edge + reach + reach * CGFloat(sin(t * 0.6))
            look = cos(t * 0.6) > 0 ? 1.5 : -1.5
            let w = CGFloat(sin(t * 4))
            let rx = 13 * (1 + 0.06 * w), ry = 9 * (1 - 0.06 * w)
            cy = floor - ry
            dome(g, x: x, cy: cy, rx: rx, ry: ry, floor: floor)
        case .done:
            let p = (t * 1.5).truncatingRemainder(dividingBy: 1)
            let hop = CGFloat(sin(p * .pi)) * 4
            let land = CGFloat(max(0, 1 - p * 5))
            let rx = 13 * (1 + 0.22 * land), ry = 9 * (1 - 0.22 * land)
            cy = floor - ry - hop
            g.addEllipse(in: CGRect(x: x - rx, y: cy - ry, width: rx * 2, height: ry * 2))
            g.fillPath()
        case .needs:
            let yb: CGFloat = 32
            let sw = CGFloat(sin(t * 2.6))
            let bulbY = yb + 12 + sw * 2, br = 11 - sw * 0.6
            // Spread along the wing's edge, a narrow neck, then the drop.
            g.move(to: CGPoint(x: x - 13, y: yb - 2.5))
            g.addCurve(to: CGPoint(x: x - 4, y: yb + 3), control1: CGPoint(x: x - 6, y: yb - 2), control2: CGPoint(x: x - 4, y: yb))
            g.addCurve(to: CGPoint(x: x - br, y: bulbY), control1: CGPoint(x: x - 4, y: yb + 6), control2: CGPoint(x: x - br, y: bulbY - br * 0.7))
            g.addArc(center: CGPoint(x: x, y: bulbY), radius: br, startAngle: .pi, endAngle: 0, clockwise: true)
            g.addCurve(to: CGPoint(x: x + 4, y: yb + 3), control1: CGPoint(x: x + br, y: bulbY - br * 0.7), control2: CGPoint(x: x + 4, y: yb + 6))
            g.addCurve(to: CGPoint(x: x + 13, y: yb - 2.5), control1: CGPoint(x: x + 4, y: yb), control2: CGPoint(x: x + 6, y: yb - 2))
            g.closePath(); g.fillPath()
            cy = bulbY - 1
        case .asleep:
            let b = CGFloat(sin(t * 1.4)) * 0.8
            let rx = 15 + b, ry = 4.5 - b * 0.3
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
        case .done: sparkles(g, t: t, x: x, y: 8)
        case .needs: bang(g, t: t, x: x + 15, y: 36)
        case .asleep: zs(g, t: t, x: x + 10, y: 28)
        case .working: break
        }
    }

    /// A half-ellipse sitting on the wing's floor.
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
        for (dx, dy, ph) in [(-20.0, 4.0, 0.0), (18, 10, 1.3), (-12, 16, 2.4), (24, 0, 3.1)] {
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

    /// Small z's rising off a sleeping Drip, inside the wing.
    private func zs(_ g: CGContext, t: Double, x: CGFloat, y: CGFloat) {
        for i in 0..<3 {
            let p = (t * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let size = CGFloat(5 + p * 4)
            let s = NSAttributedString(string: "z", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: NSColor(calibratedRed: 0.91, green: 0.93, blue: 0.98, alpha: CGFloat(max(0, 1 - p) * 0.9)),
            ])
            s.draw(at: NSPoint(x: x + CGFloat(p) * 8, y: y - CGFloat(p) * 12 - size))
        }
    }
}
