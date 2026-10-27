import XCTest
import CryptoKit
import Security
import VoiceCore
@testable import MacVoice

private final class IdentityFixtureProtocol: URLProtocol {
    static var document = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.absoluteString == "https://auth.openai.com/.well-known/jwks.json" else {
            client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Self.document); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ChatGPTIdentityTests: XCTestCase {
    func encoded(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
    func message(algorithm: String) throws -> String {
        let header: [String:Any] = ["alg":algorithm,"kid":"fixture"]
        let payload: [String:Any] = ["iss":"https://auth.openai.com","sub":"test-subject","aud":"test-client",
            "exp":Date().timeIntervalSince1970+3600,"iat":Date().timeIntervalSince1970,"nonce":"test-nonce"]
        return try encoded(JSONSerialization.data(withJSONObject:header))+"."+encoded(JSONSerialization.data(withJSONObject:payload))
    }
    func session(keys: [[String:Any]]) throws -> URLSession {
        IdentityFixtureProtocol.document = try JSONSerialization.data(withJSONObject:["keys":keys])
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IdentityFixtureProtocol.self]
        return URLSession(configuration:config)
    }
    func testES256IdentitySignatureIsActuallyVerified() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let bytes = privateKey.publicKey.x963Representation
        let session = try session(keys:[["kid":"fixture","kty":"EC","crv":"P-256","alg":"ES256","use":"sig",
            "x":encoded(bytes.subdata(in:1..<33)),"y":encoded(bytes.subdata(in:33..<65))]])
        defer { session.invalidateAndCancel() }
        let message = try message(algorithm:"ES256")
        let signature = try privateKey.signature(for:Data(message.utf8)).rawRepresentation
        let identity = try await OpenAIIdentity.verify(message+"."+encoded(signature),clientID:"test-client",nonce:"test-nonce",session:session)
        XCTAssertEqual(identity.subject,"test-subject")
        var bad = signature; bad[0] ^= 1
        do { _ = try await OpenAIIdentity.verify(message+"."+encoded(bad),clientID:"test-client",nonce:"test-nonce",session:session); XCTFail("Forged signature accepted") } catch { }
    }
    func testRS256IdentitySignatureIsActuallyVerified() async throws {
        let key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType:kSecAttrKeyTypeRSA,kSecAttrKeySizeInBits:2048] as CFDictionary,nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let representation = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey,nil)) as Data
        func field(_ data: Data, index: inout Int, tag: UInt8) throws -> Data {
            XCTAssertEqual(data[index],tag); index += 1
            var length = Int(data[index]); index += 1
            if length >= 128 {
                let count = length & 127; length = 0
                for _ in 0..<count { length = length*256 + Int(data[index]); index += 1 }
            }
            let value = data.subdata(in:index..<index+length); index += length
            return value
        }
        var index = 0
        let sequence = try field(representation,index:&index,tag:0x30); index = 0
        let modulus = try field(sequence,index:&index,tag:2).drop(while:{$0 == 0})
        let exponent = try field(sequence,index:&index,tag:2)
        let session = try session(keys:[["kid":"fixture","kty":"RSA","alg":"RS256","use":"sig",
            "n":encoded(Data(modulus)),"e":encoded(exponent)]])
        defer { session.invalidateAndCancel() }
        let message = try message(algorithm:"RS256")
        let signature = try XCTUnwrap(SecKeyCreateSignature(key,.rsaSignatureMessagePKCS1v15SHA256,Data(message.utf8) as CFData,nil)) as Data
        _ = try await OpenAIIdentity.verify(message+"."+encoded(signature),clientID:"test-client",nonce:"test-nonce",session:session)
        var bad = signature; bad[0] ^= 1
        do { _ = try await OpenAIIdentity.verify(message+"."+encoded(bad),clientID:"test-client",nonce:"test-nonce",session:session); XCTFail("Forged signature accepted") } catch { }
    }
}

@MainActor final class ChatGPTCallbackTests: XCTestCase {
    func testLoopbackRejectsWrongStateThenCompletesBrowserRedirect() async throws {
        let listener = OAuthLoopback(state:"fixture-state")
        defer { listener.cancel() }
        let redirect = try await listener.start()
        XCTAssertEqual(redirect.host,"127.0.0.1")
        XCTAssertEqual(redirect.path,"/auth/callback")
        var wrong = URLRequest(url:URL(string:redirect.absoluteString+"?state=wrong&code=fixture&client_id=oaiapp_fixture")!)
        wrong.timeoutInterval = 5
        let (_,rejected) = try await URLSession.shared.data(for:wrong)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode,400)
        var correct = URLRequest(url:URL(string:redirect.absoluteString+"?state=fixture-state&code=fixture&client_id=oaiapp_fixture")!)
        correct.timeoutInterval = 5
        let (_,accepted) = try await URLSession.shared.data(for:correct)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode,200)
        let callback = try await listener.result()
        XCTAssertEqual(try OAuthValidation.callback(callback,redirect:redirect,state:"fixture-state",clientID:nil).clientID,"oaiapp_fixture")
    }
    func testCancellingLoopbackReleasesWaitingSignIn() async throws {
        let listener = OAuthLoopback(state:"fixture-state")
        _ = try await listener.start()
        listener.cancel()
        do { _ = try await listener.result(); XCTFail("Cancelled sign-in returned a callback") }
        catch is CancellationError { }
    }
}
