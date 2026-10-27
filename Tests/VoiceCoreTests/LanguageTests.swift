import XCTest
@testable import VoiceCore

final class LanguageContractTests: XCTestCase {
    func helperRequest(_ goal: String = "enter google.com in the address bar", screen: Bool = true) -> LanguageRequest {
        LanguageRequest(goal:goal,mode:.nextAction,observation:observation(),
            apps:[AppCandidate(id:"chrome",name:"Chrome")],history:[],includeScreen:screen)
    }
    func testLiteralAndWritingRequestsAreSeparated() {
        for goal in ["Write a polite reply", "Schrijf een kort antwoord", "Please translate this into Dutch"] {
            XCTAssertTrue(LanguageRouting.canGenerate(goal))
        }
        for goal in ["type write a polite reply", "enter google.com", "open Notes and type 'write a poem'", "dictate hello"] {
            XCTAssertFalse(LanguageRouting.canGenerate(goal))
        }
    }
    func testLiteralPayloadCannotBeRewrittenByHelper() throws {
        let request = helperRequest()
        try LanguageReply(requestID:request.id,observationID:request.observation.id,kind:.text,text:"google.com").validate(for:request)
        XCTAssertThrowsError(try LanguageReply(requestID:request.id,observationID:request.observation.id,kind:.text,text:"bing.com").validate(for:request))
    }
    func testURLBarTextIsAnExactJevCandidateWithoutLLM() {
        let candidates = Candidates(goal:"enter google.com in the URL bar",observation:observation(),apps:[])
        XCTAssertTrue(candidates.texts.contains("google.com"))
        XCTAssertTrue(candidates.urls.contains("https://google.com"))
    }
    func testPreparedWritingPayloadCanBeOfferedToJev() throws {
        let text = "Bedankt voor je bericht. Ik ben er om vijf uur."
        let request = helperRequest("Schrijf een vriendelijk antwoord")
        try LanguageReply(requestID:request.id,observationID:request.observation.id,kind:.text,text:text).validate(for:request)
        let jev = try JevRequest(goal:request.goal,observation:request.observation,apps:[],history:[],preparedTexts:[text])
        XCTAssertEqual(jev.candidates.texts.first,text)
        let result = try response(jev,operation:"typeText",selected:["text":"t0"])
        XCTAssertEqual(try jev.action(from:result,observation:request.observation).text,text)
    }
    func testPayloadAndActionCannotSmuggleReturn() throws {
        let request = helperRequest("Write an email")
        for text in ["Hello\nSend", "Hello\tthere", String(repeating:"x",count:2001)] {
            XCTAssertThrowsError(try LanguageReply(requestID:request.id,observationID:request.observation.id,kind:.text,text:text).validate(for:request))
            XCTAssertThrowsError(try LanguageAction(operation:.typeText,target:"e1",text:text).resolve(for:request))
        }
    }
    func testReplyIsBoundToBothRequestAndObservation() {
        let request = helperRequest()
        for (id,observationID) in [(UUID(),request.observation.id),(request.id,UUID())] {
            XCTAssertThrowsError(try LanguageReply(requestID:id,observationID:observationID,kind:.text,text:"google.com").validate(for:request))
        }
    }
    func testPreparedTextCannotDriftDuringLaterSteps() {
        let request = LanguageRequest(goal:"Write a greeting",mode:.nextAction,observation:observation(),
            apps:[],history:[],includeScreen:true,preparedTexts:["Hello there"])
        XCTAssertThrowsError(try LanguageReply(requestID:request.id,observationID:request.observation.id,
            kind:.text,text:"A different greeting").validate(for:request))
    }
    func testUnknownTargetAndTextOnlyTargetGuessesRejected() {
        XCTAssertThrowsError(try LanguageAction(operation:.focus,target:"invented").resolve(for:helperRequest()))
        XCTAssertThrowsError(try LanguageAction(operation:.focus,target:"e1").resolve(for:helperRequest(screen:false)))
    }
    func testHelperCannotChooseDifferentNamedApp() {
        let request = LanguageRequest(goal:"open Google Chrome",mode:.nextAction,observation:observation(),
            apps:[AppCandidate(id:"chrome",name:"Chrome"),AppCandidate(id:"safari",name:"Safari")],history:[],includeScreen:true)
        XCTAssertThrowsError(try LanguageAction(operation:.openApp,target:"safari").resolve(for:request))
    }
    func testNoHelperShellOrVisualCoordinatesOrCompletion() {
        let request = helperRequest()
        for op in [Operation.visualClick,.done,.clarify,.requestLanguage] {
            XCTAssertThrowsError(try LanguageAction(operation:op).resolve(for:request))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(LanguageAction.self,from:Data(#"{"operation":"shell","text":"open -a Safari"}"#.utf8)))
    }
    func testHelperSubmissionAndClicksKeepConfirmationFloor() throws {
        let request = helperRequest()
        XCTAssertTrue(try LanguageAction(operation:.shortcut,shortcut:.enter).resolve(for:request).requiresConfirmation)
        XCTAssertTrue(try LanguageAction(operation:.click,target:"e0").resolve(for:request).requiresConfirmation)
        XCTAssertFalse(try LanguageAction(operation:.openApp,target:"chrome").resolve(for:request).requiresConfirmation)
    }
    func testTextOnlyRequestDoesNotSendImageOrAccessibility() throws {
        let request = helperRequest(screen:false)
        let data = try OpenAIProtocol.body(for:request,model:"gpt-6-luna")
        let string = String(decoding:data,as:UTF8.self)
        XCTAssertFalse(string.contains("input_image")); XCTAssertFalse(string.contains("AXTextField"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(body["store"] as? Bool,false); XCTAssertEqual(body["stream"] as? Bool,true)
        XCTAssertNil(body["tools"]); XCTAssertNil(body["background"]); XCTAssertNil(body["conversation"])
    }
    func testScreenContextIsExplicitAndBounded() throws {
        let data = try OpenAIProtocol.body(for:helperRequest(),model:"gpt-6-luna")
        let string = String(decoding:data,as:UTF8.self)
        XCTAssertTrue(string.contains("input_image")); XCTAssertTrue(string.contains("AXTextField"))
    }
    func testStreamingDeltasNeverAuthorizeAnAction() throws {
        var stream = OpenAIEventStream()
        try stream.append(line:#"data: {"type":"response.output_text.delta","delta":"{}"}"#)
        try stream.append(line:"")
        XCTAssertThrowsError(try stream.finish())
        try stream.append(line:#"data: {"type":"response.failed","response":{"error":{"message":"private server details"}}}"#)
        XCTAssertThrowsError(try stream.append(line:"")) { XCTAssertFalse($0.localizedDescription.contains("private server details")) }
    }
    func testOnlyCompletedValidatedJSONIsReturned() throws {
        let request = helperRequest()
        let reply = LanguageReply(requestID:request.id,observationID:request.observation.id,kind:.text,text:"google.com")
        let text = String(decoding:try JSONEncoder().encode(reply),as:UTF8.self)
        let event: [String:Any] = ["type":"response.completed","response":["status":"completed",
            "output":[["type":"message","content":[["type":"output_text","text":text]]]]]]
        var stream = OpenAIEventStream()
        try stream.append(line:"data: "+String(decoding:JSONSerialization.data(withJSONObject:event),as:UTF8.self))
        try stream.append(line:"")
        try stream.finish().validate(for:request)
        XCTAssertEqual(try stream.finish().text,"google.com")
    }
}

@MainActor private final class FakeLanguage: LanguageHelping {
    var calls = 0
    var hook: (() -> Void)?
    var makeReply: ((LanguageRequest) -> LanguageReply)?
    func assist(_ request: LanguageRequest) async throws -> LanguageReply {
        calls += 1; hook?()
        return makeReply?(request) ?? LanguageReply(requestID:request.id,observationID:request.observation.id,
            kind:.text,text:"Hello there")
    }
}

@MainActor final class LanguageLoopTests: XCTestCase {
    private final class PreparedDecider: Deciding {
        var index = 0
        func decide(_ request: JevRequest) async throws -> JevResponse {
            defer { index += 1 }
            return try response(request,operation:index == 0 ? "typeText" : "done",selected:["text":"t0"],complete:index == 0 ? 0 : 1)
        }
    }
    func testWritingPreparationReobservesAndRunsThroughJev() async throws {
        let world = World(), language = FakeLanguage()
        let decider = PreparedDecider()
        let loop = GoalLoop(desktop:world,decider:decider,language:language)
        try await loop.run(goal:"Write a greeting")
        XCTAssertEqual(language.calls,1); XCTAssertEqual(world.observations,3)
        XCTAssertEqual(world.actions.count,1); XCTAssertEqual(world.actions.first?.text,"Hello there")
    }
    func testStopWhileHelperReturnsPreventsAllActions() async throws {
        let world = World(), language = FakeLanguage()
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["typeText"]),language:language)
        language.hook = { loop.stop() }
        do { try await loop.run(goal:"Write a greeting"); XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertTrue(world.actions.isEmpty)
    }
    func testStopBeforeAssistanceDoesNotCallProvider() async throws {
        let world = World(), language = FakeLanguage()
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["done"]),language:language)
        loop.onEvent = { if $0.phase == .assisting { loop.stop() } }
        do { try await loop.run(goal:"Write a greeting"); XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(language.calls,0); XCTAssertTrue(world.actions.isEmpty)
    }
    func testJevCanDelegateOneActionToTheSameExecutor() async throws {
        let world = World(), language = FakeLanguage()
        language.makeReply = { LanguageReply(requestID:$0.id,observationID:$0.observation.id,kind:.action,
            action:LanguageAction(operation:.openApp,target:"chrome")) }
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["requestLanguage","done"]),language:language)
        try await loop.run(goal:"Open Chrome")
        XCTAssertEqual(world.actions.map(\.operation),[.openApp]); XCTAssertEqual(world.observations,2)
    }
    func testStaleHelperActionNeverExecutes() async throws {
        let world = World(), language = FakeLanguage(); world.fresh = false
        language.makeReply = { LanguageReply(requestID:$0.id,observationID:$0.observation.id,kind:.action,
            action:LanguageAction(operation:.openApp,target:"chrome")) }
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["requestLanguage"]),language:language)
        do { try await loop.run(goal:"Open Chrome"); XCTFail("Expected stale stop") } catch { }
        XCTAssertTrue(world.actions.isEmpty); XCTAssertLessThanOrEqual(language.calls,3)
    }
    func testAssistanceHasACallLimit() async throws {
        let world = World(), language = FakeLanguage()
        language.makeReply = { LanguageReply(requestID:$0.id,observationID:$0.observation.id,kind:.text,text:"Chrome") }
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["requestLanguage"]),language:language)
        do { try await loop.run(goal:"Open Chrome"); XCTFail("Expected bound") } catch { }
        XCTAssertEqual(language.calls,3); XCTAssertTrue(world.actions.isEmpty)
    }
}

final class OAuthValidationTests: XCTestCase {
    func testCallbackBindsStatePortPathAndIssuedClient() throws {
        let redirect = URL(string:"http://127.0.0.1:1455/auth/callback")!
        let url = URL(string:redirect.absoluteString+"?code=abc&state=expected&client_id=oaiapp_test")!
        XCTAssertEqual(try OAuthValidation.callback(url,redirect:redirect,state:"expected",clientID:nil).clientID,"oaiapp_test")
        XCTAssertThrowsError(try OAuthValidation.callback(url,redirect:redirect,state:"wrong",clientID:nil))
        XCTAssertThrowsError(try OAuthValidation.callback(url,redirect:redirect,state:"expected",clientID:"oaiapp_other"))
        XCTAssertThrowsError(try OAuthValidation.callback(url,redirect:URL(string:"http://127.0.0.1:1456/auth/callback")!,state:"expected",clientID:nil))
        XCTAssertThrowsError(try OAuthValidation.callback(URL(string:url.absoluteString+"&state=expected")!,redirect:redirect,state:"expected",clientID:nil))
    }
    func testIdentityClaimsRejectWrongIssuerAudienceNonceExpiryAndAccount() throws {
        let now = Date(timeIntervalSince1970:1000)
        let good: [String:Any] = ["iss":"https://auth.openai.com","sub":"user","aud":"client","exp":1100,"iat":990,"nonce":"nonce"]
        _ = try OAuthValidation.identity(JSONSerialization.data(withJSONObject:good),clientID:"client",nonce:"nonce",subject:"user",now:now)
        for (key,value) in [("iss","https://example.com"),("aud","other"),("nonce","other"),("sub","other")] {
            var bad = good; bad[key] = value
            XCTAssertThrowsError(try OAuthValidation.identity(JSONSerialization.data(withJSONObject:bad),clientID:"client",nonce:"nonce",subject:"user",now:now))
        }
        var expired = good; expired["exp"] = 999
        XCTAssertThrowsError(try OAuthValidation.identity(JSONSerialization.data(withJSONObject:expired),clientID:"client",nonce:"nonce",now:now))
    }
    func testOAuthFormEscapesReservedCharacters() {
        XCTAssertEqual(String(decoding:OAuthValidation.form(["code":"a+b &c=d"]),as:UTF8.self),"code=a%2Bb%20%26c%3Dd")
    }
}
