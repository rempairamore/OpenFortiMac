import Cocoa
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var vpnManager = VPNManager.shared
    private var configManager = ConfigManager.shared
    private var settingsWindow: NSWindow?
    private let panelModel = PanelViewModel()
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Create default config if first launch
        let isFirstLaunch = !FileManager.default.fileExists(atPath: ConfigManager.configPath.path)
        configManager.createDefaultConfig()

        panelModel.openSettings = { [weak self] tab, editor in
            self?.showSettings(tab: tab, editor: editor)
        }
        panelModel.quit = { [weak self] in
            self?.quitApp()
        }

        setupPopover()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusIcon()

        panelModel.refreshSudoersStatus { [weak self] status in
            // Fresh installs (e.g. via Homebrew) land straight on the permission setup
            if isFirstLaunch && (status == .missing || status == .outdated) {
                self?.showSettings(tab: .permission, editor: nil)
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStateChanged),
            name: .vpnStateChanged,
            object: nil
        )
    }

    // MARK: - Menu Bar Panel

    private func setupPopover() {
        let controller = NSHostingController(rootView: MenuPanelView(model: panelModel, vpn: vpnManager))
        // Let the popover follow the SwiftUI content height (servers, banner)
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        // The rule may have changed outside the app since the last check
        panelModel.refreshSudoersStatus()

        // Activate so the panel's keyboard shortcuts (⌘D, ⌘,, ⌘Q) work right away
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Right click keeps a classic menu for quick access.
    private func showContextMenu() {
        popover.performClose(nil)

        let menu = NSMenu()

        if case .connected = vpnManager.state {
            let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnect), keyEquivalent: "d")
            disconnectItem.target = self
            menu.addItem(disconnectItem)
            menu.addItem(NSMenuItem.separator())
        }

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit OpenFortiMac", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Attach the menu only for this click, so a left click keeps opening the panel
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Status Icon

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let symbolName: String
        let description: String

        switch vpnManager.state {
        case .disconnected:
            symbolName = "lock.open"
            description = "Disconnected"
        case .connecting, .disconnecting:
            symbolName = "arrow.triangle.2.circlepath"
            description = "In progress"
        case .connected:
            symbolName = "lock.fill"
            description = "Connected"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) {
            image.isTemplate = true

            // Tint green when connected
            if case .connected = vpnManager.state {
                let config = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
                button.image = image.withSymbolConfiguration(config) ?? image
                button.image?.isTemplate = false
            } else {
                button.image = image
            }
        }
    }

    @objc private func vpnStateChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusIcon()
        }
    }

    // MARK: - Actions

    @objc private func disconnect() {
        vpnManager.disconnect()
    }

    @objc private func openSettings() {
        showSettings(tab: nil, editor: nil)
    }

    /// Opens the settings window, switching to `tab` and opening the server editor when given.
    private func showSettings(tab: SettingsTab?, editor: ServerEditorRequest?) {
        popover.performClose(nil)

        if let existingWindow = settingsWindow {
            if let tab = tab {
                NotificationCenter.default.post(name: .showSettingsTab, object: tab)
            }
            if let editor = editor {
                NotificationCenter.default.post(name: .openServerEditor, object: editor)
            }
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(initialTab: tab ?? .servers, initialEditor: editor)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "OpenFortiMac Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        window.level = .floating
        window.delegate = self

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        if case .connected = vpnManager.state {
            vpnManager.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApp.terminate(nil)
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == settingsWindow {
            settingsWindow = nil
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let vpnStateChanged = Notification.Name("vpnStateChanged")
    static let configChanged = Notification.Name("configChanged")
    static let sudoersChanged = Notification.Name("sudoersChanged")
    static let showSettingsTab = Notification.Name("showSettingsTab")
    static let openServerEditor = Notification.Name("openServerEditor")
}
