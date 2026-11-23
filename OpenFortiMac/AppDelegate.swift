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
    /// Colors the frame of the panel in themes that have their own background
    private var popoverBackdrop: NSView?
    private var sigtermSource: DispatchSourceSignal?
    private var terminationReplied = false
    private var iconAnimation: Timer?
    /// Where the busy icon is in its cycle, 0 to 1
    private var iconPhase: CGFloat = 0
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Light, dark or Dracula: chosen in Settings, not taken from the Mac
        ThemeManager.shared.apply()
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyThemeToWindows()
        }
        vpnManager.requestNotificationPermission()

        // `kill` and some shutdowns send SIGTERM, which would end the app on the spot:
        // route it through AppKit so the tunnel is closed first
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApp.terminate(nil)
        }
        source.resume()
        sigtermSource = source

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

        // A crash or a forced quit can leave a tunnel running and its config file behind
        LeftoverTunnels.removeStaleConfigFiles()
        panelModel.refreshLeftoverTunnels()

        // GitHub is asked at most once a day; the timer only notices when a day has passed
        panelModel.refreshUpdate()
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.panelModel.refreshUpdate()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    // MARK: - Menu Bar Panel

    private func setupPopover() {
        let controller = NSHostingController(rootView: MenuPanelView(model: panelModel, vpn: vpnManager))
        // Let the popover follow the SwiftUI content height (servers, banner)
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.appearance = ThemeManager.shared.theme.appearance
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
        panelModel.refreshLeftoverTunnels()

        // Activate so the panel's keyboard shortcuts (⌘D, ⌘,, ⌘Q) work right away
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        colorPopoverFrame()
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Theme

    /// The SwiftUI views repaint by themselves; the pieces AppKit draws (the title bar of
    /// Settings, the arrow of the panel) are colored here.
    private func applyThemeToWindows() {
        // A popover takes its appearance from the view it hangs from, here the menu bar,
        // not from the app: it has to be told
        popover.appearance = ThemeManager.shared.theme.appearance
        if let window = settingsWindow {
            styleSettingsWindow(window)
        }
        if popover.isShown {
            colorPopoverFrame()
        }
    }

    private func styleSettingsWindow(_ window: NSWindow) {
        window.appearance = ThemeManager.shared.theme.appearance
        // The title bar and the tabs under it read as one toolbar
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ThemeManager.shared.theme.palette.background ?? .windowBackgroundColor
    }

    /// A popover draws its own frame and arrow. A view of the theme's color placed under the
    /// content, inside that frame, takes its shape, arrow included.
    private func colorPopoverFrame() {
        popoverBackdrop?.removeFromSuperview()
        popoverBackdrop = nil
        guard let background = ThemeManager.shared.theme.palette.panel,
              let contentView = popover.contentViewController?.view,
              let frameView = contentView.superview else { return }

        let backdrop = NSView(frame: frameView.bounds)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = background.cgColor
        backdrop.autoresizingMask = [.width, .height]
        frameView.addSubview(backdrop, positioned: .below, relativeTo: contentView)
        popoverBackdrop = backdrop
    }

    /// Right click keeps a classic menu for quick access.
    private func showContextMenu() {
        popover.performClose(nil)

        let menu = NSMenu()

        if case .connected = vpnManager.state {
            let disconnectItem = NSMenuItem(title: String(localized: "Disconnect"), action: #selector(disconnect), keyEquivalent: "d")
            disconnectItem.target = self
            menu.addItem(disconnectItem)
            menu.addItem(NSMenuItem.separator())
        }

        let settingsItem = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit OpenFortiMac"), action: #selector(quitApp), keyEquivalent: "q")
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

        switch vpnManager.state {
        case .disconnected:
            stopIconAnimation()
            button.image = StatusIcon.disconnected(description: String(localized: "Disconnected"))
        case .connecting, .disconnecting:
            // The dot on the shield pulses while the connection is set up or taken down
            startIconAnimation()
        case .connected:
            stopIconAnimation()
            button.image = StatusIcon.connected(description: String(localized: "Connected"))
        }
    }

    private func startIconAnimation() {
        guard iconAnimation == nil else { return }
        iconPhase = 0
        drawBusyIcon()
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // The dot grows and shrinks once every 1.2 seconds
            self.iconPhase = (self.iconPhase + 0.06 / 1.2).truncatingRemainder(dividingBy: 1)
            self.drawBusyIcon()
        }
        RunLoop.main.add(timer, forMode: .common)
        iconAnimation = timer
    }

    private func stopIconAnimation() {
        iconAnimation?.invalidate()
        iconAnimation = nil
    }

    private func drawBusyIcon() {
        // Up in the first half of the cycle, down in the second, slowing at both ends
        let wave = iconPhase < 0.5 ? iconPhase * 2 : (1 - iconPhase) * 2
        let eased = wave * wave * (3 - 2 * wave)
        statusItem.button?.image = StatusIcon.busy(progress: eased, description: String(localized: "In progress"))
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
        window.title = String(localized: "OpenFortiMac Settings")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        window.delegate = self
        styleSettingsWindow(window)

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        // The tunnel is closed in applicationShouldTerminate, like for every other way of quitting
        NSApp.terminate(nil)
    }

    // MARK: - Quitting

    /// Every quit path ends here: the menu, logout and shutdown, Homebrew's quit during
    /// `brew upgrade` or `brew uninstall`, and SIGTERM. openfortivpn restores routes and DNS
    /// only if it is stopped properly, so wait for it before letting the app go.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard vpnManager.isActive else { return .terminateNow }

        terminationReplied = false
        vpnManager.disconnect { [weak self] in
            self?.replyToTermination()
        }
        // Homebrew gives up on a quit after 10 s: never wait longer than 6
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.replyToTermination()
        }
        return .terminateLater
    }

    private func replyToTermination() {
        guard !terminationReplied else { return }
        terminationReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == settingsWindow {
            settingsWindow = nil
        }
    }
}
