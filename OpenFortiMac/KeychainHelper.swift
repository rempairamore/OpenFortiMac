import Foundation
import Security

/// Server passwords in the macOS Keychain, all of them in ONE item.
///
/// For an app without an Apple team, macOS ties the permission to read a Keychain item to
/// the exact build (the item's "partition list" holds the build's cdhash). So after every
/// update it asks again, once per item: with a single item it asks once.
///
/// Versions up to 1.4.1 kept one item per server. Each of those is moved into the single
/// item the first time its server is used.
struct KeychainHelper {
    #if DEBUG
    /// Tests point these somewhere else, away from the real items
    static var legacyService = "com.openfortimac.vpn"
    static var vaultService = "com.openfortimac.vpn.passwords"
    #else
    private static let legacyService = "com.openfortimac.vpn"
    private static let vaultService = "com.openfortimac.vpn.passwords"
    #endif
    private static let vaultAccount = "servers"
    /// The name macOS shows in its permission dialog and in Keychain Access
    private static let vaultLabel = "OpenFortiMac passwords"

    // MARK: - Public

    /// Save or replace the password of a server.
    static func save(password: String, for serverID: String) -> Bool {
        switch readVault() {
        case .unavailable:
            // The other passwords could not be read: writing now would lose them
            return false
        case .missing:
            guard writeVault([serverID: password], alreadyThere: false) else { return false }
        case .passwords(var all):
            all[serverID] = password
            guard writeVault(all, alreadyThere: true) else { return false }
        }
        deleteLegacy(for: serverID)
        return true
    }

    /// Whether a password is saved, without reading it: the list of server ids is kept in
    /// an attribute of the item, which macOS hands out without asking for access.
    static func exists(for serverID: String) -> Bool {
        vaultIDs().contains(serverID) || legacyExists(for: serverID)
    }

    /// Read the password of a server. This is the call that can make macOS ask for access.
    static func read(for serverID: String) -> String? {
        let vault = readVault()
        if case .passwords(let all) = vault, let password = all[serverID] {
            return password
        }

        // Saved by 1.4.1 or earlier: move it to the single item
        guard let password = readLegacy(for: serverID) else { return nil }
        var moved = false
        switch vault {
        case .passwords(var all):
            all[serverID] = password
            moved = writeVault(all, alreadyThere: true)
        case .missing:
            moved = writeVault([serverID: password], alreadyThere: false)
        case .unavailable:
            // Keep the old item: it is the only copy that can be read
            break
        }
        if moved {
            deleteLegacy(for: serverID)
        }
        return password
    }

    /// Forget the password of a server.
    static func delete(for serverID: String) {
        deleteLegacy(for: serverID)
        guard vaultIDs().contains(serverID), case .passwords(var all) = readVault() else { return }
        all.removeValue(forKey: serverID)
        _ = writeVault(all, alreadyThere: true)
    }

    // MARK: - The single item

    private enum Vault {
        case passwords([String: String])
        /// Nothing saved yet
        case missing
        /// It is there but cannot be read now (access refused, Keychain locked)
        case unavailable
    }

    private static var vaultQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: vaultAccount
        ]
    }

    private static func readVault() -> Vault {
        var query = vaultQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .missing
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let passwords = try? JSONDecoder().decode([String: String].self, from: data) else {
            return .unavailable
        }
        return .passwords(passwords)
    }

    /// Server ids that have a password, from the item's attributes: no secret is read.
    private static func vaultIDs() -> Set<String> {
        var query = vaultQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              let data = attributes[kSecAttrGeneric as String] as? Data,
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    /// Updates the item in place when it exists, so the permissions macOS has recorded
    /// for it are kept.
    private static func writeVault(_ passwords: [String: String], alreadyThere: Bool) -> Bool {
        guard let data = try? JSONEncoder().encode(passwords),
              let ids = try? JSONEncoder().encode(passwords.keys.sorted()) else { return false }

        let content: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrGeneric as String: ids
        ]

        let status: OSStatus
        if alreadyThere {
            status = SecItemUpdate(vaultQuery as CFDictionary, content as CFDictionary)
        } else {
            var item = vaultQuery
            item.merge(content) { _, new in new }
            item[kSecAttrLabel as String] = vaultLabel
            status = SecItemAdd(item as CFDictionary, nil)
        }

        if status != errSecSuccess {
            print("Keychain save error: \(status)")
        }
        return status == errSecSuccess
    }

    // MARK: - One item per server (1.4.1 and earlier)

    private static func legacyQuery(for serverID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: serverID
        ]
    }

    private static func legacyExists(for serverID: String) -> Bool {
        var query = legacyQuery(for: serverID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func readLegacy(for serverID: String) -> String? {
        var query = legacyQuery(for: serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteLegacy(for serverID: String) {
        SecItemDelete(legacyQuery(for: serverID) as CFDictionary)
    }
}
