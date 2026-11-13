import Foundation

enum SudoersStatus: Equatable {
    /// Rule installed by OpenFortiMac and matching the current openfortivpn path
    case managed
    /// Passwordless sudo works, but through a rule OpenFortiMac did not install
    case external
    /// Rule installed by OpenFortiMac, but for a different openfortivpn path
    case outdated
    /// openfortivpn is allowed, but a server uses static routes and /sbin/route is not
    case routesMissing
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

    /// The only route commands the rule allows: network routes bound to a ppp interface.
    /// Argument wildcards keep the rule readable; values are CIDR-checked before use.
    static let routeCommands = ["add", "change", "delete"].map { "/sbin/route -n \($0) -net * -interface ppp*" }

    /// Blocking: runs sudo, call it off the main thread.
    /// `needsRoutes`: some server installs static routes, so /sbin/route must be allowed too.
    func status(for binaryPath: String?, needsRoutes: Bool = ConfigManager.shared.config.needsRoutePermission) -> SudoersStatus {
        guard let binaryPath = binaryPath else { return .binaryNotFound }

        let ruleInstalled = FileManager.default.fileExists(atPath: Self.rulePath)
        let allowed = isAllowed(binaryPath: binaryPath)

        if allowed && needsRoutes && !routesAllowed() {
            return .routesMissing
        }

        switch (allowed, ruleInstalled) {
        case (true, true): return .managed
        case (true, false): return .external
        case (false, true): return .outdated
        case (false, false): return .missing
        }
    }

    /// Runs the binary through `sudo -n` (never prompts) with a harmless flag.
    /// `sudo -l` is not enough: for administrators it also lists commands that still need a password.
    func isAllowed(binaryPath: String) -> Bool {
        let result = run("/usr/bin/sudo", ["-n", binaryPath, "--version"])
        return result.status == 0 && !Self.needsPassword(result.output)
    }

    /// Deletes a route that cannot exist (TEST-NET-1 on a ppp unit that is never created):
    /// sudo either asks for a password or runs route, which then fails harmlessly.
    func routesAllowed() -> Bool {
        let result = run("/usr/bin/sudo", ["-n", "/sbin/route", "-n", "delete", "-net", "192.0.2.0/24", "-interface", "ppp999"])
        return !Self.needsPassword(result.output)
    }

    static func needsPassword(_ sudoOutput: String) -> Bool {
        sudoOutput.contains("a password is required") || sudoOutput.contains("may not run sudo")
    }

    /// The sudoers file content written by `install`.
    static func ruleContent(user: String, binaryPath: String, includeRoutes: Bool) -> [String] {
        var lines = ["\(user) ALL = (root) NOPASSWD: \(binaryPath)"]
        if includeRoutes {
            lines.append("\(user) ALL = (root) NOPASSWD: " + routeCommands.joined(separator: ", "))
        }
        return lines
    }

    /// Blocking: shows the macOS administrator password dialog.
    /// `includeRoutes`: also allow /sbin/route for servers with static routes.
    func install(binaryPath: String, includeRoutes: Bool = ConfigManager.shared.config.needsRoutePermission) throws {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw SudoersError.invalidUsername(user)
        }
        // The path ends up inside single quotes and in a sudoers Cmnd, so keep it to safe characters
        guard binaryPath.range(of: "^/[A-Za-z0-9._/+-]+$", options: .regularExpression) != nil else {
            throw SudoersError.invalidPath(binaryPath)
        }

        let lines = Self.ruleContent(user: user, binaryPath: binaryPath, includeRoutes: includeRoutes)
            .map { "'\($0)'" }
            .joined(separator: " ")
        // Runs as root: the temp file is created by root, validated by visudo, then installed read-only
        let script = """
        t=$(/usr/bin/mktemp) && \
        printf '%s\\n' \(lines) > "$t" && \
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
