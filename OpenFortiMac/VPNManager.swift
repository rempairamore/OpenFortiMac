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
    
    @Published private(set) var state: VPNState = .disconnected
    @Published private(set) var connectionLogs: [String] = []
    
    private var vpnProcess: Process?
    private var outputPipe: Pipe?
    private var tempConfigPath: String?
    private var vpnPID: Int32?
    private var connectionTimeoutTimer: Timer?
    
    private init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    func connect(to server: VPNServer, password: String) {
        guard case .disconnected = state else {
            showNotification(title: "Already Connected", body: "Disconnect first before connecting to another server")
            return
        }
        
        state = .connecting
        connectionLogs = []
        notifyStateChange()
        addLog("Connecting to \(server.name)...")
        
        // Set connection timeout (30 seconds)
        DispatchQueue.main.async { [weak self] in
            self?.connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                guard let self = self, case .connecting = self.state else { return }
                self.addLog("ERROR: Connection timeout - server not responding")
                self.showNotification(title: "Connection Failed ❌", body: "Timeout - server not responding")
                self.terminateAndCleanup()
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performConnection(server: server, password: password)
        }
    }
    
    private func performConnection(server: VPNServer, password: String) {
        let tempDir = FileManager.default.temporaryDirectory
        let configPath = tempDir.appendingPathComponent("fortivpn_\(UUID().uuidString).conf")
        tempConfigPath = configPath.path
        
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
            try configContent.write(to: configPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath.path)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.connectionFailed(reason: "Failed to create config: \(error.localizedDescription)")
            }
            return
        }
        
        guard let openfortivpnPath = findOpenfortivpnBinary() else {
            DispatchQueue.main.async { [weak self] in
                self?.connectionFailed(reason: "openfortivpn not found. Install via: brew install openfortivpn")
            }
            return
        }
        
        var arguments = ["-c", configPath.path]
        if server.trustedCert == nil || server.trustedCert?.isEmpty == true {
            arguments.append("--trusted-cert=any")
        }
        
        runWithSudo(openfortivpnPath: openfortivpnPath, arguments: arguments, server: server)
    }
    
    private func findOpenfortivpnBinary() -> String? {
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
        process.arguments = [openfortivpnPath] + arguments
        
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
            
            // Capture the real openfortivpn PID after a short delay
            // pgrep -f matches the unique config path
            captureVPNPID()
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.connectionFailed(reason: "Failed to start process: \(error.localizedDescription)")
            }
        }
    }
    
    /// Polls pgrep to find the openfortivpn process by its unique config path.
    /// Retries a few times since sudo may take a moment to spawn the child.
    private func captureVPNPID() {
        guard let configPath = tempConfigPath else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for _ in 0..<10 {
                usleep(300_000) // 0.3s
                
                let pgrep = Process()
                pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                pgrep.arguments = ["-f", configPath]
                let pipe = Pipe()
                pgrep.standardOutput = pipe
                pgrep.standardError = FileHandle.nullDevice
                
                do {
                    try pgrep.run()
                    pgrep.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8) {
                        let pids = output.components(separatedBy: .newlines)
                            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                            .filter { $0 > 0 }
                        
                        if let pid = pids.first {
                            DispatchQueue.main.async {
                                self?.vpnPID = pid
                                self?.addLog("Captured openfortivpn PID: \(pid)")
                            }
                            return
                        }
                    }
                } catch {}
            }
        }
    }
    
    private func handleOutput(_ output: String, server: VPNServer) {
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        
        for line in lines {
            addLog(line)
            
            if line.contains("Tunnel is up and running") {
                connectionTimeoutTimer?.invalidate()
                connectionTimeoutTimer = nil
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
            } else if lower.contains("certificate") && lower.contains("error") {
                connectionFailed(reason: "Certificate error - try leaving certificate field empty")
            } else if lower.contains("gateway") && lower.contains("error") {
                connectionFailed(reason: "Gateway error: \(line)")
            }
        }
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
        vpnPID = nil
        outputPipe = nil
    }
    
    private func connectionFailed(reason: String) {
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        
        state = .disconnected
        notifyStateChange()
        addLog("ERROR: \(reason)")
        showNotification(title: "Connection Failed ❌", body: String(reason.prefix(100)))
        
        terminateAndCleanup()
    }
    
    /// Kills openfortivpn using the captured PID, falls back to pkill with unique config path.
    private func terminateAndCleanup() {
        guard let process = vpnProcess else {
            cleanupTempFiles()
            state = .disconnected
            notifyStateChange()
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var killed = false
            
            // Method 1: Kill by captured PID
            if let pid = self?.vpnPID, pid > 0 {
                let killProcess = Process()
                killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                killProcess.arguments = ["kill", "-SIGTERM", String(pid)]
                killProcess.standardOutput = FileHandle.nullDevice
                killProcess.standardError = FileHandle.nullDevice
                do {
                    try killProcess.run()
                    killProcess.waitUntilExit()
                    killed = (killProcess.terminationStatus == 0)
                } catch {}
            }
            
            // Method 2: Fallback - pkill matching unique config path
            if !killed, let configPath = self?.tempConfigPath {
                let killProcess = Process()
                killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                killProcess.arguments = ["pkill", "-SIGTERM", "-f", configPath]
                killProcess.standardOutput = FileHandle.nullDevice
                killProcess.standardError = FileHandle.nullDevice
                do {
                    try killProcess.run()
                    killProcess.waitUntilExit()
                    killed = (killProcess.terminationStatus == 0)
                } catch {}
            }
            
            DispatchQueue.main.async {
                if process.isRunning {
                    process.terminate()
                }
                
                // Safety net: force state update after 3s
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self?.state != .disconnected {
                        self?.state = .disconnected
                        self?.notifyStateChange()
                        self?.cleanupTempFiles()
                        self?.vpnProcess = nil
                        self?.vpnPID = nil
                        self?.outputPipe = nil
                        self?.addLog("Disconnected (forced)")
                    }
                }
            }
        }
    }
    
    func disconnect() {
        guard vpnProcess != nil else { return }
        
        state = .disconnecting
        notifyStateChange()
        addLog("Disconnecting...")
        
        terminateAndCleanup()
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
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
