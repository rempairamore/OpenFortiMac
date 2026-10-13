import Foundation

enum SudoersStatus: Equatable {
    /// Rule installed by OpenFortiMac and matching the current openfortivpn path
    case managed
    /// Passwordless sudo works, but through a rule OpenFortiMac did not install
    case external
    /// Rule installed by OpenFortiMac, but for a different openfortivpn path
    case outdated
    /// sudo would ask for a password
    case missing
    case binaryNotFound
}

enum SudoersError: LocalizedError {
    case cancelled
    case invalidUsername(String)
    case invalidPath(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Cancelled"
        case .invalidUsername(let name):
            return "Unsupported characters in username \"\(name)\""
        case .invalidPath(let path):
            return "Unsupported characters in openfortivpn path \"\(path)\""
        case .failed(let message):
            return message
        }
    }
}

/// Manages the sudoers rule that lets openfortivpn run as root without a password prompt.
final class SudoersManager {
    static let shared = SudoersManager()

    /// Files in sudoers.d whose name contains a dot are ignored by sudo, so no extension here.
    static let rulePath = "/etc/sudoers.d/openfortimac"

    private init() {}

    /// Blocking: runs sudo, call it off the main thread.
    func status(for binaryPath: String?) -> SudoersStatus {
        guard let binaryPath = binaryPath else { return .binaryNotFound }

        let ruleInstalled = FileManager.default.fileExists(atPath: Self.rulePath)

        switch (isAllowed(binaryPath: binaryPath), ruleInstalled) {
        case (true, true): return .managed
        case (true, false): return .external
        case (false, true): return .outdated
        case (false, false): return .missing
        }
    }

    /// Asks sudo whether the binary can run without a password (-n never prompts).
    func isAllowed(binaryPath: String) -> Bool {
        run("/usr/bin/sudo", ["-n", "-l", binaryPath]).status == 0
    }

    /// Blocking: shows the macOS administrator password dialog.
    func install(binaryPath: String) throws {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw SudoersError.invalidUsername(user)
        }
        // The path ends up inside single quotes and in a sudoers Cmnd, so keep it to safe characters
        guard binaryPath.range(of: "^/[A-Za-z0-9._/+-]+$", options: .regularExpression) != nil else {
            throw SudoersError.invalidPath(binaryPath)
        }

        let rule = "\(user) ALL = (root) NOPASSWD: \(binaryPath)"
        // Runs as root: the temp file is created by root, validated by visudo, then installed read-only
        let script = """
        t=$(/usr/bin/mktemp) && \
        printf '%s\\n' '\(rule)' > "$t" && \
        /usr/sbin/visudo -cf "$t" && \
        /usr/bin/install -m 0440 -o root -g wheel "$t" \(Self.rulePath); \
        r=$?; /bin/rm -f "$t"; exit $r
        """

        try runAsAdministrator(script, prompt: "OpenFortiMac wants to allow openfortivpn to start the VPN tunnel without asking for your password.")
    }

    /// Blocking: shows the macOS administrator password dialog.
    func remove() throws {
        try runAsAdministrator("/bin/rm -f \(Self.rulePath)", prompt: "OpenFortiMac wants to remove its openfortivpn sudo rule.")
    }

    // MARK: - Helpers

    /// Runs a shell script as root through the standard macOS authorization dialog.
    /// osascript runs as a separate process, so the hardened runtime needs no Apple Events entitlement.
    private func runAsAdministrator(_ script: String, prompt: String) throws {
        let source = "do shell script \(appleScriptString(script)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        let result = run("/usr/bin/osascript", ["-e", source])

        guard result.status != 0 else { return }

        // -128 is "User canceled" in the authorization dialog
        if result.output.contains("(-128)") {
            throw SudoersError.cancelled
        }
        throw SudoersError.failed(cleanOsascriptError(result.output))
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Turns "0:123: execution error: <message> (1)" into "<message>".
    private func cleanOsascriptError(_ output: String) -> String {
        var message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = message.range(of: "execution error: ") {
            message = String(message[range.upperBound...])
        }
        if let range = message.range(of: #" \(-?\d+\)$"#, options: .regularExpression) {
            message.removeSubrange(range)
        }
        return message.isEmpty ? "Could not change the sudo rule" : message
    }

    private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
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
}
