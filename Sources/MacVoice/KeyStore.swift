// Adapted from savka777/jev-use KeyStore.swift, MIT, b22e568.
import Foundation
import Security
import VoiceCore

enum KeyStore {
    private static var query: [String: Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.macvoicecontrol.app",
         kSecAttrAccount as String:"typesafe-api-key"]
    }
    static func read() throws -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data:data,encoding:.utf8) else { throw failure(status) }
        return key
    }
    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.isEmpty else { throw VoiceError("Enter a TypeSafe API key.") }
        let attributes = [kSecValueData as String:Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary,attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item.merge(attributes) { _,new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary,nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> VoiceError {
        VoiceError("Keychain: \(SecCopyErrorMessageString(status,nil) as String? ?? "access failed")")
    }
}
