import AppKit

/// The menu bar icon: a shield. Dimmed while there is no VPN, filling up and emptying while
/// a connection is being set up or taken down, green with a check when connected.
enum StatusIcon {
    private static let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    /// A template image: macOS draws it white or black to suit the menu bar. Half of the
    /// opacity is in the image itself, so it reads as "off".
    static func disconnected(description: String) -> NSImage? {
        guard let shield = symbol("shield.fill") else { return nil }
        let image = NSImage(size: shield.size, flipped: false) { rect in
            shield.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.5)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    /// The outline of the shield, filled from the left up to `progress` (0 to 1).
    static func busy(progress: CGFloat, description: String) -> NSImage? {
        guard let outline = symbol("shield"), let filled = symbol("shield.fill") else { return nil }
        let size = NSSize(width: max(outline.size.width, filled.size.width),
                          height: max(outline.size.height, filled.size.height))
        let image = NSImage(size: size, flipped: false) { rect in
            draw(outline, centeredIn: rect)
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width * progress, height: rect.height)).addClip()
            draw(filled, centeredIn: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    /// Green, with the check cut out of the shield so the menu bar shows through it.
    static func connected(description: String) -> NSImage? {
        // Drawn in one color the symbol has the check as a hole; a palette would paint it
        guard let shield = symbol("checkmark.shield.fill") else { return nil }
        let image = NSImage(size: shield.size, flipped: false) { rect in
            shield.draw(in: rect)
            NSColor.systemGreen.set()
            rect.fill(using: .sourceIn)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = description
        return image
    }

    private static func draw(_ image: NSImage, centeredIn rect: NSRect) {
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
    }
}
