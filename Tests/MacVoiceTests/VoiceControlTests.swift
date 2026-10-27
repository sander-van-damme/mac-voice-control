import XCTest
import VoiceCore
@testable import MacVoice

private final class APIKeyFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.value(forHTTPHeaderField:"Authorization") == "Bearer fixture-api-key",
              request.url?.absoluteString == "https://api.openai.com/v1/responses" else {
            client?.urlProtocol(self,didFailWithError:URLError(.userAuthenticationRequired)); return
        }
        let text = #"{"requestID":"11111111-1111-1111-1111-111111111111","observationID":"22222222-2222-2222-2222-222222222222","kind":"text","text":"google.com","action":null,"message":""}"#
        let event: [String:Any] = ["type":"response.completed","response":["status":"completed","output":[["type":"message","content":[["type":"output_text","text":text]]]]]]
        let bytes = try! JSONSerialization.data(withJSONObject:event)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"text/event-stream"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data("data: ".utf8)+bytes+Data("\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class APIKeyAuthenticationTests: XCTestCase {
    func testAPIKeyReachesResponsesWithoutAnOAuthAccount() async throws {
        let rect = Rect(0,0,400,400)
        var observation = Observation(pid:1,app:"Chrome",window:rect,controls:[],geometry:try .fitted(crop:rect),jpeg:Data(),signature:[])
        observation.id = UUID(uuidString:"22222222-2222-2222-2222-222222222222")!
        let request = LanguageRequest(goal:"type google.com",mode:.prepareText,observation:observation,apps:[],history:[],includeScreen:false)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [APIKeyFixture.self]
        let helper = OpenAILanguageHelper(auth:ChatGPTAuth(credentials:nil),model:"gpt-6-luna",apiKey:"fixture-api-key",injectedSession:URLSession(configuration:config))
        // The fixed reply is deliberately bound to another request; reaching this validation
        // error proves API-key transport succeeded without touching OAuth credentials.
        do { _ = try await helper.assist(request); XCTFail("An unrelated request was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("older request"),error.localizedDescription) }
    }
}
