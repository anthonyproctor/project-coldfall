import AppKit
import ColdfallCore

/// The four marks for what a desk is doing, drawn the same way everywhere
/// (desk list, tabs, pane headers, groups, status bar), after Herdr's:
///
///   Needs you   an amber pill with the words, the one that should be read
///   working     a blue ring, still (a turning one is the busiest thing on screen)
///   done        a small green dot: an answer you haven't seen
///   idle        a hollow circle: running, nothing new
///
/// A desk that isn't running has no mark.
enum Mark: Equatable {
    case needsYou, working, done, idle, asleep, none

    init(_ s: DeskStatus) {
        guard s.running else { self = s.asleep ? .asleep : .none; return }
        switch s.activity {
        case .blocked: self = .needsYou
        case .working: self = .working
        case .ready: self = .done
        case .quiet: self = .idle
        }
    }
}

final class MarkView: NSView {
    var mark: Mark = .none { didSet { if mark != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    /// The pill's words; "Needs you" unless a count is wanted ("2 need you").
    /// Needs you as a small "!" instead of the words, where the words are
    /// already said beside it (the reason in a desk's row).
    var compact = false { didSet { if compact != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var pillText = "Needs you" { didSet { if pillText != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }

    static let amber = NSColor(srgbRed: 0.91, green: 0.65, blue: 0.29, alpha: 1)
    static let green = NSColor.systemGreen
    static var blue: NSColor { Theme.ui.accent }

    /// Amber as text. On a pale ground the mark's amber washes out; a
    /// darker one reads there.
    static var pillInk: NSColor { Theme.isDark ? amber : NSColor(srgbRed: 0.62, green: 0.36, blue: 0.02, alpha: 1) }

    private var pillAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: MarkView.pillInk]
    }

    override var intrinsicContentSize: NSSize {
        switch mark {
        case .needsYou:
            if compact { return NSSize(width: 16, height: 16) }
            let w = (pillText as NSString).size(withAttributes: pillAttrs).width
            return NSSize(width: ceil(w) + 12, height: 16)
        case .none: return NSSize(width: 0, height: 10)
        default: return NSSize(width: 10, height: 10)
        }
    }

    override func draw(_ dirty: NSRect) {
        let b = bounds
        let c = NSPoint(x: b.midX, y: b.midY)
        switch mark {
        case .needsYou:
            let r = NSRect(x: 0, y: (b.height - 16) / 2, width: b.width, height: 16)
            MarkView.amber.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4.5, yRadius: 4.5).fill()
            let t = (compact ? "!" : pillText) as NSString
            let sz = t.size(withAttributes: pillAttrs)
            t.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: pillAttrs)
        case .working:
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: 4.2, startAngle: 120, endAngle: 420)
            p.lineWidth = 1.6
            p.lineCapStyle = .round
            MarkView.blue.setStroke(); p.stroke()
        case .done:
            MarkView.green.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)).fill()
        case .idle:
            let p = NSBezierPath(ovalIn: NSRect(x: c.x - 3.6, y: c.y - 3.6, width: 7.2, height: 7.2))
            p.lineWidth = 1.3
            Theme.ui.dimText.withAlphaComponent(0.8).setStroke(); p.stroke()
        case .asleep:
            // A small moon: put to sleep, and it wakes where it left off.
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
            if let moon = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "Asleep")?.withSymbolConfiguration(cfg) {
                let tinted = NSImage(size: moon.size, flipped: false) { r in
                    moon.draw(in: r)
                    Theme.ui.dimText.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: c.x - moon.size.width / 2, y: c.y - moon.size.height / 2, width: moon.size.width, height: moon.size.height))
            }
        case .none: break
        }
    }
}

/// A desk's own colour (see DeskColor), as something to draw with.
enum DeskTint {
    static func color(_ value: String?) -> NSColor? {
        guard let rgb = DeskColor.rgb(value) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                       blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
    /// `base` with the desk's colour washed into it.
    static func wash(_ base: NSColor, _ value: String?, amount: Double = DeskColor.wash) -> NSColor {
        guard let t = color(value) else { return base }
        return base.blended(withFraction: CGFloat(amount), of: t) ?? base
    }
    /// A small round swatch, for the Colour menu.
    static func swatch(_ c: NSColor?) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            if let c { c.setFill(); p.fill() } else { NSColor.secondaryLabelColor.setStroke(); p.lineWidth = 1; p.stroke() }
            return true
        }
    }
}

/// A desk's vendor, as a picture: the real logo from ~/.config/coldfall/icons
/// when the person has put one there, otherwise a letter on the vendor's
/// colour (or the desk's own emoji). Rounded, and cached by what it shows.
enum VendorIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(runtime: String, icon: String?, size: CGFloat = 16) -> NSImage {
        let file = VendorBadge.iconFile(runtime: runtime, icon: icon)
        let key = "\(file ?? "letter:\(runtime):\(icon ?? "")")@\(size)"
        if let hit = cache[key] { return hit }
        let img: NSImage
        if let f = file, let pic = NSImage(contentsOfFile: f) {
            img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
                NSBezierPath(roundedRect: r, xRadius: size * 0.22, yRadius: size * 0.22).addClip()
                pic.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
        } else {
            let b = VendorBadge.badge(runtime: runtime, icon: icon)
            img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
                if let hex = b.fill {
                    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                            blue: CGFloat(hex & 0xff) / 255, alpha: 1).setFill()
                    NSBezierPath(roundedRect: r, xRadius: size * 0.25, yRadius: size * 0.25).fill()
                }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size * (b.fill == nil ? 0.78 : 0.62), weight: .bold),
                    .foregroundColor: b.fill == nil ? Theme.ui.dimText : NSColor.white,
                ]
                let t = b.text as NSString
                let sz = t.size(withAttributes: attrs)
                t.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
                return true
            }
        }
        cache[key] = img
        return img
    }

    /// Forget cached pictures, so a logo just dropped into the folder shows.
    static func reload() { cache = [:] }
}
