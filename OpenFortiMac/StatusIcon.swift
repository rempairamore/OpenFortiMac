import AppKit

/// The menu bar icon: a shield that is always clearly there, with a small badge at its
/// bottom right for the state. A ring while there is no VPN, an orange dot that pulses
/// while a connection is being set up or taken down; connected, the whole shield turns
/// green and carries a check.
enum StatusIcon {
    private static let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)

    /// Room around the shield for the badge, which reaches a little past its edge. The same on
    /// both sides, so the shield stays in the middle and the icon never moves between states.
    private static let sideMargin: CGFloat = 1.5
    private static let verticalMargin: CGFloat = 0.5

    /// Radius of the hole the badge sits in, of the ring, and of the dot at rest and at its largest
    private static let holeRadius: CGFloat = 4.1
    private static let ringRadius: CGFloat = 2.3
    private static let ringWidth: CGFloat = 1.3
    private static let dotRadius: ClosedRange<CGFloat> = 2.1...2.9

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    private struct Layout {
        let size: NSSize
        let shield: NSRect
        let badge: NSPoint
    }

    private static func layout(for shield: NSImage) -> Layout {
        let size = NSSize(width: shield.size.width + sideMargin * 2, height: shield.size.height + verticalMargin * 2)
        let rect = NSRect(x: sideMargin, y: verticalMargin, width: shield.size.width, height: shield.size.height)
        return Layout(size: size, shield: rect, badge: NSPoint(x: rect.maxX - 1.6, y: rect.minY + 2.6))
    }

    /// Draws on a layer of its own: cutting the hole for the badge then cuts the icon,
    /// not whatever is behind it in the menu bar.
    private static func image(size: NSSize, template: Bool, description: String, _ draw: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            draw()
            context.endTransparencyLayer()
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = description
        return image
    }

    private static func cutHole(at center: NSPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.fillEllipse(in: circle(center, holeRadius))
        context.restoreGState()
    }

    private static func circle(_ center: NSPoint, _ radius: CGFloat) -> NSRect {
        NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    /// A template image: macOS draws it white or black to suit the menu bar.
    static func disconnected(description: String) -> NSImage? {
        guard let shield = symbol("shield.fill") else { return nil }
        let layout = layout(for: shield)
        return image(size: layout.size, template: true, description: description) {
            shield.draw(in: layout.shield)
            cutHole(at: layout.badge)
            let ring = NSBezierPath(ovalIn: circle(layout.badge, ringRadius))
            ring.lineWidth = ringWidth
            NSColor.black.setStroke()
            ring.stroke()
        }
    }

    /// The shield with an orange dot that grows and shrinks with `progress` (0 to 1).
    /// Two colors, so it cannot be a template: the shield takes the menu bar's own color.
    static func busy(progress: CGFloat, description: String) -> NSImage? {
        guard let shield = symbol("shield.fill") else { return nil }
        let layout = layout(for: shield)
        let radius = dotRadius.lowerBound + (dotRadius.upperBound - dotRadius.lowerBound) * min(max(progress, 0), 1)
        return image(size: layout.size, template: false, description: description) {
            // Runs when the menu bar draws the icon, so this is the bar's appearance of that moment
            let onDarkBar = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            shield.draw(in: layout.shield)
            (onDarkBar ? NSColor.white : NSColor.black).set()
            layout.shield.fill(using: .sourceIn)
            cutHole(at: layout.badge)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: circle(layout.badge, radius)).fill()
        }
    }

    /// Green, with the check cut out of the shield so the menu bar shows through it.
    static func connected(description: String) -> NSImage? {
        // Drawn in one color the symbol has the check as a hole; a palette would paint it
        guard let shield = symbol("checkmark.shield.fill"), let plain = symbol("shield.fill") else { return nil }
        let layout = layout(for: plain)
        return image(size: layout.size, template: false, description: description) {
            let rect = NSRect(x: layout.shield.midX - shield.size.width / 2, y: layout.shield.midY - shield.size.height / 2,
                              width: shield.size.width, height: shield.size.height)
            shield.draw(in: rect)
            NSColor.systemGreen.set()
            rect.fill(using: .sourceIn)
        }
    }
}
