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
    private lazy var cliBridge = CLIBridge(vpn: vpnManager)
    private var sigtermSource: DispatchSourceSignal?

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

        // The icon style is a setting
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStateChanged),
            name: .configChanged,
            object: nil
        )

        installSignalHandler()
        cliBridge.start()
        vpnManager.connectAutoStartServers()
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

        // One entry per tunnel so each can be dropped independently
        for tunnel in vpnManager.tunnels {
            let title: String
            switch tunnel.state {
            case .connecting: title = "Cancel \(tunnel.serverName)"
            case .disconnecting: title = "Disconnecting \(tunnel.serverName)…"
            case .reconnecting: title = "Stop Reconnecting \(tunnel.serverName)"
            default: title = "Disconnect \(tunnel.serverName)"
            }
            let item = NSMenuItem(title: title, action: #selector(disconnectTunnel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tunnel.serverID
            menu.addItem(item)
        }

        if !vpnManager.tunnels.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        // Idle servers: connect from here too (in single-connection mode this switches)
        let idle = panelModel.servers.filter { vpnManager.status(for: $0.id) == nil }
        for server in idle {
            let item = NSMenuItem(title: "Connect \(server.name)", action: #selector(connectServer(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = server.id
            menu.addItem(item)
        }
        if !idle.isEmpty {
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

    @objc private func connectServer(_ sender: NSMenuItem) {
        if let serverID = sender.representedObject as? String,
           let server = panelModel.servers.first(where: { $0.id == serverID }) {
            panelModel.connect(server)
        }
    }

    @objc private func disconnectTunnel(_ sender: NSMenuItem) {
        if let serverID = sender.representedObject as? String {
            vpnManager.disconnect(serverID: serverID)
        }
    }

    // MARK: - Status Icon

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let image = StatusIcon.image(
            connected: vpnManager.connectedCount,
            busy: vpnManager.busyCount,
            style: configManager.config.menuBarIconStyle
        )
        button.image = image
        button.toolTip = vpnManager.tunnels.isEmpty
            ? "OpenFortiMac: not connected"
            : vpnManager.tunnels.map { "\($0.serverName): \($0.isConnected ? "connected" : "in progress")" }.joined(separator: "\n")
    }

    @objc private func vpnStateChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusIcon()
        }
    }

    // MARK: - Actions

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
        NSApp.terminate(nil)
    }

    /// Every way of quitting (menu, ⌘Q, `brew uninstall`, logout) drops the tunnels first,
    /// so openfortivpn restores routes and DNS instead of being orphaned.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let processes = vpnManager.stopAllForQuit()
        guard !processes.isEmpty else { return .terminateNow }

        // openfortivpn restores routes and DNS on SIGTERM; give it a few seconds
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(6)
            while processes.contains(where: \.isRunning) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            // The app is in a modal run loop mode while it waits to terminate
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                sender.reply(toApplicationShouldTerminate: true)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        cliBridge.stop()
    }

    /// SIGTERM (e.g. `kill`, launchd) goes through the same graceful path.
    private func installSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApp.terminate(nil)
        }
        source.resume()
        sigtermSource = source
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
    static let vpnLogsChanged = Notification.Name("vpnLogsChanged")
    static let configChanged = Notification.Name("configChanged")
    /// config.json was changed outside the app (CLI) and re-read
    static let configReloaded = Notification.Name("configReloaded")
    static let sudoersChanged = Notification.Name("sudoersChanged")
    static let showSettingsTab = Notification.Name("showSettingsTab")
    static let openServerEditor = Notification.Name("openServerEditor")
}
