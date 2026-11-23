import SwiftUI

@main
enum Main {
    static func main() {
        // First thing: the interface language is fixed as soon as a text is looked up
        AppLanguage.applyAtLaunch()
        OpenFortiMacApp.main()
    }
}

struct OpenFortiMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
