import AppKit
import CryptoKit
import Network
import Security
import VoiceCore

struct ChatGPTCredentials: Codable, Sendable {
    var clientID: String
    var subject: String
    var email: String?
    var accessToken: String
    var refreshToken: String?
    var idToken: String
    var expiresAt: Date
    var scopes: [String]
    var sharing: Bool { scopes.contains("chatgpt.tokens.use.direct") && scopes.contains("resource.invoke") }
}

enum ChatGPTKeychain {
    private static var query: [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.macvoicecontrol.chatgpt",
         kSecAttrAccount as String:"connection"]
    }
    static func read() throws -> ChatGPTCredentials? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VoiceError("Could not read ChatGPT credentials from Keychain.") }
        return try JSONDecoder().decode(ChatGPTCredentials.self,from:data)
    }
    static func save(_ credentials: ChatGPTCredentials) throws {
        let values = [kSecValueData as String:try JSONEncoder().encode(credentials)]
        let status = SecItemUpdate(query as CFDictionary,values as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q.merge(values) { _,new in new }
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw VoiceError("Could not save ChatGPT credentials in Keychain.") }
        } else if status != errSecSuccess { throw VoiceError("Could not update ChatGPT credentials in Keychain.") }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VoiceError("Could not clear ChatGPT credentials from Keychain.") }
    }
}

enum OpenAIIdentity {
    static func decodeURL(_ string: String) throws -> Data {
        var value = string.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        value += String(repeating:"=",count:(4-value.count%4)%4)
        guard let data = Data(base64Encoded:value) else { throw VoiceError("Invalid identity encoding.") }; return data
    }
    static func verify(_ token: String, clientID: String, nonce: String?, subject: String? = nil,
                       session: URLSession) async throws -> (subject: String, email: String?) {
        let parts = token.split(separator:".",omittingEmptySubsequences:false).map(String.init)
        guard parts.count == 3, token.count < 32_000,
              let header = try JSONSerialization.jsonObject(with:decodeURL(parts[0])) as? [String:Any],
              let kid = header["kid"] as? String, let alg = header["alg"] as? String,
              ["RS256","ES256"].contains(alg) else { throw VoiceError("Unsupported ChatGPT identity signature.") }
        let (data,response) = try await session.data(from:URL(string:"https://auth.openai.com/.well-known/jwks.json")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 256_000,
              let document = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let keys = document["keys"] as? [[String:Any]],
              let jwk = keys.first(where:{$0["kid"] as? String == kid}),
              jwk["use"] == nil || jwk["use"] as? String == "sig",
              jwk["alg"] == nil || jwk["alg"] as? String == alg else { throw VoiceError("Could not verify ChatGPT identity.") }
        let message = Data((parts[0]+"."+parts[1]).utf8), signature = try decodeURL(parts[2])
        let valid: Bool
        if alg == "ES256", jwk["kty"] as? String == "EC", jwk["crv"] as? String == "P-256",
           let x = jwk["x"] as? String, let y = jwk["y"] as? String {
            let key = try P256.Signing.PublicKey(x963Representation:Data([4])+decodeURL(x)+decodeURL(y))
            valid = try key.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation:signature),for:message)
        } else if alg == "RS256", jwk["kty"] as? String == "RSA",
                  let n = jwk["n"] as? String, let e = jwk["e"] as? String {
            func length(_ n: Int) -> Data { n < 128 ? Data([UInt8(n)]) : n < 256 ? Data([0x81,UInt8(n)]) : Data([0x82,UInt8(n>>8),UInt8(n&255)]) }
            func integer(_ bytes: Data) -> Data {
                let b = bytes.first.map { $0 >= 128 ? Data([0])+bytes : bytes } ?? bytes
                return Data([2])+length(b.count)+b
            }
            let modulus = try decodeURL(n), exponent = try decodeURL(e)
            guard (256...1024).contains(modulus.count), exponent.count <= 8 else { throw VoiceError("Invalid identity key.") }
            let integers = integer(modulus)+integer(exponent)
            let der = Data([0x30])+length(integers.count)+integers
            let attributes: [String:Any] = [kSecAttrKeyType as String:kSecAttrKeyTypeRSA,kSecAttrKeyClass as String:kSecAttrKeyClassPublic]
            guard let key = SecKeyCreateWithData(der as CFData,attributes as CFDictionary,nil) else { throw VoiceError("Invalid identity key.") }
            valid = SecKeyVerifySignature(key,.rsaSignatureMessagePKCS1v15SHA256,message as CFData,signature as CFData,nil)
        } else { throw VoiceError("ChatGPT identity key type did not match.") }
        guard valid else { throw VoiceError("ChatGPT identity signature did not match.") }
        return try OAuthValidation.identity(decodeURL(parts[1]),clientID:clientID,nonce:nonce,subject:subject)
    }
}

final class OpenAINoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

actor ChatGPTAuth {
    private var credentials: ChatGPTCredentials?
    private var generation = UUID()
    private var refreshTask: Task<ChatGPTCredentials,Error>?
    private let session: URLSession
    init(credentials: ChatGPTCredentials?) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        session = URLSession(configuration:config,delegate:OpenAINoRedirect(),delegateQueue:nil)
    }
    func install(_ value: ChatGPTCredentials) throws {
        try Task.checkCancellation()
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil
        try ChatGPTKeychain.save(value); credentials = value
    }
    func token() async throws -> String {
        guard let value = credentials, value.sharing else { throw VoiceError("Enable ChatGPT plan usage in Setup first.") }
        if value.expiresAt.timeIntervalSinceNow > 60 { return value.accessToken }
        let run = generation
        let task: Task<ChatGPTCredentials,Error>
        if let refreshTask { task = refreshTask }
        else {
            task = Task { try await self.refresh(value) }; refreshTask = task
        }
        do {
            let updated = try await task.value
            guard generation == run else { throw CancellationError() }
            try ChatGPTKeychain.save(updated); credentials = updated; refreshTask = nil
            try Task.checkCancellation(); return updated.accessToken
        } catch { if generation == run { refreshTask = nil }; throw error }
    }
    private func refresh(_ value: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        guard let token = value.refreshToken else { throw VoiceError("Reconnect ChatGPT in Setup.") }
        let result = try await Self.exchange(["grant_type":"refresh_token","client_id":value.clientID,
            "refresh_token":token,"resource":OpenAIProtocol.resource],session:session)
        var updated = value
        guard let access = result["access_token"] as? String, let expires = result["expires_in"] as? Double,
              expires.isFinite, expires > 0, result["token_type"] as? String == "Bearer" else { throw VoiceError("ChatGPT renewal was incomplete. Reconnect in Setup.") }
        updated.accessToken = access; updated.expiresAt = Date().addingTimeInterval(expires)
        updated.refreshToken = result["refresh_token"] as? String ?? value.refreshToken
        if let scope = result["scope"] as? String { updated.scopes = scope.split(separator:" ").map(String.init) }
        if let idToken = result["id_token"] as? String {
            _ = try await OpenAIIdentity.verify(idToken,clientID:value.clientID,nonce:nil,subject:value.subject,session:session)
            updated.idToken = idToken
        }
        guard updated.sharing else { throw VoiceError("ChatGPT plan usage is no longer authorized.") }
        return updated
    }
    static func exchange(_ values: [String:String], session: URLSession) async throws -> [String:Any] {
        var request = URLRequest(url:URL(string:"https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"; request.httpBody = OAuthValidation.form(values)
        request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
        let (data,response) = try await session.data(for:request); try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 128_000,
              let result = try JSONSerialization.jsonObject(with:data) as? [String:Any] else {
            throw VoiceError("ChatGPT sign-in or renewal failed. Reconnect in Setup.")
        }
        return result
    }
    func disconnect() async throws -> Bool {
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil
        let value = credentials; credentials = nil
        try ChatGPTKeychain.delete()
        guard let value, let refresh = value.refreshToken else { return true }
        do {
            let (discovery,response) = try await session.data(from:URL(string:"https://auth.openai.com/.well-known/openid-configuration")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with:discovery) as? [String:Any],
                  let endpoint = object["revocation_endpoint"] as? String, let url = URL(string:endpoint),
                  url.scheme == "https", url.host == "auth.openai.com" else { return false }
            var request = URLRequest(url:url); request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
            request.httpBody = OAuthValidation.form(["token":refresh,"token_type_hint":"refresh_token","client_id":value.clientID])
            for attempt in 0..<2 {
                let (_,result) = try await session.data(for:request)
                if (result as? HTTPURLResponse)?.statusCode == 200 { return true }
                if attempt == 0 { try await Task.sleep(nanoseconds:500_000_000) }
            }
        } catch { return false }
        return false
    }
}
