import Foundation
import Security
import VoiceCore

enum OpenAIAPIKeyStore {
    private static var query: [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.macvoicecontrol.openai-api",
         kSecAttrAccount as String:"api-key"]
    }
    static func read() throws -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data:data,encoding:.utf8) else {
            throw VoiceError("Could not read the OpenAI API key from Keychain.")
        }
        return key
    }
    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where:{$0.isWhitespace}) else { throw VoiceError("Enter a valid OpenAI API key.") }
        let values = [kSecValueData as String:Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary,values as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q.merge(values) { _,new in new }
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw VoiceError("Could not save the OpenAI API key.") }
        } else if status != errSecSuccess { throw VoiceError("Could not update the OpenAI API key.") }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VoiceError("Could not remove the OpenAI API key.") }
    }
}
