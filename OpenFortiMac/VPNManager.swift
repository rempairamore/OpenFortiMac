import Foundation
import AppKit
import UserNotifications
import Combine

enum VPNState: Equatable {
    case disconnected
    case connecting
    case connected(serverName: String)
    case disconnecting
}

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    
    @Published private(set) var state: VPNState = .disconnected {
        didSet {
            // Single reset point for every path that ends a connection
            if state == .disconnected {
                currentServer = nil
                connectedSince = nil
                assignedIP = nil
            }
        }
    }
    @Published private(set) var connectionLogs: [String] = []
    @Published private(set) var currentServer: VPNServer?
    @Published private(set) var connectedSince: Date?
    @Published private(set) var assignedIP: String?

    private var vpnProcess: Process?
    private var outputPipe: Pipe?
    private var tempConfigPath: String?
    private var connectionTimeoutTimer: Timer?
    /// Run once openfortivpn has exited, e.g. to let the app quit
    private var stopCompletions: [() -> Void] = []

    /// A tunnel is starting, up, or openfortivpn is still shutting down.
    var isActive: Bool {
        state != .disconnected || vpnProcess != nil
    }
    
    private init() {}

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    func connect(to server: VPNServer, password: String) {
        guard case .disconnected = state else {
            showNotification(title: "Already Connected", body: "Disconnect first before connecting to another server")
            return
        }
        // The previous openfortivpn is still shutting down: launching now would be refused
        guard vpnProcess == nil else {
            showNotification(title: "Still Disconnecting", body: "Try again in a moment")
            return
        }
        
        state = .connecting
        currentServer = server
        connectionLogs = []
        notifyStateChange()
        addLog("Connecting to \(server.name)...")
        
        // Connection timeout (30 seconds), created right away so a stale timer never outlives a cancel
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self = self, case .connecting = self.state else { return }
            self.addLog("ERROR: Connection timeout - server not responding")
            self.showNotification(title: "Connection Failed ❌", body: "Timeout - server not responding")
            self.terminateAndCleanup()
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performConnection(server: server, password: password)
        }
    }
    
    /// Slow checks off the main thread; the launch itself happens on the main thread.
    private func performConnection(server: VPNServer, password: String) {
        guard let openfortivpnPath = findOpenfortivpnBinary() else {
            DispatchQueue.main.async { [weak self] in
                self?.connectionFailed(reason: "openfortivpn not found. Install via: brew install openfortivpn")
            }
            return
        }

        // Fail early with a clear message instead of a bare sudo error
        guard SudoersManager.shared.isAllowed(binaryPath: openfortivpnPath) else {
            DispatchQueue.main.async { [weak self] in
                self?.connectionFailed(reason: "Administrator permission not set up. Open Settings › Permission.")
            }
            return
        }

        // Built before any file is written, so invalid values never reach the disk
        let configContent: String
        do {
            configContent = try OpenfortivpnConfig.make(server: server, password: password)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.connectionFailed(reason: error.localizedDescription)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.launch(openfortivpnPath: openfortivpnPath, configContent: configContent, server: server)
        }
    }

    private func launch(openfortivpnPath: String, configContent: String, server: VPNServer) {
        // Cancelled, or the app started quitting, while the permission was being checked
        guard case .connecting = state, currentServer?.id == server.id, vpnProcess == nil else { return }

        let configPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("fortivpn_\(UUID().uuidString).conf").path
        do {
            try Self.writePrivateFile(configContent, to: configPath)
        } catch {
            connectionFailed(reason: "Failed to create config: \(error.localizedDescription)")
            return
        }
        tempConfigPath = configPath

        // A trusted-cert digest, when set, is in the config file
        runWithSudo(openfortivpnPath: openfortivpnPath, arguments: ["-c", configPath], server: server)
    }

    /// Creates the file readable by its owner only from the start; O_EXCL never reuses an existing path.
    private static func writePrivateFile(_ content: String, to path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(content.utf8))
        try handle.close()
    }
    
    func findOpenfortivpnBinary() -> String? {
        let configPath = ConfigManager.shared.config.openfortivpnPath
        if FileManager.default.isExecutableFile(atPath: configPath) {
            return configPath
        }
        
        let commonPaths = [
            "/opt/homebrew/bin/openfortivpn",
            "/usr/local/bin/openfortivpn",
            "/opt/local/bin/openfortivpn"
        ]
        
        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    private func runWithSudo(openfortivpnPath: String, arguments: [String], server: VPNServer) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // -n: never prompt; without a sudoers rule sudo exits instead of waiting for a tty
        process.arguments = ["-n", openfortivpnPath] + arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        outputPipe = pipe
        vpnProcess = process
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                DispatchQueue.main.async {
                    self?.handleOutput(output, server: server)
                }
            }
        }
        
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.handleTermination(exitCode: proc.terminationStatus)
            }
        }
        
        do {
            try process.run()
            addLog("Starting connection to \(server.name)...")
        } catch {
            vpnProcess = nil
            outputPipe = nil
            connectionFailed(reason: "Failed to start process: \(error.localizedDescription)")
        }
    }
    
    private func handleOutput(_ output: String, server: VPNServer) {
        // openfortivpn reads its config before printing anything: the file with the password can go now
        cleanupTempFiles()

        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        
        for line in lines {
            addLog(line)

            if let ip = Self.assignedAddress(in: line) {
                assignedIP = ip
            }

            if line.contains("Tunnel is up and running") {
                connectionTimeoutTimer?.invalidate()
                connectionTimeoutTimer = nil
                connectedSince = Date()
                state = .connected(serverName: server.name)
                notifyStateChange()
                showNotification(title: "VPN Connected ✅", body: server.name)
                continue
            }
            
            guard case .connecting = state else { continue }
            
            let lower = line.lowercased()
            
            if lower.contains("could not resolve host") || lower.contains("cannot resolve host") {
                connectionFailed(reason: "Cannot resolve host: \(server.host)")
            } else if lower.contains("connection timed out") {
                connectionFailed(reason: "Connection timed out")
            } else if lower.contains("connection refused") {
                connectionFailed(reason: "Connection refused by server")
            } else if lower.contains("authentication failed") || lower.contains("login failed") {
                connectionFailed(reason: "Authentication failed - check username/password")
            } else if lower.contains("permission denied") && !lower.contains("sudo") {
                connectionFailed(reason: "Authentication failed - check username/password")
            } else if lower.contains("not in the local whitelist") {
                connectionFailed(reason: "The gateway's certificate is not trusted. Only if you trust this gateway, copy the sha256 digest from the Log into Certificate (optional).")
            } else if lower.contains("certificate") && lower.contains("error") {
                connectionFailed(reason: "Certificate error - see the Log for details")
            } else if lower.contains("gateway") && lower.contains("error") {
                connectionFailed(reason: "Gateway error: \(line)")
            }
        }
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

    private func handleTermination(exitCode: Int32) {
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        cleanupTempFiles()
        
        let previousState = state
        
        if case .connecting = previousState {
            state = .disconnected
            notifyStateChange()
            addLog("ERROR: Connection failed (exit code: \(exitCode))")
            showNotification(title: "Connection Failed ❌", body: "Process exited with code \(exitCode)")
        } else if case .connected = previousState {
            state = .disconnected
            notifyStateChange()
            addLog("Disconnected (exit code: \(exitCode))")
            showNotification(title: "VPN Disconnected", body: "Connection ended")
        } else {
            if case .disconnecting = previousState {
                addLog("Disconnected")
            }
            state = .disconnected
            notifyStateChange()
        }
        
        vpnProcess = nil
        outputPipe = nil
        finishStop()
    }

    private func connectionFailed(reason: String) {
        // Already cancelled while the permission was being checked: nothing left to report
        guard state != .disconnected || vpnProcess != nil else { return }

        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        
        state = .disconnected
        notifyStateChange()
        addLog("ERROR: \(reason)")
        showNotification(title: "Connection Failed ❌", body: String(reason.prefix(100)))
        
        terminateAndCleanup()
    }
    
    /// Sends SIGTERM to the sudo parent, which relays it to openfortivpn so it can restore routes and DNS.
    /// No extra sudo commands are needed, so the sudoers rule can stay limited to openfortivpn.
    private func terminateAndCleanup() {
        guard let process = vpnProcess else {
            cleanupTempFiles()
            state = .disconnected
            notifyStateChange()
            finishStop()
            return
        }

        if process.isRunning {
            process.terminate()
        }

        // Safety net: if openfortivpn has not exited after 3s, stop waiting for it
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.vpnProcess === process else { return }
            self.state = .disconnected
            self.notifyStateChange()
            self.cleanupTempFiles()
            self.vpnProcess = nil
            self.outputPipe = nil
            self.addLog("Disconnected (forced)")
            self.finishStop()
        }
    }

    /// Stops the tunnel. `completion` runs once openfortivpn has exited, or right away if nothing runs.
    func disconnect(completion: (() -> Void)? = nil) {
        if let completion = completion {
            stopCompletions.append(completion)
        }

        guard vpnProcess != nil else {
            // Still checking the permission: launch() sees the new state and never starts openfortivpn
            if state != .disconnected {
                connectionTimeoutTimer?.invalidate()
                connectionTimeoutTimer = nil
                state = .disconnected
                notifyStateChange()
                addLog("Cancelled")
            }
            finishStop()
            return
        }

        if state != .disconnected {
            state = .disconnecting
            notifyStateChange()
            addLog("Disconnecting...")
        }

        terminateAndCleanup()
    }

    private func finishStop() {
        // Still waiting for openfortivpn to exit
        guard vpnProcess == nil else { return }
        let completions = stopCompletions
        stopCompletions = []
        completions.forEach { $0() }
    }
    
    private func cleanupTempFiles() {
        if let path = tempConfigPath {
            try? FileManager.default.removeItem(atPath: path)
            tempConfigPath = nil
        }
    }
    
    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        connectionLogs.append("[\(timestamp)] \(message)")
        
        if connectionLogs.count > 500 {
            connectionLogs.removeFirst()
        }
    }
    
    private func notifyStateChange() {
        NotificationCenter.default.post(name: .vpnStateChanged, object: nil)
    }
    
    private func showNotification(title: String, body: String) {
        // Notifications need an app bundle; command-line builds of this class (tests) have none
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
