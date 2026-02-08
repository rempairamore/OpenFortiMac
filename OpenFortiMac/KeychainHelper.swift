import Foundation
import Security

struct KeychainHelper {
    
    private static let service = "com.openfortimac.vpn"
    
    /// Save or update a password in the Keychain
    static func save(password: String, for serverID: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        
        // Try to update first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID
        ]
        
        let update: [String: Any] = [
            kSecValueData as String: data
        ]
        
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        
        if updateStatus == errSecSuccess {
            return true
        }
        
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        
        print("Keychain save error: \(updateStatus)")
        return false
    }
    
    /// Read a password from the Keychain
    static func read(for serverID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        
        return String(data: data, encoding: .utf8)
    }
    
    /// Delete a password from the Keychain
    static func delete(for serverID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}
