import Foundation

/// Builds the configuration file handed to openfortivpn with `-c <file>`.
enum OpenfortivpnConfig {
    enum BuildError: LocalizedError {
        case lineBreak(field: String)

        var errorDescription: String? {
            switch self {
            case .lineBreak(let field):
                return "\(field) contains a line break. Edit the server in Settings."
            }
        }
    }

    static func make(server: VPNServer, password: String) throws -> String {
        // (config key, field name shown to the user, value)
        var entries: [(key: String, field: String, value: String)] = [
            ("host", "Host", server.host),
            ("port", "Port", String(server.port)),
            ("username", "Username", server.username),
            ("password", "Password", password),
        ]
        if let trustedCert = server.trustedCert, !trustedCert.isEmpty {
            entries.append(("trusted-cert", "Certificate", trustedCert))
        }
        if let realm = server.realm, !realm.isEmpty {
            entries.append(("realm", "Realm", realm))
        }

        // Each value must stay on its own "key = value" line: a line break would add other options
        if let entry = entries.first(where: { $0.value.contains(where: \.isNewline) }) {
            throw BuildError.lineBreak(field: entry.field)
        }

        return entries.map { "\($0.key) = \($0.value)" }.joined(separator: "\n") + "\n"
    }
}
