import Foundation

/// Called only after signature verification. Shared here so identity binding is portable-testable.
public enum OAuthValidation {
    public static func identity(_ payload: Data, clientID: String, nonce: String?,
                                subject: String? = nil, now: Date = Date()) throws -> (subject: String, email: String?) {
        guard let c = try JSONSerialization.jsonObject(with:payload) as? [String:Any],
              c["iss"] as? String == "https://auth.openai.com",
              let sub = c["sub"] as? String, !sub.isEmpty,
              let exp = c["exp"] as? Double, exp.isFinite, exp > now.timeIntervalSince1970,
              let iat = c["iat"] as? Double, iat.isFinite, iat <= now.timeIntervalSince1970 + 5 else {
            throw VoiceError("ChatGPT identity validation failed.")
        }
        let audiences = (c["aud"] as? [String]) ?? (c["aud"] as? String).map { [$0] } ?? []
        if let nbf = c["nbf"] as? Double, !nbf.isFinite || nbf > now.timeIntervalSince1970 + 5 {
            throw VoiceError("ChatGPT identity is not yet valid.")
        }
        guard audiences.contains(clientID), audiences.count == 1 || c["azp"] as? String == clientID,
              nonce == nil || c["nonce"] as? String == nonce,
              subject == nil || subject == sub else { throw VoiceError("ChatGPT identity did not match this sign-in.") }
        return (sub,c["email"] as? String)
    }
    public static func callback(_ url: URL, redirect: URL, state: String, clientID: String?) throws -> (code: String, clientID: String) {
        guard url.scheme == redirect.scheme, url.host == "127.0.0.1", url.port == redirect.port,
              url.path == "/auth/callback", let components = URLComponents(url:url,resolvingAgainstBaseURL:false) else {
            throw VoiceError("Unexpected sign-in callback.")
        }
        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { throw VoiceError("Duplicate sign-in parameters.") }
        let values = Dictionary(uniqueKeysWithValues:items.map { ($0.name,$0.value ?? "") })
        guard values["state"] == state else { throw VoiceError("Sign-in state did not match.") }
        guard values["error"] == nil else { throw VoiceError("ChatGPT sign-in was declined or cancelled.") }
        guard let code = values["code"], !code.isEmpty,
              let issued = values["client_id"] ?? clientID, !issued.isEmpty, issued != "dynamic_agent_client",
              clientID == nil || issued == clientID else { throw VoiceError("ChatGPT registration did not match this sign-in.") }
        return (code,issued)
    }
    public static func form(_ values: [String:String]) -> Data {
        let allowed = CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted(by:{$0.key < $1.key}).map {
            $0.key.addingPercentEncoding(withAllowedCharacters:allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters:allowed)!
        }.joined(separator:"&").utf8)
    }
}
