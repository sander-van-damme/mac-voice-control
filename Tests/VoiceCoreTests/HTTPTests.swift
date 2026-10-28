import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VoiceCore

private final class MockHTTP: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int,Data,[String:String]))?
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status,data,headers) = try Self.handler!(request)
            let response = HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}

@MainActor final class HTTPTests: XCTestCase {
    private func client() -> JevClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockHTTP.self]
        return JevClient(key:"test-only-not-a-real-key",session:URLSession(configuration:config))
    }
    func testClientSendsRealImageOptInAndAuthorizationHeaders() async throws {
        let q = try request()
        let fixture = try JSONEncoder().encode(response(q))
        MockHTTP.handler = { request in
            XCTAssertEqual(request.url?.absoluteString,"https://api.typesafe.ai/v1/systemone")
            XCTAssertEqual(request.httpMethod,"POST")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-only-not-a-real-key")
            XCTAssertEqual(request.value(forHTTPHeaderField:"TypeSafe-Danger-Zone-Images"),"true")
            return (200,fixture,[:])
        }
        let result = try await client().decide(q)
        XCTAssertEqual(result.model,"jev-1.14.0")
    }
    func testStagedArgumentsAreConditionedOnChosenOperation() async throws {
        let q = try request(), fixture = try response(q)
        var calls = 0
        MockHTTP.handler = { request in
            calls += 1
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(request.httpBody)) as? [String:Any])
            let questions = try XCTUnwrap(root["questions"] as? [String:Any])
            if calls == 1 { XCTAssertEqual(Set(questions.keys),Set(["operation","is_command","complete","sensitive"])) }
            else {
                XCTAssertEqual(Set(questions.keys),Set(["click_target"]))
                XCTAssertEqual((root["state"] as? [String:Any])?["selected_operation"] as? String,"click")
            }
            return (200,try JSONEncoder().encode(fixture),[:])
        }
        let result = try await client().decide(q)
        XCTAssertEqual(calls,2)
        XCTAssertEqual(try q.action(from:result,observation:observation()).target,"e0")
    }
    func testUnauthorizedIsNotRetriedAndResponseBodyIsNotExposed() async throws {
        var calls = 0
        MockHTTP.handler = { _ in calls += 1; return (401,Data("PRIVATE ECHO test-only-not-a-real-key".utf8),[:]) }
        do { _ = try await client().decide(request()); XCTFail("Expected auth failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE")); XCTAssertFalse(error.localizedDescription.contains("test-only")) }
        XCTAssertEqual(calls,1)
    }
    func testLongRetryAfterReturnsWithoutRepeatedRequests() async throws {
        var calls = 0
        MockHTTP.handler = { _ in calls += 1; return (429,Data(),["Retry-After":"120"]) }
        do { _ = try await client().decide(request()); XCTFail("Expected bounded retry refusal") } catch { }
        XCTAssertEqual(calls,1)
    }
    func testTransientRetryDoesNotExecuteOrChangeModel() async throws {
        let q = try request(), fixture = try JSONEncoder().encode(response(request()))
        var calls = 0
        MockHTTP.handler = { _ in
            calls += 1
            return calls == 1 ? (503,Data(),["Retry-After":"0"]) : (200,fixture,[:])
        }
        _ = try await client().decide(q)
        XCTAssertEqual(calls,3)
    }
}
