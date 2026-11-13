import Foundation
import AppKit
import UserNotifications
import Combine
import Network

enum VPNState: Equatable {
    case disconnected
    case connecting
    case connected(serverName: String)
    case disconnecting
    /// Auto-reconnect: next attempt at the given time, or nil while waiting for the network
    case reconnecting(at: Date?)
}

extension VPNState {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Live state of one tunnel, published to the UI.
struct TunnelStatus: Identifiable, Equatable {
    let serverID: String
    /// Identifies the current connection attempt, so a cancelled one that is still
    /// starting up cannot take over a newer one
    var attempt = UUID()
    /// Consecutive auto-reconnect attempts, 0 outside a reconnect cycle
    var reconnectAttempt = 0
    var state: VPNState = .disconnected
    var serverName: String = ""
    var assignedIP: String?
    /// ppp interface picked by pppd ("ppp0", "ppp1", …): numbering is dynamic,
    /// so it is read from the output once the tunnel is up.
    var interface: String?
    var connectedSince: Date?
    /// Static routes currently installed through this tunnel
    var routes: [String] = []

    var id: String { serverID }

    var isConnected: Bool { state.isConnected }

    var isBusy: Bool {
        switch state {
        case .connecting, .disconnecting, .reconnecting: return true
        case .connected, .disconnected: return false
        }
    }
}

/// Everything owned by one running openfortivpn process.
private final class TunnelConnection {
    let server: VPNServer
    let process: Process
    let pipe: Pipe
    let configPath: String
    var routesAdded: [(cidr: String, interface: String)] = []
    var finished = false
    /// A failure was already reported, so termination stays quiet
    var failed = false
    /// Retrying cannot help (wrong credentials or certificate): no auto-reconnect
    var fatal = false

    init(server: VPNServer, process: Process, pipe: Pipe, configPath: String) {
        self.server = server
        self.process = process
        self.pipe = pipe
        self.configPath = configPath
    }
}

/// Manages openfortivpn tunnels: one at a time by default, or several side by side
/// when "Allow multiple connections" is on. Each tunnel has its own root process,
/// status, log lines and optional static routes through its ppp interface.
///
/// All state lives on the main thread; background work hops back with `onMain`.
class VPNManager: ObservableObject {
    static let shared = VPNManager()

    /// One entry per active/connecting tunnel, in connection order.
    @Published private(set) var tunnels: [TunnelStatus] = []
    @Published private(set) var connectionLogs: [String] = []
    /// Last failure per server id (shown by the CLI); cleared on the next connect
    @Published private(set) var lastErrors: [String: TunnelError] = [:]

    struct TunnelError: Equatable {
        let message: String
        let date: Date
    }

    private var connections: [String: TunnelConnection] = [:]
    /// Single-connection mode: the connect waiting for the previous tunnel to go down
    private var pendingSwitch: AnyCancellable?

    /// Auto-reconnect waits for the network instead of failing attempts while offline
    private let pathMonitor = NWPathMonitor()
    private var networkAvailable = true

    /// Seconds before each reconnect attempt; the last value repeats
    static let reconnectDelays: [TimeInterval] = [2, 5, 10, 20, 30, 60]

    private init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            DispatchQueue.main.async {
                self?.networkChanged(available: available)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "openfortimac.network"))
    }

    // MARK: - Computed state

    var connectedCount: Int { tunnels.filter(\.isConnected).count }

    var busyCount: Int { tunnels.filter(\.isBusy).count }

    var hasTunnels: Bool { !tunnels.isEmpty }

    /// Aggregate state, e.g. for accessibility: connected wins over in-progress.
    var state: VPNState {
        if let connected = tunnels.first(where: \.isConnected) {
            return .connected(serverName: connected.serverName)
        }
        if tunnels.allSatisfy({ $0.state == .disconnecting }) && !tunnels.isEmpty {
            return .disconnecting
        }
        return tunnels.isEmpty ? .disconnected : .connecting
    }

    func status(for serverID: String) -> TunnelStatus? {
        tunnels.first { $0.serverID == serverID }
    }

    // MARK: - Connect

    func connect(to server: VPNServer, password: String) {
        guard status(for: server.id) == nil else { return }

        // Single-connection mode: switch servers by dropping the current tunnel first
        if !ConfigManager.shared.config.allowMultipleConnections, hasTunnels {
            addLog(server.name, "Switching: disconnecting current tunnel first")
            disconnectAll()
            pendingSwitch = $tunnels
                .first(where: \.isEmpty)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.pendingSwitch = nil
                    self?.connect(to: server, password: password)
                }
            return
        }

        lastErrors[server.id] = nil
        tunnels.append(TunnelStatus(serverID: server.id, state: .connecting, serverName: server.name))
        addLog(server.name, "Connecting to \(server.name)...")
        startAttempt(server: server, password: password)
    }

    /// Main thread: starts openfortivpn for a tunnel entry that already exists.
    private func startAttempt(server: VPNServer, password: String) {
        let attempt = UUID()
        updateTunnel(server.id) { status in
            status.state = .connecting
            status.attempt = attempt
        }
        notifyStateChange()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performConnection(server: server, password: password, attempt: attempt)
        }
    }

    /// Connects every server marked "Connect at launch" that has a saved password.
    func connectAutoStartServers() {
        let servers = ConfigManager.shared.config.servers.filter(\.autoConnect)
        let allowMultiple = ConfigManager.shared.config.allowMultipleConnections
        for server in allowMultiple ? servers : Array(servers.prefix(1)) {
            guard let password = KeychainHelper.read(for: server.id), !password.isEmpty else {
                addLog(server.name, "Auto-connect skipped: no saved password")
                continue
            }
            connect(to: server, password: password)
        }
    }

    /// Runs on a background queue.
    private func performConnection(server: VPNServer, password: String, attempt: UUID) {
        guard let openfortivpnPath = findOpenfortivpnBinary() else {
            onMain { $0.connectionFailed(server: server, reason: "openfortivpn not found. Install via: brew install openfortivpn") }
            return
        }

        // Fail early with a clear message instead of a bare sudo error
        guard SudoersManager.shared.isAllowed(binaryPath: openfortivpnPath) else {
            onMain { $0.connectionFailed(server: server, reason: "Administrator permission not set up. Open Settings › Permission.") }
            return
        }

        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fortivpn_\(UUID().uuidString).conf")

        var configContent = """
        host = \(server.host)
        port = \(server.port)
        username = \(server.username)
        password = \(password)
        """

        if let trustedCert = server.trustedCert, !trustedCert.isEmpty {
            configContent += "\ntrusted-cert = \(trustedCert)"
        }

        do {
            // Created 0600 before the password is written
            FileManager.default.createFile(atPath: configURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try configContent.write(to: configURL, atomically: false, encoding: .utf8)
        } catch {
            onMain { $0.connectionFailed(server: server, reason: "Failed to create config: \(error.localizedDescription)") }
            return
        }

        var arguments = ["-c", configURL.path]
        if server.trustedCert?.isEmpty ?? true {
            arguments.append("--trusted-cert=any")
        }
        if server.noRoutesDNS {
            arguments += ["--no-routes", "--no-dns"]
        }

        onMain { manager in
            // Cancelled while the config was being prepared
            guard let status = manager.status(for: server.id), status.attempt == attempt, status.state == .connecting else {
                try? FileManager.default.removeItem(at: configURL)
                return
            }
            if server.noRoutesDNS {
                manager.addLog(server.name, "Routes and DNS left untouched (--no-routes --no-dns)")
            }
            manager.start(openfortivpnPath: openfortivpnPath, arguments: arguments, server: server, configPath: configURL.path)
        }
    }

    func findOpenfortivpnBinary() -> String? {
        Self.locateOpenfortivpn()
    }

    /// Static so the CLI can use it without creating the manager (and its notification setup).
    static func locateOpenfortivpn() -> String? {
        let configPath = ConfigManager.shared.config.openfortivpnPath
        if FileManager.default.isExecutableFile(atPath: configPath) {
            return configPath
        }

        let commonPaths = [
            "/opt/homebrew/bin/openfortivpn",
            "/usr/local/bin/openfortivpn",
            "/opt/local/bin/openfortivpn"
        ]

        return commonPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Main thread: launches `sudo -n openfortivpn …` for one server.
    private func start(openfortivpnPath: String, arguments: [String], server: VPNServer, configPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // -n: never prompt; without a sudoers rule sudo exits instead of waiting for a tty
        process.arguments = ["-n", openfortivpnPath] + arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let conn = TunnelConnection(server: server, process: process, pipe: pipe, configPath: configPath)
        connections[server.id] = conn

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.handleOutput(output, conn: conn)
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.handleTermination(conn: conn, exitCode: proc.terminationStatus)
            }
        }

        // Per-tunnel connection timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak conn] in
            guard let self = self, let conn = conn, !conn.finished,
                  self.status(for: server.id)?.state == .connecting else { return }
            self.connectionFailed(server: server, reason: "Connection timeout - server not responding")
        }

        do {
            try process.run()
        } catch {
            connectionFailed(server: server, reason: "Failed to start process: \(error.localizedDescription)")
        }
    }

    // MARK: - Output parsing

    private func handleOutput(_ output: String, conn: TunnelConnection) {
        guard connections[conn.server.id] === conn else { return }
        let server = conn.server

        for line in output.components(separatedBy: .newlines) where !line.isEmpty {
            addLog(server.name, line)

            if let ip = Self.assignedAddress(in: line) {
                updateTunnel(server.id) { $0.assignedIP = ip }
            }

            if let iface = Self.interfaceName(in: line) {
                updateTunnel(server.id) { $0.interface = iface }
            }

            if line.contains("Tunnel is up and running") {
                markConnected(conn: conn)
                continue
            }

            guard status(for: server.id)?.state == .connecting,
                  let reason = Self.failureReason(in: line, server: server) else { continue }
            connectionFailed(server: server, reason: reason, fatal: Self.isFatal(reason))
        }
    }

    static func failureReason(in line: String, server: VPNServer) -> String? {
        let lower = line.lowercased()
        if lower.contains("could not resolve host") || lower.contains("cannot resolve host") {
            return "Cannot resolve host: \(server.host)"
        } else if lower.contains("connection timed out") {
            return "Connection timed out"
        } else if lower.contains("connection refused") {
            return "Connection refused by server"
        } else if lower.contains("authentication failed") || lower.contains("login failed") {
            return "Authentication failed - check username/password"
        } else if lower.contains("permission denied") && !lower.contains("sudo") {
            return "Authentication failed - check username/password"
        } else if lower.contains("certificate") && lower.contains("error") {
            return "Certificate error - try leaving certificate field empty"
        } else if lower.contains("gateway") && lower.contains("error") {
            return "Gateway error: \(line)"
        }
        return nil
    }

    /// Failures that a retry cannot fix: auto-reconnect stops instead of locking the account.
    static func isFatal(_ reason: String) -> Bool {
        reason.hasPrefix("Authentication failed") || reason.hasPrefix("Certificate error")
    }

    /// Extracts the tunnel IP from openfortivpn's "Got addresses: [10.0.0.5], ns [...]" line.
    static func assignedAddress(in line: String) -> String? {
        guard let range = line.range(of: #"Got addresses: \[[^\],]+"#, options: .regularExpression) else {
            return nil
        }
        let match = line[range]
        guard let open = match.firstIndex(of: "[") else { return nil }
        let ip = match[match.index(after: open)...].trimmingCharacters(in: .whitespaces)
        return ip.isEmpty ? nil : ip
    }

    /// Extracts the ppp interface from pppd's "Using interface ppp0" line.
    static func interfaceName(in line: String) -> String? {
        guard let range = line.range(of: #"Using interface ppp\d+"#, options: .regularExpression) else {
            return nil
        }
        return String(line[range].dropFirst("Using interface ".count))
    }

    private func markConnected(conn: TunnelConnection) {
        let server = conn.server
        let reconnected = (status(for: server.id)?.reconnectAttempt ?? 0) > 0

        // openfortivpn read its config at startup: do not keep the password on disk while connected
        try? FileManager.default.removeItem(atPath: conn.configPath)

        updateTunnel(server.id) { status in
            status.state = .connected(serverName: server.name)
            status.connectedSince = Date()
            status.reconnectAttempt = 0
        }
        notifyStateChange()
        showNotification(title: reconnected ? "VPN Reconnected" : "VPN Connected", body: server.name)

        let routes = server.validatedStaticRoutes
        guard !routes.isEmpty else { return }

        let knownInterface = status(for: server.id)?.interface
        let tunnelIP = status(for: server.id)?.assignedIP

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Fallback when pppd's "Using interface" line was not seen: look the IP up in ifconfig
            guard let iface = knownInterface ?? Self.findInterface(tunnelIP: tunnelIP) else {
                self?.onMain { $0.addLog(server.name, "ERROR: could not determine the ppp interface, static routes not added") }
                return
            }
            self?.addStaticRoutes(routes, interface: iface, conn: conn)
        }
    }

    /// Blocking: finds the ppp interface holding the given local address, e.g. "ppp1".
    static func findInterface(tunnelIP: String?) -> String? {
        guard let tunnelIP = tunnelIP else { return nil }
        let text = run("/sbin/ifconfig", []).output

        // Blocks look like: "ppp1: flags=...\n\tinet 10.0.0.2 --> 169.254.2.1 ..."
        var currentInterface: String?
        for line in text.components(separatedBy: .newlines) {
            if !line.hasPrefix("\t"), let name = line.split(separator: ":").first, !name.isEmpty {
                currentInterface = String(name)
            } else if let iface = currentInterface, iface.hasPrefix("ppp") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count >= 2, fields[0] == "inet", fields[1] == tunnelIP {
                    return iface
                }
            }
        }
        return nil
    }

    // MARK: - Static routes

    /// Background queue: `sudo -n /sbin/route -n add -net <cidr> -interface <pppN>` per route.
    /// Failures are logged; the tunnel itself stays up.
    private func addStaticRoutes(_ routes: [String], interface: String, conn: TunnelConnection) {
        let server = conn.server
        for cidr in routes {
            var result = Self.runRoute("add", cidr: cidr, interface: interface)
            // A leftover route (e.g. from an earlier session) is re-pointed to this tunnel
            if !result.success && result.output.contains("File exists") {
                result = Self.runRoute("change", cidr: cidr, interface: interface)
            }

            onMain { manager in
                if result.success {
                    // The tunnel may have dropped meanwhile; the kernel removed the route with it
                    guard !conn.finished else { return }
                    conn.routesAdded.append((cidr, interface))
                    manager.updateTunnel(server.id) { $0.routes.append(cidr) }
                    manager.addLog(server.name, "Route added: \(cidr) via \(interface)")
                } else {
                    manager.addLog(server.name, "ERROR: could not add route \(cidr) via \(interface): \(result.output)")
                    if result.output.contains("password is required") {
                        manager.addLog(server.name, "Static routes need permission: open Settings › Permission and click Update")
                        manager.showNotification(title: "Static routes not added", body: "\(server.name): update the permission in Settings")
                    }
                }
            }
        }
    }

    /// Background queue. Interface-bound routes vanish with the ppp interface;
    /// this cleans up whatever outlived it.
    private func removeStaticRoutes(_ routes: [(cidr: String, interface: String)]) {
        guard !routes.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for route in routes {
                _ = Self.runRoute("delete", cidr: route.cidr, interface: route.interface)
            }
        }
    }

    private static func runRoute(_ verb: String, cidr: String, interface: String) -> (success: Bool, output: String) {
        // Matches the sudoers rule: /sbin/route -n <verb> -net * -interface ppp*
        let result = run("/usr/bin/sudo", ["-n", "/sbin/route", "-n", verb, "-net", cidr, "-interface", interface])
        return (result.status == 0, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Disconnect

    func disconnect(serverID: String) {
        guard let conn = connections[serverID], !conn.finished else {
            // Preparing the config or waiting to reconnect: dropping the entry cancels it
            if let status = status(for: serverID) {
                if case .reconnecting = status.state {
                    addLog(status.serverName, "Auto-reconnect cancelled")
                }
                removeTunnel(serverID)
            }
            return
        }

        updateTunnel(serverID) { $0.state = .disconnecting }
        notifyStateChange()
        addLog(conn.server.name, "Disconnecting...")

        terminate(conn: conn)
    }

    func disconnectAll() {
        tunnels.map(\.serverID).forEach(disconnect(serverID:))
        pendingSwitch = nil
    }

    /// Quit path: SIGTERM to every tunnel and returns the processes to wait for.
    /// While the app waits to terminate, the main queue is not serviced, so the
    /// usual termination callbacks cannot be relied on: clean up synchronously here.
    func stopAllForQuit() -> [Process] {
        pendingSwitch = nil
        let active = connections.values.filter { !$0.finished }
        for conn in active {
            if conn.process.isRunning {
                conn.process.terminate()
            }
            // openfortivpn has read its config by now: do not leave the password on disk
            try? FileManager.default.removeItem(atPath: conn.configPath)
        }
        return active.map(\.process)
    }

    /// Sends SIGTERM to the sudo parent, which relays it to openfortivpn so it can restore routes and DNS.
    private func terminate(conn: TunnelConnection) {
        if conn.process.isRunning {
            conn.process.terminate()
        }

        // Safety net: drop the entry if the process does not report back
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, !conn.finished else { return }
            self.addLog(conn.server.name, "Disconnected (forced)")
            self.finish(conn)
        }
    }

    // MARK: - Termination handling

    private func handleTermination(conn: TunnelConnection, exitCode: Int32) {
        guard !conn.finished else { return }
        let server = conn.server
        let status = status(for: server.id)
        let previousState = status?.state ?? .disconnected
        let inReconnectCycle = (status?.reconnectAttempt ?? 0) > 0

        // Reconnect a tunnel that dropped, and keep retrying while a reconnect fails,
        // unless the user disconnected or retrying cannot help
        let dropped = previousState.isConnected || (previousState == .connecting && inReconnectCycle)
        let reconnect = dropped && !conn.fatal && autoReconnectEnabled(for: server.id)

        finish(conn, keepStatus: reconnect)

        switch previousState {
        case .connecting where !conn.failed:
            lastErrors[server.id] = TunnelError(message: "openfortivpn exited with code \(exitCode)", date: Date())
            addLog(server.name, "ERROR: Connection failed (exit code: \(exitCode))")
            if !inReconnectCycle {
                showNotification(title: "Connection Failed", body: "\(server.name): openfortivpn exited with code \(exitCode)")
            }
        case .connected:
            addLog(server.name, "Disconnected (exit code: \(exitCode))")
            showNotification(title: "VPN Disconnected", body: reconnect ? "\(server.name): reconnecting…" : server.name)
        case .disconnecting:
            addLog(server.name, "Disconnected")
        default:
            break
        }

        if reconnect {
            scheduleReconnect(server: server, attempt: (status?.reconnectAttempt ?? 0) + 1)
        }
    }

    // MARK: - Auto-reconnect

    private func autoReconnectEnabled(for serverID: String) -> Bool {
        // Read the saved profile: the option may have changed while connected
        ConfigManager.shared.config.servers.first { $0.id == serverID }?.autoReconnect ?? false
    }

    /// Main thread: keeps the tunnel entry and retries after a growing delay.
    private func scheduleReconnect(server: VPNServer, attempt: Int) {
        let delay = Self.reconnectDelays[min(attempt, Self.reconnectDelays.count) - 1]
        let date = networkAvailable ? Date().addingTimeInterval(delay) : nil

        updateTunnel(server.id) { status in
            status.state = .reconnecting(at: date)
            status.reconnectAttempt = attempt
            status.assignedIP = nil
            status.interface = nil
            status.connectedSince = nil
            status.routes = []
        }
        notifyStateChange()

        guard let date = date else {
            addLog(server.name, "Waiting for the network to reconnect")
            return
        }
        addLog(server.name, "Reconnecting in \(Int(delay))s (attempt \(attempt))")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Skip if cancelled, or already retried because the network came back
            guard let self = self, self.status(for: server.id)?.state == .reconnecting(at: date) else { return }
            self.reconnect(serverID: server.id)
        }
    }

    private func reconnect(serverID: String) {
        guard let status = status(for: serverID) else { return }

        // The profile may have been edited or deleted in the meantime
        guard let server = ConfigManager.shared.config.servers.first(where: { $0.id == serverID }),
              server.autoReconnect else {
            addLog(status.serverName, "Auto-reconnect stopped")
            removeTunnel(serverID)
            return
        }
        guard let password = KeychainHelper.read(for: server.id), !password.isEmpty else {
            reportError(server: server, reason: "Auto-reconnect stopped: no saved password")
            removeTunnel(serverID)
            return
        }
        guard networkAvailable else {
            updateTunnel(serverID) { $0.state = .reconnecting(at: nil) }
            notifyStateChange()
            addLog(server.name, "Waiting for the network to reconnect")
            return
        }

        addLog(server.name, "Reconnecting (attempt \(status.reconnectAttempt))...")
        startAttempt(server: server, password: password)
    }

    private func networkChanged(available: Bool) {
        let restored = available && !networkAvailable
        networkAvailable = available
        guard restored else { return }

        // Retry right away instead of waiting for the backoff to expire
        for status in tunnels {
            if case .reconnecting = status.state {
                addLog(status.serverName, "Network is back")
                reconnect(serverID: status.serverID)
            }
        }
    }

    /// Records a failure that happened before a tunnel was started (e.g. no saved password).
    func reportError(server: VPNServer, reason: String) {
        lastErrors[server.id] = TunnelError(message: reason, date: Date())
        addLog(server.name, "ERROR: \(reason)")
    }

    private func connectionFailed(server: VPNServer, reason: String, fatal: Bool = false) {
        lastErrors[server.id] = TunnelError(message: reason, date: Date())
        addLog(server.name, "ERROR: \(reason)")

        // While reconnecting, every failed attempt would notify: the log is enough
        let reconnecting = (status(for: server.id)?.reconnectAttempt ?? 0) > 0
        if !reconnecting || fatal {
            showNotification(title: "Connection Failed", body: "\(server.name): \(String(reason.prefix(100)))")
        }

        if let conn = connections[server.id], !conn.finished {
            conn.failed = true
            conn.fatal = fatal
            terminate(conn: conn)
        } else {
            removeTunnel(server.id)
        }
    }

    /// Main thread: releases everything the connection owned.
    /// `keepStatus`: the tunnel entry stays for an auto-reconnect.
    private func finish(_ conn: TunnelConnection, keepStatus: Bool = false) {
        conn.finished = true
        conn.pipe.fileHandleForReading.readabilityHandler = nil
        try? FileManager.default.removeItem(atPath: conn.configPath)
        removeStaticRoutes(conn.routesAdded)

        if connections[conn.server.id] === conn {
            connections.removeValue(forKey: conn.server.id)
            if !keepStatus {
                removeTunnel(conn.server.id)
            }
        }
    }

    // MARK: - State helpers (main thread)

    private func updateTunnel(_ serverID: String, _ mutate: (inout TunnelStatus) -> Void) {
        guard let index = tunnels.firstIndex(where: { $0.serverID == serverID }) else { return }
        mutate(&tunnels[index])
    }

    private func removeTunnel(_ serverID: String) {
        tunnels.removeAll { $0.serverID == serverID }
        notifyStateChange()
    }

    private func onMain(_ work: @escaping (VPNManager) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let self = self { work(self) }
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        // Read before waiting so a full pipe cannot block the child
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Logs & notifications

    private func addLog(_ serverName: String, _ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        connectionLogs.append("[\(timestamp)] [\(serverName)] \(message)")
        LogFile.shared.append("\(Self.fileTimestamp.string(from: Date())) [\(serverName)] \(message)")

        if connectionLogs.count > 500 {
            connectionLogs.removeFirst(connectionLogs.count - 500)
        }
        NotificationCenter.default.post(name: .vpnLogsChanged, object: nil)
    }

    private static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func notifyStateChange() {
        NotificationCenter.default.post(name: .vpnStateChanged, object: nil)
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
