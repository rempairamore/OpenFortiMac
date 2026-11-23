import Foundation
import AppKit
import Combine

/// State and actions behind the menu bar panel.
final class PanelViewModel: ObservableObject {
    @Published private(set) var servers: [VPNServer] = []
    @Published private(set) var serversWithoutPassword: Set<String> = []
    @Published private(set) var sudoersStatus: SudoersStatus?
    @Published private(set) var configIssue: ConfigIssue?
    /// Tunnels left running by an earlier run of the app
    @Published private(set) var leftoverTunnels: [Int32] = []
    @Published private(set) var leftoverStopFailed = false
    @Published private(set) var availableUpdate: AvailableUpdate?

    /// Wired by AppDelegate, which owns the windows
    var openSettings: (SettingsTab?, ServerEditorRequest?) -> Void = { _, _ in }
    var quit: () -> Void = {}

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private var observers: [NSObjectProtocol] = []

    init() {
        loadServers()

        observers.append(NotificationCenter.default.addObserver(
            forName: .configChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadServers()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .sudoersChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let status = notification.object as? SudoersStatus {
                self?.sudoersStatus = status
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .updateSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshUpdate()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func loadServers() {
        servers = ConfigManager.shared.config.servers
        configIssue = ConfigManager.shared.loadIssue
        // Only asks the Keychain whether a password exists: the secret is read when connecting
        serversWithoutPassword = Set(servers.filter { !$0.singleSignOn && !KeychainHelper.exists(for: $0.id) }.map(\.id))
    }

    func refreshSudoersStatus(completion: ((SudoersStatus) -> Void)? = nil) {
        let path = VPNManager.shared.findOpenfortivpnBinary()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = SudoersManager.shared.status(for: path)
            DispatchQueue.main.async {
                self?.sudoersStatus = status
                completion?(status)
            }
        }
    }

    // MARK: - Connection

    func connect(_ server: VPNServer) {
        if server.singleSignOn {
            VPNManager.shared.connect(to: server, password: nil)
            return
        }
        guard let password = KeychainHelper.read(for: server.id), !password.isEmpty else {
            openSettings(.servers, .edit(server.id))
            return
        }
        VPNManager.shared.connect(to: server, password: password)
    }

    func disconnect() {
        VPNManager.shared.disconnect()
    }

    /// Pins the certificate the gateway showed in the failed attempt, then connects again.
    func trustCertificateAndConnect() {
        guard let failure = VPNManager.shared.lastFailure,
              case .untrustedCertificate(let digest?, _) = failure.kind,
              let index = servers.firstIndex(where: { $0.id == failure.serverID }) else { return }

        var updated = servers
        updated[index] = updated[index].trusting(digest)
        ConfigManager.shared.saveServers(updated)
        NotificationCenter.default.post(name: .configChanged, object: nil)
        connect(updated[index])
    }

    // MARK: - Leftover tunnels

    func refreshLeftoverTunnels() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = LeftoverTunnels.find()
            DispatchQueue.main.async {
                self?.leftoverTunnels = found
                if found.isEmpty {
                    self?.leftoverStopFailed = false
                }
            }
        }
    }

    func stopLeftoverTunnels() {
        let pids = leftoverTunnels
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            LeftoverTunnels.stop(pids)
            // openfortivpn needs a moment to restore routes and DNS
            Thread.sleep(forTimeInterval: 2)
            let remaining = LeftoverTunnels.find()
            DispatchQueue.main.async {
                self?.leftoverTunnels = remaining
                self?.leftoverStopFailed = !remaining.isEmpty
            }
        }
    }

    // MARK: - Updates

    /// Shows a known newer version and, if a check is due, asks GitHub.
    func refreshUpdate() {
        guard UpdateChecker.shared.isEnabled else {
            availableUpdate = nil
            return
        }
        availableUpdate = UpdateChecker.shared.knownUpdate
        UpdateChecker.shared.checkIfDue { [weak self] update in
            self?.availableUpdate = update
        }
    }

    func openUpdatePage() {
        if let update = availableUpdate {
            NSWorkspace.shared.open(update.page)
        }
    }

    func revealConfigFolder() {
        let folder = ConfigManager.configPath.deletingLastPathComponent()
        let file = configIssue?.backup.map { folder.appendingPathComponent($0) } ?? ConfigManager.configPath
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}

#if DEBUG
extension PanelViewModel {
    /// Shows given banners, for SwiftUI previews and rendering checks.
    func setPreview(servers: [VPNServer], withoutPassword: Set<String> = [], sudoers: SudoersStatus? = .managed,
                    leftoverTunnels: [Int32] = [], update: AvailableUpdate? = nil, configIssue: ConfigIssue? = nil) {
        self.servers = servers
        self.serversWithoutPassword = withoutPassword
        self.sudoersStatus = sudoers
        self.leftoverTunnels = leftoverTunnels
        self.availableUpdate = update
        self.configIssue = configIssue
    }
}
#endif
