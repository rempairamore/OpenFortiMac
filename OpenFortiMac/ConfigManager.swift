import Foundation

class ConfigManager {
    static let shared = ConfigManager()
    
    private(set) var config: AppConfig
    
    static var configPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("OpenFortiMac")
        return appFolder.appendingPathComponent("config.json")
    }
    
    private init() {
        config = ConfigManager.loadConfig(from: ConfigManager.configPath)
    }
    
    func reload() {
        config = ConfigManager.loadConfig(from: ConfigManager.configPath)
    }
    
    private static func loadConfig(from path: URL) -> AppConfig {
        let directory = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        guard FileManager.default.fileExists(atPath: path.path) else {
            print("Config file not found at \(path.path), using defaults")
            return AppConfig.default
        }
        
        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            // No keyDecodingStrategy — we use explicit CodingKeys in Models
            let config = try decoder.decode(AppConfig.self, from: data)
            print("Config loaded from \(path.path)")
            return config
        } catch {
            print("Error loading config: \(error)")
            return AppConfig.default
        }
    }
    
    func saveConfig(_ newConfig: AppConfig) {
        let path = ConfigManager.configPath
        let directory = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        do {
            let encoder = JSONEncoder()
            // No keyEncodingStrategy — we use explicit CodingKeys in Models
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(newConfig)
            try data.write(to: path)
            self.config = newConfig
            print("Config saved to \(path.path)")
        } catch {
            print("Error saving config: \(error)")
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
