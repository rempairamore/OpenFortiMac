import Foundation
import CryptoKit

/// What went wrong while reading config.json. Shown to the user: the app never starts
/// with an empty list in silence, and the original file is kept as a copy.
enum ConfigIssue: Equatable {
    /// The file is not valid, so the app started with an empty list
    case unreadable(backup: String?)
    /// Some servers are incomplete and were left out
    case skippedServers(count: Int, backup: String?)

    var backup: String? {
        switch self {
        case .unreadable(let backup), .skippedServers(_, let backup): return backup
        }
    }
}

class ConfigManager {
    static let shared = ConfigManager()

    private(set) var config: AppConfig
    private(set) var loadIssue: ConfigIssue?

    static var configPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("OpenFortiMac")
        return appFolder.appendingPathComponent("config.json")
    }

    private init() {
        (config, loadIssue) = Self.loadConfig(from: Self.configPath)
        migrateLegacyPasswords()
        // Ids made up while reading must reach the file: the next launch would make
        // different ones, and the passwords saved under these would be lost
        if config.assignedIDs {
            saveConfig(config)
        }
    }

    private static func loadConfig(from path: URL) -> (AppConfig, ConfigIssue?) {
        let directory = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: path.path) else {
            return (.default, nil)
        }
        guard let data = try? Data(contentsOf: path) else {
            return (.default, .unreadable(backup: nil))
        }
        // An empty file is a first launch, not a broken configuration
        guard !data.isEmpty else {
            return (.default, nil)
        }

        do {
            // No keyDecodingStrategy — we use explicit CodingKeys in Models
            let config = try JSONDecoder().decode(AppConfig.self, from: data)
            if config.skippedServers > 0 {
                return (config, .skippedServers(count: config.skippedServers, backup: keepCopy(of: data, nextTo: path)))
            }
            return (config, nil)
        } catch {
            print("Error loading config: \(error)")
            return (.default, .unreadable(backup: keepCopy(of: data, nextTo: path)))
        }
    }

    /// Saves the original bytes next to config.json before the app can overwrite them.
    /// The name comes from the content, so the same broken file is copied only once.
    private static func keepCopy(of data: Data, nextTo path: URL) -> String? {
        let digest = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        let name = "config.backup-\(digest).json"
        let destination = path.deletingLastPathComponent().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            return name
        }
        do {
            try data.write(to: destination, options: .atomic)
            return name
        } catch {
            print("Could not keep a copy of config.json: \(error)")
            return nil
        }
    }

    /// Old files could carry a "password" key that the app never used. Move it to the
    /// Keychain and rewrite the file without it.
    private func migrateLegacyPasswords() {
        let legacy = config.servers.filter { !($0.legacyPassword ?? "").isEmpty }
        guard !legacy.isEmpty else { return }

        for server in legacy where !KeychainHelper.exists(for: server.id) {
            guard let password = server.legacyPassword, KeychainHelper.save(password: password, for: server.id) else {
                // Keep the file as it is and try again at the next launch
                return
            }
        }
        saveConfig(config)
    }

    @discardableResult
    func saveConfig(_ newConfig: AppConfig) -> Bool {
        let path = ConfigManager.configPath
        let directory = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let encoder = JSONEncoder()
            // No keyEncodingStrategy — we use explicit CodingKeys in Models
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(newConfig)
            // Atomic: a crash while writing never leaves half a file
            try data.write(to: path, options: .atomic)
            self.config = newConfig
            return true
        } catch {
            print("Error saving config: \(error)")
            return false
        }
    }

    func saveServers(_ servers: [VPNServer]) {
        let newConfig = AppConfig(
            servers: servers,
            openfortivpnPath: config.openfortivpnPath
        )
        saveConfig(newConfig)
    }

    func saveOpenfortivpnPath(_ path: String) {
        guard path != config.openfortivpnPath else { return }
        let newConfig = AppConfig(
            servers: config.servers,
            openfortivpnPath: path
        )
        saveConfig(newConfig)
    }

    func createDefaultConfig() {
        let path = ConfigManager.configPath
        let directory = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard !FileManager.default.fileExists(atPath: path.path) else { return }

        saveConfig(AppConfig.default)
    }
}
