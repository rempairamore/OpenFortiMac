import Foundation
import Combine

/// Shared between the app and the `openfortimac` command line tool.
///
/// The running app publishes its tunnels to `state.json` and listens for commands
/// as distributed notifications, so the CLI never touches the Keychain or root.
enum CLIProtocol {
    static let commandNotification = Notification.Name("com.openfortimac.cli.command")
    static let bundleIdentifier = "rempairamore.OpenFortiMac"

    static var stateURL: URL {
        ConfigManager.configPath.deletingLastPathComponent().appendingPathComponent("state.json")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OpenFortiMac/openfortimac.log")
    }

    enum Action: String {
        case connect, disconnect, disconnectAll = "disconnect-all", reloadConfig = "reload-config"
    }

    struct State: Codable {
        var pid: Int32
        var updated: Date
        var allowMultipleConnections: Bool
        var tunnels: [Tunnel]
        /// Last failure per server id, so `connect` can report why it did not come up
        var errors: [String: ErrorEntry]

        struct Tunnel: Codable {
            var id: String
            var name: String
            var state: String
            var ip: String?
            var interface: String?
            var since: Date?
            var routes: [String]
        }

        struct ErrorEntry: Codable {
            var message: String
            var date: Date
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension VPNState {
    var cliName: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        case .reconnecting: return "reconnecting"
        }
    }
}

/// App side: executes CLI commands and keeps `state.json` current.
final class CLIBridge {
    private let vpn: VPNManager
    private var cancellables: Set<AnyCancellable> = []
    private var observer: NSObjectProtocol?

    init(vpn: VPNManager) {
        self.vpn = vpn
    }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: CLIProtocol.commandNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handle(notification.userInfo ?? [:])
        }

        // @Published fires before the value changes: hop to the next main loop turn
        vpn.$tunnels.map { _ in () }
            .merge(with: vpn.$lastErrors.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.writeState() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .configChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.writeState() }
            .store(in: &cancellables)

        writeState()
    }

    /// Called on quit: no state file means "app not running" to the CLI.
    func stop() {
        try? FileManager.default.removeItem(at: CLIProtocol.stateURL)
    }

    private func handle(_ info: [AnyHashable: Any]) {
        guard let actionName = info["action"] as? String,
              let action = CLIProtocol.Action(rawValue: actionName) else { return }

        switch action {
        case .reloadConfig:
            // The CLI edited config.json: pick it up so the app does not overwrite it later
            ConfigManager.shared.reload()
            NotificationCenter.default.post(name: .configChanged, object: nil)
            NotificationCenter.default.post(name: .configReloaded, object: nil)
        case .disconnectAll:
            vpn.disconnectAll()
        case .disconnect:
            if let id = info["server"] as? String {
                vpn.disconnect(serverID: id)
            }
        case .connect:
            guard let id = info["server"] as? String,
                  let server = ConfigManager.shared.config.servers.first(where: { $0.id == id }) else { return }
            guard let password = KeychainHelper.read(for: server.id), !password.isEmpty else {
                vpn.reportError(server: server, reason: "No saved password: set it in Settings › Servers")
                return
            }
            vpn.connect(to: server, password: password)
        }
    }

    private func writeState() {
        let state = CLIProtocol.State(
            pid: ProcessInfo.processInfo.processIdentifier,
            updated: Date(),
            allowMultipleConnections: ConfigManager.shared.config.allowMultipleConnections,
            tunnels: vpn.tunnels.map {
                .init(
                    id: $0.serverID,
                    name: $0.serverName,
                    state: $0.state.cliName,
                    ip: $0.assignedIP,
                    interface: $0.interface,
                    since: $0.connectedSince,
                    routes: $0.routes
                )
            },
            errors: vpn.lastErrors.mapValues { .init(message: $0.message, date: $0.date) }
        )
        guard let data = try? CLIProtocol.encoder().encode(state) else { return }
        try? data.write(to: CLIProtocol.stateURL, options: .atomic)
    }
}

/// Appends log lines to ~/Library/Logs/OpenFortiMac/openfortimac.log for `openfortimac logs`.
final class LogFile {
    static let shared = LogFile()

    private let queue = DispatchQueue(label: "openfortimac.logfile")
    private let url = CLIProtocol.logURL
    private let maxSize: UInt64 = 2_000_000

    func append(_ line: String) {
        queue.async { [url, maxSize] in
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Keep one previous file around instead of growing forever
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maxSize {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
        }
    }
}
