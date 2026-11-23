import AppKit
import Combine
import SwiftUI

/// The look of the app, chosen in Settings. It does not follow the appearance of the Mac.
enum AppTheme: String, CaseIterable, Identifiable {
    case light
    case dark
    case dracula

    var id: String { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .dracula: return "Dracula"
        }
    }

    /// Dracula is a dark appearance with its own colors on top
    var appearance: NSAppearance? {
        NSAppearance(named: self == .light ? .aqua : .darkAqua)
    }

    var palette: Palette {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .dracula: return .dracula
        }
    }
}

/// The colors the views draw with. Light and dark are what macOS gives; dark only makes
/// the panel solid, where macOS would let the desktop show through.
struct Palette {
    /// Behind the menu bar panel; nil keeps the material of macOS
    let panel: NSColor?
    /// Behind the windows; nil keeps the one of macOS
    let background: NSColor?
    /// Boxes inside the panel
    let card: Color
    /// Rows of a grouped form; nil keeps the ones of macOS
    let row: Color?
    /// Text fields and the log
    let inset: Color
    /// The strip under a list
    let bar: Color
    let accent: Color
    /// Text on a surface filled with the accent
    let onAccent: Color
    let good: Color
    let bad: Color
    let busy: Color
    let warning: Color
    let news: Color

    var backgroundColor: Color? {
        background.map { Color(nsColor: $0) }
    }

    static let light = Palette(
        panel: nil,
        background: nil,
        card: Color.primary.opacity(0.05),
        row: nil,
        inset: Color(NSColor.textBackgroundColor),
        bar: Color(NSColor.controlBackgroundColor),
        accent: .accentColor,
        onAccent: .white,
        good: .green,
        bad: .red,
        busy: .orange,
        warning: .orange,
        news: .blue
    )

    static let dark = Palette(
        panel: NSColor(hex: 0x2a2a2e),
        background: nil,
        card: Color.primary.opacity(0.05),
        row: nil,
        inset: Color(NSColor.textBackgroundColor),
        bar: Color(NSColor.controlBackgroundColor),
        accent: .accentColor,
        onAccent: .white,
        good: .green,
        bad: .red,
        busy: .orange,
        warning: .orange,
        news: .blue
    )

    /// https://draculatheme.com/contribute: background, current line, purple, green, red, orange, yellow, cyan
    static let dracula = Palette(
        panel: NSColor(hex: 0x282a36),
        background: NSColor(hex: 0x282a36),
        card: Color(hex: 0x44475a).opacity(0.6),
        row: Color(hex: 0x343746),
        inset: Color(hex: 0x21222c),
        bar: Color(hex: 0x21222c),
        accent: Color(hex: 0xbd93f9),
        onAccent: Color(hex: 0x282a36),
        good: Color(hex: 0x50fa7b),
        bad: Color(hex: 0xff5555),
        busy: Color(hex: 0xffb86c),
        warning: Color(hex: 0xf1fa8c),
        news: Color(hex: 0x8be9fd)
    )
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

/// Holds the chosen theme and applies it to the whole app.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    private static let defaultsKey = "theme"

    @Published var theme: AppTheme {
        didSet {
            guard oldValue != theme else { return }
            UserDefaults.standard.set(theme.rawValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(AppTheme.init(rawValue:))
        // Dark is the look of the screenshots on the site
        theme = saved ?? .dark
    }

    /// Menus, windows and the panel take the appearance from the app; the windows that are
    /// open also hear about the colors.
    func apply() {
        NSApp?.appearance = theme.appearance
        NotificationCenter.default.post(name: .themeChanged, object: nil)
    }
}

// MARK: - SwiftUI

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.light
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// What a themed root view is, which decides the background it gets.
enum ThemedSurface {
    /// The panel under the menu bar
    case panel
    /// A window
    case window
    /// Something that paints its own background, like a sheet
    case custom
}

/// Put on the root of a window: hands the palette down and repaints when the theme changes.
private struct Themed: ViewModifier {
    @ObservedObject private var manager = ThemeManager.shared
    let surface: ThemedSurface

    func body(content: Content) -> some View {
        let palette = manager.theme.palette
        content
            .background(background(in: palette).map { Color(nsColor: $0) } ?? .clear)
            .environment(\.palette, palette)
            .tint(palette.accent)
    }

    private func background(in palette: Palette) -> NSColor? {
        switch surface {
        case .panel: return palette.panel
        case .window: return palette.background
        case .custom: return nil
        }
    }
}

/// Form rows in the palette's color, when it has one.
private struct ThemedForm: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        if palette.background != nil {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}

extension View {
    func themed(_ surface: ThemedSurface) -> some View {
        modifier(Themed(surface: surface))
    }

    /// For a grouped Form: lets the window's own background show through in themes that have one.
    func themedForm() -> some View {
        modifier(ThemedForm())
    }
}
