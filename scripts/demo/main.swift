import AppKit
import SwiftUI

// Renders the pictures of the README and of the site from the app's real views, with
// example data. Compiled together with the app's sources by scripts/make_panel_demo.py:
//
//     demo <output dir>
//
// Writes the frames of the animated demo (frame-NNN.png and frames.json with their
// durations) and the still pictures. Nothing here ships in the app.

let outDir = CommandLine.arguments[1]
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Never the real Keychain items: these names do not exist
KeychainHelper.legacyService = "com.openfortimac.demo.none"
KeychainHelper.vaultService = "com.openfortimac.demo.none"

// MARK: - Example data

let office = VPNServer(name: "Office VPN", host: "vpn.example.com", port: 443, username: "john.doe",
                       trustedCert: nil, realm: nil, icon: "building.2", id: "demo-office")
let home = VPNServer(name: "Home Lab", host: "home.example.net", port: 10443, username: "mario",
                     trustedCert: nil, icon: "house", id: "demo-home")
let customer = VPNServer(name: "Customer Acme", host: "ssl.acme.example", port: 443, username: "",
                         trustedCert: nil, icon: "briefcase", singleSignOn: true, id: "demo-customer")
let servers = [office, home, customer]

let vpn = VPNManager.shared
let model = PanelViewModel()

// MARK: - Geometry (points; everything is drawn at two pixels per point)

let scale: CGFloat = 2
let panelWidth: CGFloat = 320
let margin: CGFloat = 18
let menuBarHeight: CGFloat = 24
let arrowHeight: CGFloat = 10
let arrowHalfWidth: CGFloat = 12
let panelTop = menuBarHeight + 4 + arrowHeight
let canvasWidth = panelWidth + margin * 2
let iconX = margin + panelWidth / 2
/// The page background of the site, so the pictures sit on it without a frame
let page = NSColor(hex: 0x0c0e12)

// MARK: - Rendering the real views

/// Draws a SwiftUI view off screen, in the theme that is current.
func render<V: View>(_ view: V, settle: TimeInterval = 0.6) -> NSImage {
    let hosting = NSHostingView(rootView: view)
    let size = hosting.fittingSize
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = ThemeManager.shared.theme.appearance
    window.isOpaque = false
    window.backgroundColor = .clear
    window.contentView = hosting
    window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(settle))

    let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)
    hosting.displayIgnoringOpacity(hosting.bounds, in: NSGraphicsContext(cgContext: context, flipped: false))
    window.orderOut(nil)
    return NSImage(cgImage: context.makeImage()!, size: size)
}

func panelImage() -> NSImage {
    render(MenuPanelView(model: model, vpn: vpn))
}

// MARK: - Drawing a frame

final class Canvas {
    let size: CGSize
    let context: CGContext

    init(width: CGFloat, height: CGFloat, background: NSColor) {
        size = CGSize(width: width, height: height)
        context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        draw {
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
    }

    func draw(_ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A rectangle given from the top-left corner, as one reads a screen
    func rect(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: x, y: size.height - top - height, width: width, height: height)
    }

    func write(_ name: String) {
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImage {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color])))!
}

/// What the menu bar does with a template image: paint it in its own text color.
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    guard image.isTemplate else { return image }
    return NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceIn)
        return true
    }
}

enum BarIcon {
    case disconnected
    case busy(CGFloat)
    case connected

    var image: NSImage {
        switch self {
        case .disconnected: return StatusIcon.disconnected(description: "")!
        case .busy(let progress): return StatusIcon.busy(progress: progress, description: "")!
        case .connected: return StatusIcon.connected(description: "")!
        }
    }
}

func drawCentered(_ image: NSImage, x: CGFloat, y: CGFloat, alpha: CGFloat = 1) {
    let size = image.size
    image.draw(in: NSRect(x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height),
               from: .zero, operation: .sourceOver, fraction: alpha)
}

/// The menu bar, with the app's icon above the middle of the panel and the usual neighbours.
func drawMenuBar(on canvas: Canvas, icon: BarIcon, highlighted: Bool) {
    canvas.draw {
        NSColor(white: 1, alpha: 0.055).setFill()
        canvas.rect(x: 0, top: 0, width: canvas.size.width, height: menuBarHeight).fill()
        let y = canvas.size.height - menuBarHeight / 2
        let ink = NSColor.white
        if highlighted {
            NSColor(white: 1, alpha: 0.2).setFill()
            NSBezierPath(roundedRect: NSRect(x: iconX - 15, y: y - 10, width: 30, height: 20), xRadius: 5, yRadius: 5).fill()
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            drawCentered(tinted(icon.image, ink), x: iconX, y: y)
        }
        drawCentered(symbol("icloud", size: 13, weight: .medium, color: ink), x: iconX - 36, y: y)
        drawCentered(symbol("wifi", size: 13, weight: .medium, color: ink), x: iconX + 36, y: y)
        drawCentered(symbol("battery.75", size: 15, color: ink), x: iconX + 70, y: y)
        let clock = NSAttributedString(string: "Mon 22:58", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ink])
        clock.draw(at: NSPoint(x: canvas.size.width - clock.size().width - 10, y: y - clock.size().height / 2))
    }
}

/// The popover: a rounded box with an arrow that points at the icon, and the real panel in it.
func drawPopover(on canvas: Canvas, panel: NSImage, x: CGFloat, top: CGFloat, arrowX: CGFloat?, alpha: CGFloat = 1) {
    let palette = ThemeManager.shared.theme.palette
    let isLight = ThemeManager.shared.theme == .light
    let fill = palette.panel ?? NSColor(hex: 0xececec)
    let box = canvas.rect(x: x, top: top, width: panel.size.width, height: panel.size.height)

    let shape = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
    if let arrowX = arrowX {
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: arrowX - arrowHalfWidth, y: box.maxY - 0.5))
        arrow.line(to: NSPoint(x: arrowX - 2, y: box.maxY + arrowHeight - 1.5))
        arrow.curve(to: NSPoint(x: arrowX + 2, y: box.maxY + arrowHeight - 1.5),
                    controlPoint1: NSPoint(x: arrowX - 0.8, y: box.maxY + arrowHeight),
                    controlPoint2: NSPoint(x: arrowX + 0.8, y: box.maxY + arrowHeight))
        arrow.line(to: NSPoint(x: arrowX + arrowHalfWidth, y: box.maxY - 0.5))
        arrow.close()
        shape.append(arrow)
    }

    canvas.draw {
        let context = NSGraphicsContext.current!.cgContext
        context.setAlpha(alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.5)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -7)
        shadow.set()
        fill.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).addClip()
        panel.draw(in: box)
        NSGraphicsContext.restoreGraphicsState()

        (isLight ? NSColor(white: 0, alpha: 0.16) : NSColor(white: 1, alpha: 0.14)).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()

        context.endTransparencyLayer()
        context.setAlpha(1)
    }
}

/// The real arrow pointer, with its tip at `point` (given from the top-left corner).
func drawPointer(on canvas: Canvas, at point: CGPoint, pressed: Bool) {
    let cursor = NSCursor.arrow
    let size = cursor.image.size
    canvas.draw {
        if pressed {
            NSColor(white: 1, alpha: 0.22).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 11, y: canvas.size.height - point.y - 11, width: 22, height: 22)).fill()
        }
        cursor.image.draw(in: NSRect(x: point.x - cursor.hotSpot.x,
                                     y: canvas.size.height - point.y + cursor.hotSpot.y - size.height,
                                     width: size.width, height: size.height))
    }
}

// MARK: - The animated demo

ThemeManager.shared.theme = .dark

func showIdle(hover: Bool = false) -> NSImage {
    PanelPreview.hoveredServerID = hover ? office.id : nil
    model.setPreview(servers: servers)
    vpn.setPreview(state: .disconnected)
    let image = panelImage()
    PanelPreview.hoveredServerID = nil
    return image
}

func showConnecting() -> NSImage {
    model.setPreview(servers: servers)
    vpn.setPreview(state: .connecting, server: office)
    return panelImage()
}

func showConnected(seconds: Int) -> NSImage {
    model.setPreview(servers: servers)
    // A little more than the whole second, so the clock in the panel shows exactly that
    vpn.setPreview(state: .connected(serverName: office.name), server: office,
                   since: Date().addingTimeInterval(-Double(seconds) - 0.25), ip: "10.212.134.5",
                   traffic: TunnelTraffic(received: UInt64(seconds) * 412_000 + 96_000, sent: UInt64(seconds) * 58_000 + 21_000))
    return panelImage()
}

let idle = showIdle()
let idleHover = showIdle(hover: true)
let connecting = showConnecting()
let connected = (1...4).map { showConnected(seconds: $0) }

let tallest = ([idle, idleHover, connecting] + connected).map(\.size.height).max()!
let canvasHeight = (panelTop + tallest + 22).rounded(.up)

struct Frame {
    var icon: BarIcon = .disconnected
    var open = false
    var panel: NSImage?
    var alpha: CGFloat = 1
    var lift: CGFloat = 0
    var pointer: CGPoint
    var pressed = false
    var duration: Double
}

func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}
func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

let start = CGPoint(x: canvasWidth * 0.72, y: 250)
let onIcon = CGPoint(x: iconX + 2, y: menuBarHeight / 2 + 3)
/// Over "Connect", at the right end of the first server row
let onConnect = CGPoint(x: margin + panelWidth - 46, y: panelTop + 118)
let away = CGPoint(x: canvasWidth * 0.80, y: panelTop + 236)

var frames: [Frame] = []

// 1. The menu bar, the pointer goes to the shield and clicks
frames.append(Frame(pointer: start, duration: 1.0))
for step in 1...12 {
    frames.append(Frame(pointer: lerp(start, onIcon, ease(CGFloat(step) / 12)), duration: 0.04))
}
frames.append(Frame(pointer: onIcon, duration: 0.3))
frames.append(Frame(open: true, pointer: onIcon, pressed: true, duration: 0.15))

// 2. The panel comes in under the icon
for (alpha, lift) in [(CGFloat(0.35), CGFloat(6)), (0.7, 3), (1, 0)] {
    frames.append(Frame(open: true, panel: idle, alpha: alpha, lift: lift, pointer: onIcon, duration: 0.05))
}
frames.append(Frame(open: true, panel: idle, pointer: onIcon, duration: 0.5))

// 3. To Office VPN, where "Connect" shows up, and click
for step in 1...14 {
    let point = lerp(onIcon, onConnect, ease(CGFloat(step) / 14))
    let overRow = point.y > panelTop + 96
    frames.append(Frame(open: true, panel: overRow ? idleHover : idle, pointer: point, duration: 0.04))
}
frames.append(Frame(open: true, panel: idleHover, pointer: onConnect, duration: 0.7))
frames.append(Frame(open: true, panel: idleHover, pointer: onConnect, pressed: true, duration: 0.18))

// 4. Connecting: the shield fills up and empties
let busySteps = 20
for step in 0..<busySteps {
    let phase = CGFloat(step) / CGFloat(busySteps)
    let wave = phase < 0.5 ? phase * 2 : (1 - phase) * 2
    let point = lerp(onConnect, away, ease(min(1, CGFloat(step) / 9)))
    frames.append(Frame(icon: .busy(ease(wave)), open: true, panel: connecting, pointer: point, duration: 0.09))
}

// 5. Connected: green shield, the clock and the traffic move
for (index, panel) in connected.enumerated() {
    frames.append(Frame(icon: .connected, open: true, panel: panel, pointer: away,
                        duration: index == connected.count - 1 ? 2.2 : 1.0))
}

var durations: [Double] = []
for (index, frame) in frames.enumerated() {
    let canvas = Canvas(width: canvasWidth, height: canvasHeight, background: page)
    drawMenuBar(on: canvas, icon: frame.icon, highlighted: frame.open)
    if let panel = frame.panel {
        drawPopover(on: canvas, panel: panel, x: margin, top: panelTop - frame.lift, arrowX: iconX, alpha: frame.alpha)
    }
    drawPointer(on: canvas, at: frame.pointer, pressed: frame.pressed)
    canvas.write(String(format: "frame-%03d.png", index))
    durations.append(frame.duration)
}
try! JSONSerialization.data(withJSONObject: ["durations": durations, "width": canvasWidth, "height": canvasHeight])
    .write(to: URL(fileURLWithPath: "\(outDir)/frames.json"))

// MARK: - Still pictures

/// The three themes side by side, each on a different moment of the panel.
func themesPicture() {
    func codeEntry() -> NSImage {
        PanelPreview.code = "492 031"
        model.setPreview(servers: servers)
        vpn.setPreview(state: .connecting, server: office, pendingInput: .code)
        let image = panelImage()
        PanelPreview.code = ""
        return image
    }
    func notices() -> NSImage {
        vpn.setPreview(state: .disconnected)
        model.setPreview(servers: servers, leftoverTunnels: [4242],
                         update: AvailableUpdate(version: "1.5.0", page: UpdateChecker.releasesPage))
        return panelImage()
    }

    ThemeManager.shared.theme = .light
    let light = codeEntry()
    ThemeManager.shared.theme = .dark
    let dark = showConnected(seconds: 5047)
    ThemeManager.shared.theme = .dracula
    let dracula = notices()

    let gap: CGFloat = 28
    let panels: [(AppTheme, NSImage)] = [(.light, light), (.dark, dark), (.dracula, dracula)]
    let height = panels.map(\.1.size.height).max()! + gap * 2 + 8
    let canvas = Canvas(width: panelWidth * 3 + gap * 4, height: height, background: page)
    for (index, entry) in panels.enumerated() {
        ThemeManager.shared.theme = entry.0
        drawPopover(on: canvas, panel: entry.1, x: gap + CGFloat(index) * (panelWidth + gap), top: gap, arrowX: nil)
    }
    canvas.write("themes.png")
}
themesPicture()

/// The connected panel alone, for the link preview of the site.
ThemeManager.shared.theme = .dark
let preview = showConnected(seconds: 5047)
let previewCanvas = Canvas(width: preview.size.width, height: preview.size.height, background: NSColor(hex: 0x2a2a2e))
previewCanvas.draw { preview.draw(in: NSRect(origin: .zero, size: preview.size)) }
previewCanvas.write("panel-connected.png")

print("frames: \(frames.count), \(String(format: "%.1f", durations.reduce(0, +))) s, \(Int(canvasWidth))x\(Int(canvasHeight)) points")
