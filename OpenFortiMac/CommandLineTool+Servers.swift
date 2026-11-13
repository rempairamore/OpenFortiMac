import Foundation

/// Server management and settings for the `openfortimac` CLI: add, edit, remove, show,
/// settings, permission. Writes config.json and the Keychain directly (same signed
/// executable as the app), then asks a running app to reload.
extension CommandLineTool {

    // MARK: - Option parsing

    struct Options {
        var positional: [String] = []
        var values: [String: [String]] = [:]
        var flags: Set<String> = []

        func value(_ name: String) -> String? { values[name]?.last }
        func all(_ name: String) -> [String] { values[name] ?? [] }
        func has(_ name: String) -> Bool { flags.contains(name) }
    }

    /// Options taking a value; everything else starting with "--" is a flag.
    static let valueOptions: Set<String> = [
        "--name", "--host", "--port", "--user", "--username", "--cert", "--icon",
        "--route", "--add-route", "--remove-route",
        "--allow-multiple", "--openfortivpn-path", "--menu-bar-icon"
    ]

    static func parseOptions(_ args: [String]) -> Options? {
        var options = Options()
        var index = 0
        while index < args.count {
            var arg = args[index]
            var inlineValue: String?
            // --host=example.com
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                inlineValue = String(arg[arg.index(after: eq)...])
                arg = String(arg[..<eq])
            }
            if valueOptions.contains(arg) {
                let key = arg == "--username" ? "--user" : arg
                if let value = inlineValue {
                    options.values[key, default: []].append(value)
                } else if index + 1 < args.count {
                    options.values[key, default: []].append(args[index + 1])
                    index += 1
                } else {
                    printError("\(arg) needs a value")
                    return nil
                }
            } else if arg.hasPrefix("--") || arg == "-y" {
                options.flags.insert(arg)
            } else {
                options.positional.append(arg)
            }
            index += 1
        }
        return options
    }

    // MARK: - add

    static func add(_ args: [String]) -> Int32 {
        guard let options = parseOptions(args) else { return 2 }
        guard let name = (options.value("--name") ?? options.positional.first)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else {
            return usage("add needs a name: openfortimac add <name> --host <host> --user <user>")
        }
        guard let host = options.value("--host"), let user = options.value("--user") else {
            return usage("add needs --host and --user")
        }

        var servers = ConfigManager.shared.config.servers
        if servers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            printError("a server named \"\(name)\" already exists (use edit)")
            return 2
        }

        let routes = options.all("--route") + options.all("--add-route")
        let server = VPNServer(
            name: name,
            host: host,
            port: Int(options.value("--port") ?? "443") ?? -1,
            username: user,
            password: nil,
            trustedCert: nonEmpty(options.value("--cert")),
            icon: options.value("--icon") ?? VPNServer.defaultIcon,
            noRoutesDNS: options.has("--no-routes-dns"),
            staticRoutes: routes,
            autoConnect: options.has("--auto-connect"),
            autoReconnect: options.has("--auto-reconnect")
        )
        if let problem = validate(server) {
            printError(problem)
            return 2
        }

        if let code = storePassword(options, serverID: server.id, required: false) {
            return code
        }

        servers.append(server)
        ConfigManager.shared.saveServers(servers)
        configChanged()
        print("Added \(server.name)" + (KeychainHelper.read(for: server.id) == nil ? " (no password yet: openfortimac edit \"\(server.name)\" --password)" : ""))
        warnIfRoutesNeedPermission(server)
        return 0
    }

    // MARK: - edit

    static func edit(_ args: [String]) -> Int32 {
        guard let options = parseOptions(args) else { return 2 }
        guard let query = options.positional.first else {
            return usage("edit needs a server: openfortimac edit <server> [options]")
        }
        guard let old = resolve(query) else { return 2 }

        var routes = old.staticRoutes
        if !options.all("--route").isEmpty { routes = options.all("--route") }
        if options.has("--clear-routes") { routes = [] }
        routes += options.all("--add-route").filter { !routes.contains($0) }
        routes.removeAll { options.all("--remove-route").contains($0) }

        var noRoutesDNS = old.noRoutesDNS
        if options.has("--no-routes-dns") { noRoutesDNS = true }
        if options.has("--routes-dns") { noRoutesDNS = false }

        var autoConnect = old.autoConnect
        if options.has("--auto-connect") { autoConnect = true }
        if options.has("--no-auto-connect") { autoConnect = false }

        var autoReconnect = old.autoReconnect
        if options.has("--auto-reconnect") { autoReconnect = true }
        if options.has("--no-auto-reconnect") { autoReconnect = false }

        var cert = old.trustedCert
        if let value = options.value("--cert") { cert = nonEmpty(value) }
        if options.has("--no-cert") { cert = nil }

        let name = options.value("--name")?.trimmingCharacters(in: .whitespaces) ?? old.name
        let server = VPNServer(
            name: name,
            host: options.value("--host") ?? old.host,
            port: options.value("--port").map { Int($0) ?? -1 } ?? old.port,
            username: options.value("--user") ?? old.username,
            password: old.password,
            trustedCert: cert,
            icon: options.value("--icon") ?? old.icon,
            id: old.id,
            noRoutesDNS: noRoutesDNS,
            staticRoutes: routes,
            autoConnect: autoConnect,
            autoReconnect: autoReconnect
        )
        if let problem = validate(server) {
            printError(problem)
            return 2
        }

        var servers = ConfigManager.shared.config.servers
        if name != old.name, servers.contains(where: { $0.id != old.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            printError("a server named \"\(name)\" already exists")
            return 2
        }

        if let code = storePassword(options, serverID: server.id, required: false) {
            return code
        }

        guard let index = servers.firstIndex(where: { $0.id == old.id }) else { return 1 }
        servers[index] = server
        ConfigManager.shared.saveServers(servers)
        configChanged()
        print("Updated \(server.name)")

        // Auto-connect, auto-reconnect, name and icon apply right away; the rest is openfortivpn input
        let connectionChanged = server.host != old.host || server.port != old.port
            || server.username != old.username || server.trustedCert != old.trustedCert
            || server.noRoutesDNS != old.noRoutesDNS || server.staticRoutes != old.staticRoutes
            || options.has("--password") || options.has("--password-stdin")
        if connectionChanged, runningState()?.tunnels.contains(where: { $0.id == server.id }) == true {
            print("Note: \(server.name) is connected; connection changes apply on the next connect")
        }
        warnIfRoutesNeedPermission(server)
        return 0
    }

    // MARK: - remove

    static func remove(_ args: [String]) -> Int32 {
        guard let options = parseOptions(args) else { return 2 }
        guard let query = options.positional.first else {
            return usage("remove needs a server: openfortimac remove <server> [--yes]")
        }
        guard let server = resolve(query) else { return 2 }

        if !(options.has("--yes") || options.has("-y")) {
            guard isatty(STDIN_FILENO) != 0 else {
                printError("pass --yes to remove \"\(server.name)\" non-interactively")
                return 2
            }
            print("Remove \"\(server.name)\" and its saved password? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
                print("Cancelled")
                return 1
            }
        }

        if runningState()?.tunnels.contains(where: { $0.id == server.id }) == true {
            _ = disconnect(server.id, wait: true)
        }

        let servers = ConfigManager.shared.config.servers.filter { $0.id != server.id }
        KeychainHelper.delete(for: server.id)
        ConfigManager.shared.saveServers(servers)
        configChanged()
        print("Removed \(server.name)")
        return 0
    }

    // MARK: - show

    static func show(_ args: [String], json: Bool) -> Int32 {
        guard let query = args.first else { return usage("show needs a server") }
        guard let server = resolve(query) else { return 2 }
        let tunnel = runningState()?.tunnels.first { $0.id == server.id }
        let hasPassword = !(KeychainHelper.read(for: server.id)?.isEmpty ?? true)

        if json {
            var item: [String: Any] = [
                "id": server.id, "name": server.name, "host": server.host, "port": server.port,
                "username": server.username, "icon": server.iconName,
                "no_routes_dns": server.noRoutesDNS, "static_routes": server.staticRoutes,
                "auto_connect": server.autoConnect, "auto_reconnect": server.autoReconnect,
                "has_password": hasPassword,
                "state": tunnel?.state ?? "disconnected"
            ]
            item["trusted_cert"] = server.trustedCert
            item["interface"] = tunnel?.interface
            item["ip"] = tunnel?.ip
            return printJSON(item)
        }

        let rows: [(String, String)] = [
            ("Name", server.name),
            ("ID", server.id),
            ("Gateway", "\(server.host):\(server.port)"),
            ("User", server.username),
            ("Password", hasPassword ? "saved in Keychain" : "not set"),
            ("Certificate", server.trustedCert ?? "any (not pinned)"),
            ("Routes/DNS", server.noRoutesDNS ? "left untouched (--no-routes --no-dns)" : "managed by openfortivpn"),
            ("Static routes", server.staticRoutes.isEmpty ? "-" : server.staticRoutes.joined(separator: ", ")),
            ("Auto-connect", server.autoConnect ? "yes" : "no"),
            ("Reconnect", server.autoReconnect ? "automatically" : "no"),
            ("State", tunnel.map { [$0.state, $0.ip, $0.interface].compactMap { $0 }.joined(separator: ", ") } ?? "disconnected")
        ]
        for (label, value) in rows {
            print(pad(label + ":", 15) + value)
        }
        return 0
    }

    // MARK: - settings

    static func settings(_ args: [String], json: Bool) -> Int32 {
        guard let options = parseOptions(args) else { return 2 }
        var changed = false

        if let value = options.value("--allow-multiple") {
            guard let enabled = parseBool(value) else { return usage("--allow-multiple takes on or off") }
            ConfigManager.shared.saveAllowMultipleConnections(enabled)
            changed = true
        }
        if let value = options.value("--menu-bar-icon") {
            guard let style = MenuBarIconStyle(rawValue: value.lowercased()) else {
                return usage("--menu-bar-icon takes classic or monochrome")
            }
            ConfigManager.shared.saveMenuBarIconStyle(style)
            changed = true
        }
        if let path = options.value("--openfortivpn-path") {
            guard FileManager.default.isExecutableFile(atPath: path) else {
                printError("not an executable: \(path)")
                return 2
            }
            ConfigManager.shared.saveOpenfortivpnPath(path)
            changed = true
        }
        if changed { configChanged() }

        let config = ConfigManager.shared.config
        if json {
            return printJSON([
                "allow_multiple_connections": config.allowMultipleConnections,
                "menu_bar_icon": config.menuBarIconStyle.rawValue,
                "openfortivpn_path": config.openfortivpnPath,
                "config_file": ConfigManager.configPath.path
            ] as [String: Any])
        }
        print(pad("Allow multiple connections:", 29) + (config.allowMultipleConnections ? "on" : "off"))
        print(pad("Menu bar icon:", 29) + config.menuBarIconStyle.rawValue)
        print(pad("openfortivpn:", 29) + config.openfortivpnPath)
        print(pad("Config file:", 29) + ConfigManager.configPath.path)
        return 0
    }

    // MARK: - permission

    static func permission(_ args: [String]) -> Int32 {
        let path = VPNManager.locateOpenfortivpn()
        if args.first == "install" || args.first == "update" {
            guard let path = path else {
                printError("openfortivpn not found")
                return 1
            }
            do {
                // Shows the macOS administrator password dialog
                try SudoersManager.shared.install(binaryPath: path)
            } catch {
                printError(error.localizedDescription)
                return 1
            }
        }

        let status = SudoersManager.shared.status(for: path)
        let text: String
        switch status {
        case .managed: text = "ok (\(SudoersManager.rulePath))"
        case .external: text = "ok (a rule not managed by OpenFortiMac)"
        case .routesMissing: text = "static routes not allowed: run openfortimac permission update"
        case .outdated: text = "rule points to another openfortivpn: run openfortimac permission update"
        case .missing: text = "not set up: run openfortimac permission install"
        case .binaryNotFound: text = "openfortivpn not found"
        }
        print("Permission: \(text)")
        return [.managed, .external].contains(status) ? 0 : 1
    }

    // MARK: - Helpers

    static func validate(_ server: VPNServer) -> String? {
        if server.name.isEmpty { return "name cannot be empty" }
        if server.host.isEmpty || server.host.contains(where: \.isWhitespace) { return "host cannot be empty or contain spaces" }
        if !(1...65535).contains(server.port) { return "port must be a number between 1 and 65535" }
        if server.username.trimmingCharacters(in: .whitespaces).isEmpty { return "user cannot be empty" }
        if let bad = server.staticRoutes.first(where: { !VPNServer.isValidCIDR($0) }) {
            return "invalid route \"\(bad)\": use CIDR notation like 10.20.30.0/24"
        }
        if let icon = server.icon, !VPNServer.iconChoices.contains(icon) {
            return "unknown icon \"\(icon)\": choose one of " + VPNServer.iconChoices.joined(separator: ", ")
        }
        return nil
    }

    /// `--password` prompts without echo, `--password-stdin` reads one line from stdin.
    /// Returns an exit code on failure, nil when done or not requested.
    static func storePassword(_ options: Options, serverID: String, required: Bool) -> Int32? {
        var password: String?
        if options.has("--password-stdin") {
            password = readLine(strippingNewline: true)
        } else if options.has("--password") {
            var buffer = [CChar](repeating: 0, count: 1024)
            guard let raw = readpassphrase("Password: ", &buffer, buffer.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) else {
                printError("could not read the password (no terminal? use --password-stdin)")
                return 1
            }
            password = String(cString: raw)
        } else if !required {
            return nil
        }

        guard let value = password, !value.isEmpty else {
            printError("empty password")
            return 2
        }
        guard KeychainHelper.save(password: value, for: serverID) else {
            printError("could not save the password to the Keychain")
            return 1
        }
        return nil
    }

    static func warnIfRoutesNeedPermission(_ server: VPNServer) {
        guard !server.validatedStaticRoutes.isEmpty, !SudoersManager.shared.routesAllowed() else { return }
        print("Note: static routes need an updated sudo rule: openfortimac permission update")
    }

    /// Tells a running app to re-read config.json, so it does not overwrite these changes.
    static func configChanged() {
        guard runningState() != nil else { return }
        send(.reloadConfig, server: nil)
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "on", "yes", "true", "1": return true
        case "off", "no", "false", "0": return false
        default: return nil
        }
    }
}
