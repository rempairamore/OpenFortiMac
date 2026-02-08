import Foundation

struct AppConfig: Codable {
    var servers: [VPNServer]
    var openfortivpnPath: String
    
    static let `default` = AppConfig(
        servers: [],
        openfortivpnPath: "/opt/homebrew/bin/openfortivpn"
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
        servers = try container.decodeIfPresent([VPNServer].self, forKey: .servers) ?? []
        openfortivpnPath = try container.decodeIfPresent(String.self, forKey: .openfortivpnPath) ?? "/opt/homebrew/bin/openfortivpn"
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
    
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, password
        case trustedCert = "trusted_cert"
    }
    
    init(name: String, host: String, port: Int, username: String, password: String?, trustedCert: String?, id: String? = nil) {
        self.id = id ?? UUID().uuidString
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.trustedCert = trustedCert
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
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: VPNServer, rhs: VPNServer) -> Bool {
        lhs.id == rhs.id
    }
}
