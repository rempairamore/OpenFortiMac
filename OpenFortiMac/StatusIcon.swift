import AppKit

/// Draws the menu bar icon in the style chosen in Settings › General.
///
/// Classic: open lock, arrows while connecting, green lock when connected.
///
/// Monochrome: a template shield that follows the menu bar appearance like system icons:
/// - no tunnel: outlined shield
/// - connecting (nothing up yet): half-filled shield
/// - one tunnel up: shield with a checkmark
/// - several tunnels up: filled shield with the count cut out of it
/// - a tunnel up while another one connects: a small dot next to the shield
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image(connected: Int, busy: Int, style: MenuBarIconStyle) -> NSImage {
        switch style {
        case .classic: return classic(connected: connected, busy: busy)
        case .monochrome: return monochrome(connected: connected, busy: busy)
        }
    }

    private static func classic(connected: Int, busy: Int) -> NSImage {
        let symbolName: String
        let description: String

        if connected > 0 {
            symbolName = "lock.fill"
            description = connected == 1 ? "Connected" : "Connected: \(connected) tunnels"
        } else if busy > 0 {
            symbolName = "arrow.triangle.2.circlepath"
            description = "In progress"
        } else {
            symbolName = "lock.open"
            description = "Disconnected"
        }

        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) else {
            return NSImage()
        }
        image.isTemplate = true

        // Tint green when connected
        guard connected > 0 else { return image }
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
        let tinted = image.withSymbolConfiguration(config) ?? image
        tinted.isTemplate = false
        return tinted
    }

    private static func monochrome(connected: Int, busy: Int) -> NSImage {
        let symbolName: String
        let description: String
        var count: String?

        switch connected {
        case 0 where busy > 0:
            symbolName = "shield.lefthalf.filled"
            description = "Connecting"
        case 0:
            symbolName = "shield"
            description = "Disconnected"
        case 1:
            symbolName = "checkmark.shield.fill"
            description = "Connected: 1 tunnel"
        default:
            symbolName = "shield.fill"
            description = "Connected: \(connected) tunnels"
            count = connected > 9 ? "+" : String(connected)
        }

        let showsActivity = connected > 0 && busy > 0
        let width = showsActivity ? size.width + 4.5 : size.width

        let image = NSImage(size: NSSize(width: width, height: size.height), flipped: false) { _ in
            let shieldRect = NSRect(origin: .zero, size: size)
            drawSymbol(symbolName, in: shieldRect)

            if let count = count {
                cutOut(count, in: shieldRect)
            }

            if showsActivity {
                let dot = NSRect(x: size.width + 0.5, y: 2, width: 4, height: 4)
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    private static func drawSymbol(_ name: String, in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }

        let symbolSize = symbol.size
        let origin = NSPoint(
            x: rect.midX - symbolSize.width / 2,
            y: rect.midY - symbolSize.height / 2
        )
        symbol.draw(in: NSRect(origin: origin, size: symbolSize))
    }

    /// Punches the text out of what is already drawn, so the menu bar shows through it.
    private static func cutOut(_ text: String, in rect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        // The shield tapers towards the bottom: sit the digit slightly above center
        let origin = NSPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2 + 0.5
        )
        string.draw(at: origin)

        context.restoreGraphicsState()
    }
}
