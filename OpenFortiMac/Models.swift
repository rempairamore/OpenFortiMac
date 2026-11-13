import Foundation

/// Menu bar icon look, chosen in Settings › General.
enum MenuBarIconStyle: String, Codable, CaseIterable {
    /// Lock icons, green when connected (the original look)
    case classic
    /// Template shield that follows the menu bar appearance and shows the tunnel count
    case monochrome
}

struct AppConfig: Codable {
    var servers: [VPNServer]
    var openfortivpnPath: String
    /// Off by default: connecting to a server first drops the current tunnel,
    /// as in earlier versions. On: every server runs its own tunnel side by side.
    var allowMultipleConnections: Bool
    var menuBarIconStyle: MenuBarIconStyle

    static let defaultOpenfortivpnPath = "/opt/homebrew/bin/openfortivpn"

    static let `default` = AppConfig(
        servers: [],
        openfortivpnPath: defaultOpenfortivpnPath
    )

    enum CodingKeys: String, CodingKey {
        case servers
        case openfortivpnPath = "openfortivpn_path"
        case allowMultipleConnections = "allow_multiple_connections"
        case menuBarIconStyle = "menu_bar_icon"
    }

    init(
        servers: [VPNServer],
        openfortivpnPath: String,
        allowMultipleConnections: Bool = false,
        menuBarIconStyle: MenuBarIconStyle = .classic
    ) {
        self.servers = servers
        self.openfortivpnPath = openfortivpnPath
        self.allowMultipleConnections = allowMultipleConnections
        self.menuBarIconStyle = menuBarIconStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = try container.decodeIfPresent([VPNServer].self, forKey: .servers) ?? []
        openfortivpnPath = try container.decodeIfPresent(String.self, forKey: .openfortivpnPath) ?? Self.defaultOpenfortivpnPath
        allowMultipleConnections = try container.decodeIfPresent(Bool.self, forKey: .allowMultipleConnections) ?? false
        // Unknown values (e.g. from a newer version) fall back to the default look
        let style = try container.decodeIfPresent(String.self, forKey: .menuBarIconStyle)
        menuBarIconStyle = style.flatMap(MenuBarIconStyle.init(rawValue:)) ?? .classic
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(servers, forKey: .servers)
        try container.encode(openfortivpnPath, forKey: .openfortivpnPath)
        // Written only when enabled, so existing config files stay unchanged
        if allowMultipleConnections {
            try container.encode(true, forKey: .allowMultipleConnections)
        }
        if menuBarIconStyle != .classic {
            try container.encode(menuBarIconStyle, forKey: .menuBarIconStyle)
        }
    }

    /// True when at least one server installs static routes (needs the extra sudo rule).
    var needsRoutePermission: Bool {
        servers.contains { !$0.validatedStaticRoutes.isEmpty }
    }
}

struct VPNServer: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let username: String
    let password: String?
    let trustedCert: String?
    /// SF Symbol shown next to the server name
    let icon: String?
    /// Pass --no-routes --no-dns: the tunnel leaves the routing table and the resolver alone,
    /// e.g. a secondary tunnel next to a primary one that owns the default routes.
    let noRoutesDNS: Bool
    /// Static routes (CIDR) installed through this tunnel's ppp interface
    /// when it comes up, and removed when it goes down.
    let staticRoutes: [String]
    /// Connect automatically when OpenFortiMac starts.
    let autoConnect: Bool
    /// Reconnect when the tunnel drops (network change, gateway timeout, sleep)
    /// until the user disconnects.
    let autoReconnect: Bool

    static let defaultIcon = "server.rack"
    static let iconChoices = ["server.rack", "building.2", "briefcase", "house", "cloud", "lock.shield", "network", "desktopcomputer"]

    var iconName: String { icon ?? Self.defaultIcon }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, password, icon
        case trustedCert = "trusted_cert"
        case noRoutesDNS = "no_routes_dns"
        case staticRoutes = "static_routes"
        case autoConnect = "auto_connect"
        case autoReconnect = "auto_reconnect"
    }

    init(
        name: String,
        host: String,
        port: Int,
        username: String,
        password: String?,
        trustedCert: String?,
        icon: String? = nil,
        id: String? = nil,
        noRoutesDNS: Bool = false,
        staticRoutes: [String] = [],
        autoConnect: Bool = false,
        autoReconnect: Bool = false
    ) {
        self.id = id ?? UUID().uuidString
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.trustedCert = trustedCert
        self.icon = icon
        self.noRoutesDNS = noRoutesDNS
        self.staticRoutes = staticRoutes
        self.autoConnect = autoConnect
        self.autoReconnect = autoReconnect
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 443
        username = try container.decode(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        trustedCert = try container.decodeIfPresent(String.self, forKey: .trustedCert)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        noRoutesDNS = try container.decodeIfPresent(Bool.self, forKey: .noRoutesDNS) ?? false
        staticRoutes = try container.decodeIfPresent([String].self, forKey: .staticRoutes) ?? []
        autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? false
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encodeIfPresent(trustedCert, forKey: .trustedCert)
        try container.encodeIfPresent(icon, forKey: .icon)
        // Optional features are written only when used, so plain profiles look as before
        if noRoutesDNS {
            try container.encode(true, forKey: .noRoutesDNS)
        }
        if !staticRoutes.isEmpty {
            try container.encode(staticRoutes, forKey: .staticRoutes)
        }
        if autoConnect {
            try container.encode(true, forKey: .autoConnect)
        }
        if autoReconnect {
            try container.encode(true, forKey: .autoReconnect)
        }
    }

    /// Routes that passed the CIDR check: only these are ever handed to /sbin/route.
    var validatedStaticRoutes: [String] {
        staticRoutes.filter { Self.isValidCIDR($0) }
    }

    /// Strict IPv4 CIDR check: a.b.c.d/n with plain decimal parts.
    static func isValidCIDR(_ value: String) -> Bool {
        guard value.range(of: #"^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$"#, options: .regularExpression) != nil else {
            return false
        }
        let parts = value.split(separator: "/")
        guard let prefix = Int(parts[1]), (0...32).contains(prefix) else { return false }
        return parts[0].split(separator: ".").allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: VPNServer, rhs: VPNServer) -> Bool {
        lhs.id == rhs.id
    }
}
