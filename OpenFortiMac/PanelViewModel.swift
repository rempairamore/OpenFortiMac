import Foundation
import Combine

/// State and actions behind the menu bar panel.
final class PanelViewModel: ObservableObject {
    @Published private(set) var servers: [VPNServer] = []
    @Published private(set) var serversWithoutPassword: Set<String> = []
    @Published private(set) var sudoersStatus: SudoersStatus?

    /// Wired by AppDelegate, which owns the windows
    var openSettings: (SettingsTab?, ServerEditorRequest?) -> Void = { _, _ in }
    var quit: () -> Void = {}

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
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func loadServers() {
        servers = ConfigManager.shared.config.servers
        // Cached here so the panel does not hit the Keychain on every redraw
        serversWithoutPassword = Set(servers.filter { KeychainHelper.read(for: $0.id)?.isEmpty ?? true }.map(\.id))
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

    func connect(_ server: VPNServer) {
        guard let password = KeychainHelper.read(for: server.id), !password.isEmpty else {
            openSettings(.servers, .edit(server.id))
            return
        }
        VPNManager.shared.connect(to: server, password: password)
    }

    func disconnect() {
        VPNManager.shared.disconnect()
    }
}
