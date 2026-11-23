import AppKit

/// The language of the interface. OpenFortiMac is in English unless another language is
/// picked in Settings: it does not follow the language of the Mac.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case italian = "it"

    var id: String { rawValue }

    /// Shown in the picker, each in its own language
    var name: String {
        switch self {
        case .english: return "English"
        case .italian: return "Italiano"
        }
    }

    /// macOS reads this key, in the app's own preferences, to choose the language of an app.
    /// System Settings › Language & Region › Applications writes the same key.
    private static let defaultsKey = "AppleLanguages"

    private init?(code: String?) {
        guard let code = code?.lowercased() else { return nil }
        if code.hasPrefix("it") {
            self = .italian
        } else if code.hasPrefix("en") {
            self = .english
        } else {
            return nil
        }
    }

    /// What the app's own preferences say, leaving out the languages of the Mac
    private static var storedCodes: [String]? {
        guard let domain = Bundle.main.bundleIdentifier else { return nil }
        return UserDefaults.standard.persistentDomain(forName: domain)?[defaultsKey] as? [String]
    }

    /// The language for the next launch.
    static var selected: AppLanguage {
        get { AppLanguage(code: storedCodes?.first) ?? .english }
        set { UserDefaults.standard.set([newValue.rawValue], forKey: defaultsKey) }
    }

    /// The language the interface is using now: it is fixed when the app starts.
    static var running: AppLanguage {
        AppLanguage(code: Bundle.main.preferredLocalizations.first) ?? .english
    }

    /// Must run before the first text is looked up. With nothing chosen yet macOS would
    /// use the language of the Mac, so the choice is written first: English.
    static func applyAtLaunch() {
        if storedCodes == nil {
            selected = .english
        }
    }

    /// Quits (which disconnects the VPN first) and opens the app again once it has gone.
    static func restartApp() {
        let waitAndOpen = Process()
        waitAndOpen.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The pid and the path are arguments, never part of the script text.
        // -n because Launch Services may still list the copy that has just quit, and would only activate it
        waitAndOpen.arguments = [
            "-c",
            "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open -n \"$1\"",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundlePath,
        ]
        do {
            try waitAndOpen.run()
        } catch {
            // Without the helper the app would quit and stay closed
            return
        }
        NSApp.terminate(nil)
    }
}
