import Foundation

struct AppConfig: Codable {
    var servers: [VPNServer]
    var openfortivpnPath: String
    /// Server entries of the file that could not be read; they are not written back
    var skippedServers = 0
    /// Some servers had no "id" of their own in the file and were given one
    var assignedIDs = false

    static let defaultOpenfortivpnPath = "/opt/homebrew/bin/openfortivpn"

    static let `default` = AppConfig(
        servers: [],
        openfortivpnPath: defaultOpenfortivpnPath
    )

    enum CodingKeys: String, CodingKey {
        case servers
        case openfortivpnPath = "openfortivpn_path"
    }

    init(servers: [VPNServer], openfortivpnPath: String) {
        self.servers = servers
        self.openfortivpnPath = openfortivpnPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One incomplete server must not hide the others
        let entries = try container.decodeIfPresent([LenientServer].self, forKey: .servers) ?? []
        skippedServers = entries.filter { $0.server == nil }.count

        // The id ties a server to its Keychain password: every server needs one, all different.
        // A block copied by hand keeps the id of the original, so the copy gets a new one.
        var seen = Set<String>()
        var readable: [VPNServer] = []
        for entry in entries {
            guard var server = entry.server else { continue }
            if !entry.hasID {
                assignedIDs = true
            }
            if !seen.insert(server.id).inserted {
                server = server.copy(named: server.name)
                seen.insert(server.id)
                assignedIDs = true
            }
            readable.append(server)
        }
        servers = readable
        openfortivpnPath = try container.decodeIfPresent(String.self, forKey: .openfortivpnPath) ?? Self.defaultOpenfortivpnPath
    }
}

/// Decodes one server entry, or nil when the entry is incomplete.
private struct LenientServer: Decodable {
    let server: VPNServer?
    /// False when VPNServer had to make up the id
    let hasID: Bool

    private enum IDKey: String, CodingKey {
        case id
    }

    init(from decoder: Decoder) throws {
        server = try? VPNServer(from: decoder)
        let container = try? decoder.container(keyedBy: IDKey.self)
        hasID = ((try? container?.decode(String.self, forKey: .id)) ?? "").isEmpty == false
    }
}

struct VPNServer: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let username: String
    let trustedCert: String?
    /// Authentication realm (openfortivpn `realm`), only for gateways that use one
    let realm: String?
    /// SF Symbol shown next to the server name
    let icon: String?
    /// Lowest TLS version to accept ("1.0" to "1.3"); nil keeps openfortivpn's default
    let minTLS: String?
    /// Always type the one-time code, even when the gateway offers approval on the phone
    let alwaysAskCode: Bool
    /// Sign in with the browser (SAML): no username or password
    let singleSignOn: Bool
    /// Password found in an old config.json: moved to the Keychain at load, never written back
    let legacyPassword: String?

    static let defaultIcon = "server.rack"
    static let iconChoices = ["server.rack", "building.2", "briefcase", "house", "cloud", "lock.shield", "network", "desktopcomputer"]
    static let tlsChoices = ["1.0", "1.1", "1.2", "1.3"]

    var iconName: String { icon ?? Self.defaultIcon }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, password, realm, icon
        case trustedCert = "trusted_cert"
        case minTLS = "min_tls"
        case oneTimeCode = "one_time_code"
        case singleSignOn = "single_sign_on"
    }

    init(name: String, host: String, port: Int, username: String, trustedCert: String?,
         realm: String? = nil, icon: String? = nil, minTLS: String? = nil,
         alwaysAskCode: Bool = false, singleSignOn: Bool = false, id: String? = nil) {
        self.id = id ?? UUID().uuidString
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.trustedCert = trustedCert
        self.realm = realm
        self.icon = icon
        self.minTLS = minTLS
        self.alwaysAskCode = alwaysAskCode
        self.singleSignOn = singleSignOn
        self.legacyPassword = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Missing, or not text: a new one is made and AppConfig has the file saved with it
        let givenID = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        id = givenID.isEmpty ? UUID().uuidString : givenID
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)

        // Hand-edited files often have the port in quotes
        if let number = try? container.decodeIfPresent(Int.self, forKey: .port) {
            port = number
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .port), let number = Int(text) {
            port = number
        } else if container.contains(.port) {
            throw DecodingError.dataCorruptedError(forKey: .port, in: container, debugDescription: "Port is not a number")
        } else {
            port = 443
        }

        singleSignOn = (try? container.decodeIfPresent(Bool.self, forKey: .singleSignOn)) ?? false
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        if username.isEmpty && !singleSignOn {
            throw DecodingError.dataCorruptedError(forKey: .username, in: container, debugDescription: "Username is missing")
        }

        legacyPassword = try? container.decodeIfPresent(String.self, forKey: .password)
        trustedCert = try container.decodeIfPresent(String.self, forKey: .trustedCert)
        realm = try container.decodeIfPresent(String.self, forKey: .realm)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        let tls = try? container.decodeIfPresent(String.self, forKey: .minTLS)
        minTLS = tls.flatMap { Self.tlsChoices.contains($0) ? $0 : nil }
        alwaysAskCode = (try? container.decodeIfPresent(String.self, forKey: .oneTimeCode)) == "ask"
    }

    /// Passwords are never written: they live in the Keychain. Options are written only when set.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(trustedCert, forKey: .trustedCert)
        try container.encodeIfPresent(realm, forKey: .realm)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(minTLS, forKey: .minTLS)
        if alwaysAskCode {
            try container.encode("ask", forKey: .oneTimeCode)
        }
        if singleSignOn {
            try container.encode(true, forKey: .singleSignOn)
        }
    }

    /// Same server with another pinned certificate digest.
    func trusting(_ digest: String) -> VPNServer {
        VPNServer(name: name, host: host, port: port, username: username, trustedCert: digest,
                  realm: realm, icon: icon, minTLS: minTLS, alwaysAskCode: alwaysAskCode,
                  singleSignOn: singleSignOn, id: id)
    }

    /// A copy with its own identity, e.g. for "Duplicate" or an imported file.
    func copy(named newName: String? = nil) -> VPNServer {
        VPNServer(name: newName ?? name, host: host, port: port, username: username, trustedCert: trustedCert,
                  realm: realm, icon: icon, minTLS: minTLS, alwaysAskCode: alwaysAskCode,
                  singleSignOn: singleSignOn, id: nil)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: VPNServer, rhs: VPNServer) -> Bool {
        lhs.id == rhs.id
    }
}
