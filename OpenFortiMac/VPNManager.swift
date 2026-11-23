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

/// One line of the connection log.
struct LogEntry: Identifiable, Equatable {
    enum Level: Equatable {
        case info, ok, warning, error
    }

    let id: Int
    let date: Date
    let level: Level
    let message: String

    var tag: String {
        switch level {
        case .info: return "INFO"
        case .ok: return "OK"
        case .warning: return "WARN"
        case .error: return "ERR"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var time: String { Self.timeFormatter.string(from: date) }

    /// Plain text, for copying and saving
    var text: String { "\(time) \(tag.padding(toLength: 4, withPad: " ", startingAt: 0)) \(message)" }
}

/// Why the last attempt failed. Shown in the panel until the next attempt.
struct ConnectionFailure: Equatable {
    enum Kind: Equatable {
        case authentication
        /// The gateway's certificate is not signed by a trusted authority; `digest` is its sha256
        case untrustedCertificate(digest: String?, subject: String?)
        case permission
        case other
    }

    let serverID: String
    let serverName: String
    let kind: Kind
    let title: String
    let detail: String
}

/// What openfortivpn is waiting for from the user while connecting.
enum PendingInput: Equatable {
    case code
    case browserSignIn(URL)
}

struct TunnelTraffic: Equatable {
    var received: UInt64
    var sent: UInt64
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
                traffic = nil
                pendingInput = nil
                stopTrafficMonitor()
            }
        }
    }
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var currentServer: VPNServer?
    @Published private(set) var connectedSince: Date?
    @Published private(set) var assignedIP: String?
    @Published private(set) var traffic: TunnelTraffic?
    @Published private(set) var pendingInput: PendingInput?
    @Published private(set) var lastFailure: ConnectionFailure?

    /// Opens the single sign-on page in the browser; replaced in tests
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private var vpnProcess: Process?
    private var outputPipe: Pipe?
    private var inputPipe: Pipe?
    private var tempConfigPath: String?
    private var timeoutTimer: Timer?
    /// Run once openfortivpn has exited, e.g. to let the app quit
    private var stopCompletions: [() -> Void] = []

    private var nextLogID = 0
    /// Output received after the last line break: a question, if openfortivpn is waiting
    private var unfinishedOutput = ""
    private var attemptFirstLogID = 0
    private var codeWasSent = false
    private var certificateSubject: [String] = []
    private var readingCertificateSubject = false

    private var interfaceName: String?
    private var trafficTimer: Timer?
    private var lastCounters: (received: UInt32, sent: UInt32)?

    /// A tunnel is starting, up, or openfortivpn is still shutting down.
    var isActive: Bool {
        state != .disconnected || vpnProcess != nil
    }

    /// The sudo process of the tunnel this app started, if any.
    var currentProcessID: Int32? {
        vpnProcess?.processIdentifier
    }

    private init() {
        // Writing a code to an openfortivpn that just exited must not end the app
        signal(SIGPIPE, SIG_IGN)
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Connecting

    /// `password` is nil for single sign-on, where the browser does the login.
    func connect(to server: VPNServer, password: String?) {
        guard case .disconnected = state else {
            showNotification(title: String(localized: "Already Connected"),
                             body: String(localized: "Disconnect first before connecting to another server"))
            return
        }
        // The previous openfortivpn is still shutting down: launching now would be refused
        guard vpnProcess == nil else {
            showNotification(title: String(localized: "Still Disconnecting"), body: String(localized: "Try again in a moment"))
            return
        }

        lastFailure = nil
        codeWasSent = false
        unfinishedOutput = ""
        certificateSubject = []
        readingCertificateSubject = false
        interfaceName = nil
        attemptFirstLogID = nextLogID

        state = .connecting
        currentServer = server
        notifyStateChange()
        addLog("Connecting to \(server.name)…")

        // Created right away, so a stale timer never outlives a cancel
        armTimeout(30, log: "Timeout: the server did not respond",
                   detail: String(localized: "\(server.name) did not answer in time."))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performConnection(server: server, password: password)
        }
    }

    /// Restarts the countdown for the current phase of the connection.
    private func armTimeout(_ seconds: TimeInterval, log: String, detail: String) {
        timeoutTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self = self, case .connecting = self.state else { return }
            self.addLog(log, level: .error)
            self.connectionFailed(title: String(localized: "No response"), detail: detail)
        }
        RunLoop.main.add(timer, forMode: .common)
        timeoutTimer = timer
    }

    private func cancelTimeout() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    /// Slow checks off the main thread; the launch itself happens on the main thread.
    private func performConnection(server: VPNServer, password: String?) {
        guard let openfortivpnPath = findOpenfortivpnBinary() else {
            DispatchQueue.main.async { [weak self] in
                self?.connectionFailed(title: String(localized: "openfortivpn not found"),
                                       detail: String(localized: "Install it with brew install openfortivpn."))
            }
            return
        }

        // Fail early with a clear message instead of a bare sudo error
        guard SudoersManager.shared.isAllowed(binaryPath: openfortivpnPath) else {
            DispatchQueue.main.async { [weak self] in
                self?.connectionFailed(.permission,
                                       title: String(localized: "Administrator permission not set up"),
                                       detail: String(localized: "Open Settings › Permission."))
            }
            return
        }

        // Built before any file is written, so invalid values never reach the disk
        let configContent: String
        do {
            configContent = try OpenfortivpnConfig.make(server: server, password: password)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.connectionFailed(title: String(localized: "Connection failed"), detail: error.localizedDescription)
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
            connectionFailed(title: String(localized: "Connection failed"),
                             detail: String(localized: "The connection could not be prepared: \(error.localizedDescription)"))
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
        // openfortivpn reads a two-factor code from its standard input
        let input = Pipe()
        process.standardInput = input

        outputPipe = pipe
        inputPipe = input
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
            addLog("Starting openfortivpn…")
        } catch {
            vpnProcess = nil
            outputPipe = nil
            inputPipe = nil
            connectionFailed(title: String(localized: "Connection failed"),
                             detail: String(localized: "openfortivpn could not be started: \(error.localizedDescription)"))
        }
    }

    // MARK: - Output

    private func handleOutput(_ output: String, server: VPNServer) {
        // openfortivpn reads its config before printing anything: the file with the password can go now
        cleanupTempFiles()

        unfinishedOutput += output
        var lines = unfinishedOutput.components(separatedBy: .newlines)
        unfinishedOutput = lines.removeLast()

        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            handleLine(line, server: server)
        }

        // Log lines start with their level and end with a line break. Anything else that
        // stops without one is a question openfortivpn is waiting on: the two-factor code.
        let question = unfinishedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty, !Self.startsWithLogLevel(question), case .connecting = state {
            unfinishedOutput = ""
            addLog(question)
            pendingInput = .code
            armTimeout(300, log: "Timeout: no code entered",
                       detail: String(localized: "No code was entered in time."))
        }
    }

    private func handleLine(_ line: String, server: VPNServer) {
        let entry = addLog(fromOpenfortivpn: line)

        if let ip = Self.assignedAddress(in: line) {
            assignedIP = ip
        }
        if let name = Self.firstGroup(#"Interface (\S+) is UP"#, in: line) {
            interfaceName = name
        }
        readCertificateDetails(entry.message)

        if line.contains("Tunnel is up and running") {
            cancelTimeout()
            pendingInput = nil
            connectedSince = Date()
            state = .connected(serverName: server.name)
            notifyStateChange()
            startTrafficMonitor()
            showNotification(title: String(localized: "VPN Connected"), body: server.name)
            return
        }

        guard case .connecting = state else { return }

        if let address = Self.firstGroup(#"Authenticate at '([^']+)'"#, in: line) {
            startBrowserSignIn(address, server: server)
            return
        }
        if line.contains("Connected to gateway") || line.contains("Processing HTTP SAML request") {
            if case .browserSignIn = pendingInput {
                pendingInput = nil
            }
            // The sign-in can include an approval on the phone, so it gets more time than the first contact
            armTimeout(120, log: "Timeout: the gateway did not complete the sign-in",
                       detail: String(localized: "The sign-in was not completed in time."))
        }

        guard entry.level == .error else { return }
        let lower = line.lowercased()

        if lower.contains("could not authenticate to gateway") || lower.contains("authentication failed") || lower.contains("login failed") {
            connectionFailed(.authentication,
                             title: String(localized: "Authentication failed"),
                             detail: codeWasSent
                                ? String(localized: "Check the two-factor code and the password of \(server.name).")
                                : String(localized: "Check the username and password of \(server.name)."))
        } else if lower.contains("no otp specified") || lower.contains("no token specified") {
            connectionFailed(.authentication,
                             title: String(localized: "Two-factor code missing"),
                             detail: String(localized: "\(server.name) asks for a code. Connect again and enter it."))
        } else if lower.contains("not in the local whitelist") {
            connectionFailed(.untrustedCertificate(digest: nil, subject: nil),
                             title: String(localized: "Certificate not trusted"),
                             detail: String(localized: "The certificate of \(server.name) is not signed by a trusted authority."))
        } else if lower.contains("getaddrinfo") || lower.contains("could not resolve") || lower.contains("cannot resolve") {
            connectionFailed(title: String(localized: "Server not found"),
                             detail: String(localized: "Cannot find \(server.host). Check the address and your connection."))
        } else if lower.contains("connection refused") {
            connectionFailed(title: String(localized: "Connection refused"),
                             detail: String(localized: "\(server.host):\(String(server.port)) refused the connection."))
        } else if lower.contains("timed out") {
            connectionFailed(title: String(localized: "No response"),
                             detail: String(localized: "\(server.name) did not answer in time."))
        }
        // Other errors end openfortivpn: handleTermination reports them
    }

    /// Single sign-on: openfortivpn prints the page to open and waits for the browser to come back.
    private func startBrowserSignIn(_ address: String, server: VPNServer) {
        // The address comes from openfortivpn's output: open it only if it is this server's
        guard let url = URL(string: address), url.scheme == "https",
              url.host?.lowercased() == server.host.lowercased() else {
            connectionFailed(title: String(localized: "Single sign-on failed"),
                             detail: String(localized: "The sign-in address is not the one of \(server.name)."))
            return
        }
        pendingInput = .browserSignIn(url)
        armTimeout(300, log: "Timeout: the sign-in in the browser was not completed",
                   detail: String(localized: "The sign-in in the browser was not completed in time."))
        openURL(url)
    }

    func reopenSignInPage() {
        if case .browserSignIn(let url) = pendingInput {
            openURL(url)
        }
    }

    /// Sends the two-factor code openfortivpn is waiting for.
    func submitCode(_ code: String) {
        guard case .code = pendingInput, let input = inputPipe else { return }
        let cleaned = code.filter { !$0.isWhitespace && !$0.isNewline }
        guard !cleaned.isEmpty else { return }

        do {
            try input.fileHandleForWriting.write(contentsOf: Data((cleaned + "\n").utf8))
        } catch {
            addLog("Could not send the code: \(error.localizedDescription)", level: .error)
            return
        }
        codeWasSent = true
        pendingInput = nil
        addLog("Code sent")
        armTimeout(120, log: "Timeout: the gateway did not complete the sign-in",
                   detail: String(localized: "The sign-in was not completed in time."))
    }

    /// openfortivpn lists the refused certificate over several lines: subject, issuer, sha256 digest.
    private func readCertificateDetails(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespaces)

        if text == "subject:" {
            readingCertificateSubject = true
            certificateSubject = []
        } else if text == "issuer:" || text == "sha256 digest:" {
            readingCertificateSubject = false
        } else if readingCertificateSubject {
            certificateSubject.append(text)
        }

        guard case .untrustedCertificate(let knownDigest, _) = lastFailure?.kind, let failure = lastFailure else { return }
        let digest = Self.firstGroup(#"trusted-cert[ =]+([0-9a-f]{64})"#, in: text) ?? knownDigest
        let commonName = certificateSubject.first { $0.hasPrefix("CN=") }.map { String($0.dropFirst(3)) }
        lastFailure = ConnectionFailure(serverID: failure.serverID, serverName: failure.serverName,
                                        kind: .untrustedCertificate(digest: digest, subject: commonName ?? certificateSubject.first),
                                        title: failure.title, detail: failure.detail)
    }

    private static func startsWithLogLevel(_ text: String) -> Bool {
        ["INFO:", "WARN:", "ERROR:", "DEBUG:"].contains { text.hasPrefix($0) }
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
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

    // MARK: - Ending

    private func handleTermination(exitCode: Int32) {
        cancelTimeout()
        cleanupTempFiles()

        let previousState = state

        if case .connecting = previousState {
            // openfortivpn gave up without one of the errors handled above: show its last one
            let lastError = logs.last { $0.id >= attemptFirstLogID && $0.level == .error }?.message
                .trimmingCharacters(in: .whitespaces)
            let detail = lastError ?? String(localized: "openfortivpn stopped with code \(String(exitCode)).")
            recordFailure(.other, title: String(localized: "Connection failed"), detail: detail)
            state = .disconnected
            notifyStateChange()
            addLog("Connection failed (exit code: \(exitCode))", level: .error)
            showNotification(title: String(localized: "Connection Failed"), body: String(detail.prefix(100)))
        } else if case .connected = previousState {
            state = .disconnected
            notifyStateChange()
            addLog("Disconnected (exit code: \(exitCode))", level: exitCode == 0 ? .info : .warning)
            showNotification(title: String(localized: "VPN Disconnected"), body: String(localized: "Connection ended"))
        } else {
            if case .disconnecting = previousState {
                addLog("Disconnected")
            }
            state = .disconnected
            notifyStateChange()
        }

        vpnProcess = nil
        outputPipe = nil
        inputPipe = nil
        finishStop()
    }

    private func recordFailure(_ kind: ConnectionFailure.Kind, title: String, detail: String) {
        guard let server = currentServer else { return }
        lastFailure = ConnectionFailure(serverID: server.id, serverName: server.name,
                                        kind: kind, title: title, detail: detail)
    }

    private func connectionFailed(_ kind: ConnectionFailure.Kind = .other, title: String, detail: String) {
        // Already cancelled while the permission was being checked: nothing left to report
        guard state != .disconnected || vpnProcess != nil else { return }

        cancelTimeout()
        recordFailure(kind, title: title, detail: detail)

        state = .disconnected
        notifyStateChange()
        addLog("\(title): \(detail)", level: .error)
        showNotification(title: String(localized: "Connection Failed"), body: String("\(title). \(detail)".prefix(100)))

        terminateAndCleanup()
    }

    /// Forgets the failure shown in the panel.
    func dismissFailure() {
        lastFailure = nil
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
            self.inputPipe = nil
            self.addLog("Disconnected (forced)", level: .warning)
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
                cancelTimeout()
                state = .disconnected
                notifyStateChange()
                addLog("Cancelled")
            }
            finishStop()
            return
        }

        cancelTimeout()
        if state != .disconnected {
            state = .disconnecting
            notifyStateChange()
            addLog("Disconnecting…")
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

    // MARK: - Traffic

    /// Reads the tunnel interface's byte counters every two seconds while connected.
    private func startTrafficMonitor() {
        stopTrafficMonitor()
        guard interfaceName != nil else { return }
        lastCounters = nil
        updateTraffic()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateTraffic()
        }
        RunLoop.main.add(timer, forMode: .common)
        trafficTimer = timer
    }

    private func stopTrafficMonitor() {
        trafficTimer?.invalidate()
        trafficTimer = nil
        lastCounters = nil
    }

    private func updateTraffic() {
        guard let name = interfaceName, let counters = Self.interfaceCounters(name) else { return }
        if let last = lastCounters, var total = traffic {
            // The system counters are 32-bit: wrapping subtraction keeps the totals right past 4 GB
            total.received += UInt64(counters.received &- last.received)
            total.sent += UInt64(counters.sent &- last.sent)
            traffic = total
        } else {
            // The interface was created for this tunnel, so its counters start from zero
            traffic = TunnelTraffic(received: UInt64(counters.received), sent: UInt64(counters.sent))
        }
        lastCounters = counters
    }

    static func interfaceCounters(_ name: String) -> (received: UInt32, sent: UInt32)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: entry.pointee.ifa_name) == name,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            return (counters.ifi_ibytes, counters.ifi_obytes)
        }
        return nil
    }

    // MARK: - Log

    func clearLogs() {
        logs = []
    }

    @discardableResult
    private func addLog(_ message: String, level: LogEntry.Level = .info) -> LogEntry {
        let entry = LogEntry(id: nextLogID, date: Date(), level: level, message: message)
        nextLogID += 1
        logs.append(entry)

        if logs.count > 500 {
            logs.removeFirst()
        }
        return entry
    }

    /// openfortivpn starts every line with its level, padded to eight characters.
    private func addLog(fromOpenfortivpn line: String) -> LogEntry {
        let levels: [(prefix: String, level: LogEntry.Level)] = [
            ("ERROR:", .error), ("WARN:", .warning), ("INFO:", .info), ("DEBUG:", .info)
        ]
        guard let match = levels.first(where: { line.hasPrefix($0.prefix) }) else {
            return addLog(line)
        }
        var message = Substring(line.dropFirst(match.prefix.count))
        var padding = 8 - match.prefix.count
        while padding > 0, message.first == " " {
            message = message.dropFirst()
            padding -= 1
        }
        let level: LogEntry.Level = message.contains("Tunnel is up and running") ? .ok : match.level
        return addLog(String(message), level: level)
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

#if DEBUG
extension VPNManager {
    /// Puts the manager in a given state, for SwiftUI previews and rendering checks.
    func setPreview(state: VPNState, server: VPNServer? = nil, since: Date? = nil, ip: String? = nil,
                    traffic: TunnelTraffic? = nil, pendingInput: PendingInput? = nil,
                    failure: ConnectionFailure? = nil, logs: [LogEntry] = []) {
        self.state = state
        self.currentServer = server
        self.connectedSince = since
        self.assignedIP = ip
        self.traffic = traffic
        self.pendingInput = pendingInput
        self.lastFailure = failure
        self.logs = logs
    }
}
#endif
