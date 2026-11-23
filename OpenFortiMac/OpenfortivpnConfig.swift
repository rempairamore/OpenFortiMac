import Foundation

/// Builds the configuration file handed to openfortivpn with `-c <file>`.
enum OpenfortivpnConfig {
    /// Local port where openfortivpn waits for the browser after a single sign-on
    static let samlPort = 8020

    enum BuildError: LocalizedError {
        case lineBreak(field: String)

        var errorDescription: String? {
            switch self {
            case .lineBreak(let field):
                return String(localized: "\(field) contains a line break. Edit the server in Settings.")
            }
        }
    }

    /// `password` is nil for single sign-on, where the browser does the login.
    static func make(server: VPNServer, password: String?) throws -> String {
        // (config key, field name shown to the user, value)
        var entries: [(key: String, field: String, value: String)] = [
            ("host", String(localized: "Host"), server.host),
            ("port", String(localized: "Port"), String(server.port)),
        ]
        if server.singleSignOn {
            entries.append(("saml-login", String(localized: "Single sign-on"), String(samlPort)))
        } else {
            entries.append(("username", String(localized: "Username"), server.username))
            entries.append(("password", String(localized: "Password"), password ?? ""))
        }
        if let trustedCert = server.trustedCert, !trustedCert.isEmpty {
            entries.append(("trusted-cert", String(localized: "Certificate"), trustedCert))
        }
        if let realm = server.realm, !realm.isEmpty {
            entries.append(("realm", String(localized: "Realm"), realm))
        }
        if let minTLS = server.minTLS, VPNServer.tlsChoices.contains(minTLS) {
            entries.append(("min-tls", String(localized: "Minimum TLS"), minTLS))
        }
        if server.alwaysAskCode {
            entries.append(("no-ftm-push", String(localized: "One-time code"), "1"))
        }

        // Each value must stay on its own "key = value" line: a line break would add other options
        if let entry = entries.first(where: { $0.value.contains(where: \.isNewline) }) {
            throw BuildError.lineBreak(field: entry.field)
        }

        return entries.map { "\($0.key) = \($0.value)" }.joined(separator: "\n") + "\n"
    }
}
