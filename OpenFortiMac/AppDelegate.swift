import Cocoa
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var vpnManager = VPNManager.shared
    private var configManager = ConfigManager.shared
    private var settingsWindow: NSWindow?
    private var sudoersStatus: SudoersStatus?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Create default config if first launch
        let isFirstLaunch = !FileManager.default.fileExists(atPath: ConfigManager.configPath.path)
        configManager.createDefaultConfig()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        updateStatusIcon()
        setupMenu()

        refreshSudoersStatus { [weak self] status in
            // Fresh installs (e.g. via Homebrew) land straight on the permission setup
            if isFirstLaunch && (status == .missing || status == .outdated) {
                self?.showSettings(tab: .general)
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sudoersDidChange(_:)),
            name: .sudoersChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStateChanged),
            name: .vpnStateChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configDidChange),
            name: .configChanged,
            object: nil
        )
    }
    
    @objc private func configDidChange() {
        configManager.reload()
        setupMenu()
    }

    @objc private func sudoersDidChange(_ notification: Notification) {
        guard let status = notification.object as? SudoersStatus else { return }
        sudoersStatus = status
        setupMenu()
    }

    private func refreshSudoersStatus(completion: ((SudoersStatus) -> Void)? = nil) {
        let path = vpnManager.findOpenfortivpnBinary()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = SudoersManager.shared.status(for: path)
            DispatchQueue.main.async {
                self?.sudoersStatus = status
                self?.setupMenu()
                completion?(status)
            }
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        // Status
        let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusMenuItem.attributedTitle = statusAttributedTitle()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // Setup warning
        if let warning = setupWarning() {
            let warningItem = NSMenuItem(title: warning, action: #selector(openGeneralSettings), keyEquivalent: "")
            warningItem.target = self
            menu.addItem(warningItem)
        }

        menu.addItem(NSMenuItem.separator())
        
        // Server list
        let servers = configManager.config.servers
        let isDisconnected = vpnManager.state == .disconnected
        
        if servers.isEmpty {
            let noServersItem = NSMenuItem(title: "No servers — Open Settings", action: #selector(openSettings), keyEquivalent: "")
            noServersItem.target = self
            noServersItem.isEnabled = isDisconnected
            menu.addItem(noServersItem)
        } else {
            for (index, server) in servers.enumerated() {
                let serverItem = NSMenuItem(
                    title: server.name,
                    action: #selector(connectToServer(_:)),
                    keyEquivalent: ""
                )
                serverItem.tag = index
                
                if isDisconnected {
                    serverItem.target = self
                    serverItem.action = #selector(connectToServer(_:))
                } else {
                    serverItem.target = nil
                    serverItem.action = nil
                    if case .connected(let connectedName) = vpnManager.state, connectedName == server.name {
                        serverItem.state = .on
                    }
                }

                
                menu.addItem(serverItem)
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Disconnect
        let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnect), keyEquivalent: "d")
        disconnectItem.target = self
        disconnectItem.isEnabled = {
            if case .connected = vpnManager.state { return true }
            return false
        }()
        menu.addItem(disconnectItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.isEnabled = isDisconnected
        menu.addItem(settingsItem)
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        self.statusItem.menu = menu
    }
    
    private func setupWarning() -> String? {
        switch sudoersStatus {
        case .missing, .outdated:
            return "⚠️ Setup required — Open Settings"
        case .binaryNotFound:
            return "⚠️ openfortivpn not found — Open Settings"
        default:
            return nil
        }
    }

    private func statusTitle() -> String {
        switch vpnManager.state {
        case .disconnected:
            return "● Disconnected"
        case .connecting:
            return "● Connecting..."
        case .connected(let serverName):
            return "● Connected: \(serverName)"
        case .disconnecting:
            return "● Disconnecting..."
        }
    }
    
    private func statusAttributedTitle() -> NSAttributedString {
        let dot: String
        let dotColor: NSColor
        let text: String
        
        switch vpnManager.state {
        case .disconnected:
            dot = "● "
            dotColor = .secondaryLabelColor
            text = "Disconnected"
        case .connecting:
            dot = "● "
            dotColor = .systemOrange
            text = "Connecting..."
        case .connected(let serverName):
            dot = "● "
            dotColor = .systemGreen
            text = "Connected: \(serverName)"
        case .disconnecting:
            dot = "● "
            dotColor = .systemOrange
            text = "Disconnecting..."
        }
        
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: dot, attributes: [.foregroundColor: dotColor]))
        result.append(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.labelColor]))
        return result
    }
    
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
            self?.setupMenu()
        }
    }
    
    @objc private func connectToServer(_ sender: NSMenuItem) {
        let index = sender.tag
        let servers = configManager.config.servers
        guard index < servers.count else { return }
        
        let server = servers[index]
        
        guard let password = KeychainHelper.read(for: server.id), !password.isEmpty else {
            showAlert(title: "No Password", message: "Please set a password in Settings for server \"\(server.name)\".")
            return
        }
        
        vpnManager.connect(to: server, password: password)
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    @objc private func disconnect() {
        vpnManager.disconnect()
    }
    
    @objc private func openSettings() {
        showSettings(tab: nil)
    }

    @objc private func openGeneralSettings() {
        showSettings(tab: .general)
    }

    /// Opens the settings window, switching to `tab` when given.
    private func showSettings(tab: SettingsTab?) {
        if let existingWindow = settingsWindow {
            if let tab = tab {
                NotificationCenter.default.post(name: .showSettingsTab, object: tab)
            }
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(initialTab: tab ?? .servers)
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
}
