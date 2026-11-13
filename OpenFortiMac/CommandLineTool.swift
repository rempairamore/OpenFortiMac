import Foundation
import AppKit

/// `openfortimac` command line interface. The app executable doubles as the CLI:
/// link it into PATH, e.g.
///
///     ln -s /Applications/OpenFortiMac.app/Contents/MacOS/OpenFortiMac /opt/homebrew/bin/openfortimac
///
/// Commands are executed by the running app (launched in the background when needed),
/// which owns the tunnels, the Keychain access and the sudo rule.
enum CommandLineTool {
    static let commands: Set<String> = [
        "list", "ls", "status", "st", "connect", "up", "disconnect", "down", "logs", "log",
        "add", "edit", "remove", "rm", "show", "settings", "permission",
        "help", "--help", "-h", "version", "--version"
    ]

    /// True when the process was started as `openfortimac <command>` rather than as the app.
    /// Launch Services and Xcode only pass "-…" arguments, so any other word is a CLI call
    /// (unknown ones print the usage instead of starting a second app instance).
    static func handles(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        return commands.contains(arguments[1]) || !arguments[1].hasPrefix("-")
    }

    static func run(_ arguments: [String]) -> Int32 {
        var args = Array(arguments.dropFirst())
        let command = args.removeFirst()
        let json = takeFlag("--json", from: &args)

        switch command {
        case "list", "ls":
            return list(json: json)
        case "status", "st":
            return status(json: json)
        case "connect", "up":
            let noWait = takeFlag("--no-wait", from: &args)
            let timeout = takeOption("--timeout", from: &args).flatMap(Double.init) ?? 45
            guard let query = args.first else { return usage("connect needs a server name") }
            return connect(query, wait: !noWait, timeout: timeout)
        case "disconnect", "down":
            let noWait = takeFlag("--no-wait", from: &args)
            let all = takeFlag("--all", from: &args) || args.first == "all"
            guard all || args.first != nil else { return usage("disconnect needs a server name or --all") }
            return disconnect(all ? nil : args.first, wait: !noWait)
        case "add":
            return add(args)
        case "edit":
            return edit(args)
        case "remove", "rm":
            return remove(args)
        case "show":
            return show(args, json: json)
        case "settings":
            return settings(args, json: json)
        case "permission":
            return permission(args)
        case "logs", "log":
            let follow = takeFlag("-f", from: &args) || takeFlag("--follow", from: &args)
            let lines = takeOption("-n", from: &args) ?? "50"
            return logs(lines: lines, follow: follow)
        case "version", "--version":
            // Called through a symlink, Bundle.main does not see the app bundle: resolve it
            var size = UInt32(PATH_MAX)
            var buffer = [CChar](repeating: 0, count: Int(size))
            _ = _NSGetExecutablePath(&buffer, &size)
            let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
            let bundle = Bundle(url: executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) ?? .main
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            print("openfortimac \(version)")
            return 0
        case "help", "--help", "-h":
            printUsage()
            return 0
        default:
            return usage("unknown command \"\(command)\"")
        }
    }

    // MARK: - Commands

    static func list(json: Bool) -> Int32 {
        let servers = ConfigManager.shared.config.servers
        let state = runningState()

        if json {
            let items: [[String: Any]] = servers.map { server in
                var item: [String: Any] = [
                    "id": server.id,
                    "name": server.name,
                    "host": server.host,
                    "port": server.port,
                    "username": server.username,
                    "no_routes_dns": server.noRoutesDNS,
                    "static_routes": server.staticRoutes,
                    "auto_connect": server.autoConnect,
                    "auto_reconnect": server.autoReconnect,
                    "state": state?.tunnels.first { $0.id == server.id }?.state ?? "disconnected"
                ]
                if let error = state?.errors[server.id] {
                    item["last_error"] = error.message
                }
                return item
            }
            return printJSON(items)
        }

        if servers.isEmpty {
            print("No servers configured. Add one in OpenFortiMac › Settings › Servers.")
            return 0
        }

        let nameWidth = servers.map(\.name.count).max() ?? 0
        for server in servers {
            let tunnelState = state?.tunnels.first { $0.id == server.id }?.state ?? "-"
            var flags: [String] = []
            if server.noRoutesDNS { flags.append("no-routes/dns") }
            if !server.staticRoutes.isEmpty { flags.append("routes: " + server.staticRoutes.joined(separator: ",")) }
            if server.autoConnect { flags.append("auto-connect") }
            if server.autoReconnect { flags.append("auto-reconnect") }
            let line = [
                pad(server.name, nameWidth),
                pad(tunnelState, 13),
                pad("\(server.host):\(server.port)", 22),
                flags.joined(separator: "  ")
            ].joined(separator: "  ")
            print(line.trimmingCharacters(in: .whitespaces))
        }
        if state == nil {
            print("\n(OpenFortiMac is not running)")
        }
        return 0
    }

    static func status(json: Bool) -> Int32 {
        guard let state = runningState() else {
            if json { return printJSON(["running": false, "tunnels": []] as [String: Any]) }
            print("OpenFortiMac is not running")
            return 3
        }

        if json {
            guard let data = try? CLIProtocol.encoder().encode(state),
                  let text = String(data: data, encoding: .utf8) else { return 1 }
            print(text)
            return 0
        }

        if state.tunnels.isEmpty {
            print("No active tunnels")
            return 0
        }

        let nameWidth = state.tunnels.map(\.name.count).max() ?? 0
        for tunnel in state.tunnels {
            var columns = [pad(tunnel.name, nameWidth), pad(tunnel.state, 13)]
            if let since = tunnel.since {
                columns.append(pad(duration(Date().timeIntervalSince(since)), 9))
            }
            if let ip = tunnel.ip { columns.append(pad(ip, 15)) }
            if let iface = tunnel.interface { columns.append(pad(iface, 5)) }
            if !tunnel.routes.isEmpty { columns.append("routes: " + tunnel.routes.joined(separator: ",")) }
            print(columns.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
        }
        return 0
    }

    static func connect(_ query: String, wait: Bool, timeout: TimeInterval) -> Int32 {
        guard let server = resolve(query) else { return 2 }
        guard let state = ensureRunning() else {
            printError("could not start OpenFortiMac")
            return 3
        }
        if let tunnel = state.tunnels.first(where: { $0.id == server.id }), tunnel.state == "connected" {
            print("\(server.name) is already connected")
            return 0
        }

        let requested = Date()
        send(.connect, server: server.id)
        guard wait else { return 0 }

        var seen = false
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            guard let state = runningState() else {
                printError("OpenFortiMac quit")
                return 3
            }
            if let tunnel = state.tunnels.first(where: { $0.id == server.id }) {
                seen = true
                if tunnel.state == "connected" {
                    var details = [tunnel.ip, tunnel.interface].compactMap { $0 }
                    if !tunnel.routes.isEmpty { details.append("routes: " + tunnel.routes.joined(separator: ",")) }
                    print("Connected \(server.name)" + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"))
                    return 0
                }
            } else if let error = state.errors[server.id], error.date >= requested.addingTimeInterval(-1) {
                printError("\(server.name): \(error.message)")
                return 1
            } else if seen || Date().timeIntervalSince(requested) > 5 {
                printError("\(server.name) did not connect, see: openfortimac logs")
                return 1
            }
        }
        printError("\(server.name): still not connected after \(Int(timeout))s")
        return 1
    }

    static func disconnect(_ query: String?, wait: Bool) -> Int32 {
        guard let state = runningState() else {
            print("OpenFortiMac is not running: nothing to disconnect")
            return 0
        }

        var targets: [String]
        if let query = query {
            guard let server = resolve(query) else { return 2 }
            guard state.tunnels.contains(where: { $0.id == server.id }) else {
                print("\(server.name) is not connected")
                return 0
            }
            targets = [server.id]
            send(.disconnect, server: server.id)
        } else {
            targets = state.tunnels.map(\.id)
            send(.disconnectAll, server: nil)
        }
        guard wait else { return 0 }

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            let remaining = runningState()?.tunnels.filter { targets.contains($0.id) } ?? []
            if remaining.isEmpty {
                print(targets.isEmpty ? "No active tunnels" : "Disconnected")
                return 0
            }
        }
        printError("tunnels still up after 15s")
        return 1
    }

    static func logs(lines: String, follow: Bool) -> Int32 {
        let path = CLIProtocol.logURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            print("No log yet (\(path))")
            return 0
        }
        var arguments = ["tail", "-n", lines]
        if follow { arguments.append("-F") }
        arguments.append(path)
        let cArgs = arguments.map { strdup($0) } + [nil]
        execv("/usr/bin/tail", cArgs)
        printError("could not run tail")
        return 1
    }

    // MARK: - App communication

    /// State published by the running app, nil when it is not running.
    static func runningState() -> CLIProtocol.State? {
        guard let data = try? Data(contentsOf: CLIProtocol.stateURL),
              let state = try? CLIProtocol.decoder().decode(CLIProtocol.State.self, from: data) else { return nil }
        // A stale file from a crashed app: its pid is gone (EPERM would mean it exists)
        guard kill(state.pid, 0) == 0 || errno == EPERM else { return nil }
        return state
    }

    /// Starts the app in the background when it is not running and waits for its state.
    static func ensureRunning() -> CLIProtocol.State? {
        if let state = runningState() { return state }

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", CLIProtocol.bundleIdentifier]
        try? open.run()
        open.waitUntilExit()

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            if let state = runningState() {
                // Let the app finish wiring its observers
                Thread.sleep(forTimeInterval: 0.5)
                return state
            }
        }
        return nil
    }

    static func send(_ action: CLIProtocol.Action, server: String?) {
        var info: [String: String] = ["action": action.rawValue]
        info["server"] = server
        DistributedNotificationCenter.default().postNotificationName(
            CLIProtocol.commandNotification,
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
    }

    /// Matches by id, exact name, then unique case-insensitive name prefix.
    static func resolve(_ query: String) -> VPNServer? {
        let servers = ConfigManager.shared.config.servers
        if let server = servers.first(where: { $0.id == query })
            ?? servers.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            return server
        }
        let matches = servers.filter { $0.name.lowercased().hasPrefix(query.lowercased()) }
        if matches.count == 1 { return matches[0] }

        if matches.isEmpty {
            printError("no server matches \"\(query)\". Servers: " + servers.map { "\"\($0.name)\"" }.joined(separator: ", "))
        } else {
            printError("\"\(query)\" is ambiguous: " + matches.map { "\"\($0.name)\"" }.joined(separator: ", "))
        }
        return nil
    }

    // MARK: - Helpers

    static func takeFlag(_ flag: String, from args: inout [String]) -> Bool {
        guard let index = args.firstIndex(of: flag) else { return false }
        args.remove(at: index)
        return true
    }

    static func takeOption(_ option: String, from args: inout [String]) -> String? {
        guard let index = args.firstIndex(of: option), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    static func printJSON(_ object: Any) -> Int32 {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return 1 }
        print(text)
        return 0
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data("openfortimac: \(message)\n".utf8))
    }

    @discardableResult
    static func usage(_ message: String) -> Int32 {
        printError(message)
        printUsage()
        return 2
    }

    static func printUsage() {
        print("""
        usage: openfortimac <command> [options]

          list [--json]                       servers and their state
          status [--json]                     active tunnels (time, IP, interface, routes)
          connect <server> [--no-wait] [--timeout s]
                                              connect; waits until the tunnel is up
          disconnect <server> | --all [--no-wait]
          logs [-n lines] [-f]                tunnel log (openfortivpn output)

          show <server> [--json]              server details
          add <name> --host <host> --user <user> [server options]
          edit <server> [server options] [--name <new name>]
          remove <server> [--yes]             also deletes the saved password
          settings [--allow-multiple on|off] [--menu-bar-icon classic|monochrome]
                   [--openfortivpn-path <path>] [--json]
          permission [install|update]         sudo rule for openfortivpn and static routes
          version

        Server options:
          --host <host>  --port <port>  --user <user>  --icon <sf symbol>
          --cert <sha256> | --no-cert         pin the gateway certificate (default: any)
          --password                          prompt for the password (saved in the Keychain)
          --password-stdin                    read the password from stdin
          --no-routes-dns | --routes-dns      pass --no-routes --no-dns (secondary tunnel)
          --route <cidr>                      static route via the tunnel (repeatable; edit: replaces)
          --add-route <cidr> --remove-route <cidr> --clear-routes
          --auto-connect | --no-auto-connect  connect when OpenFortiMac starts
          --auto-reconnect | --no-auto-reconnect
                                              reconnect when the tunnel drops, until disconnected

        <server> is a name, a unique name prefix (case-insensitive) or an id.
        Commands run through the OpenFortiMac app, which is started in the background if needed.
        Exit codes: 0 ok, 1 failed, 2 usage / unknown server, 3 app not running.
        """)
    }
}
