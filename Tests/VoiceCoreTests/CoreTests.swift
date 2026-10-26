import XCTest
@testable import VoiceCore

func observation(state: UInt8 = 0, secure: Bool = false) -> Observation {
    let frame = Rect(-1920,100,1200,800)
    let controls = [Control(id:"e0",role:"AXButton",label:"Next",frame:Rect(-1800,200,80,40),canPress:true),
                    Control(id:"e1",role:"AXTextField",label:"Search",frame:Rect(-1750,300,400,40),canFocus:true)]
    return Observation(pid:123,app:"Chrome",window:frame,controls:controls,focusedID:"e1",secureFocus:secure,
        geometry:try! .fitted(crop:frame),jpeg:Data([0xFF,0xD8,0xFF]),signature:[UInt8](repeating:state,count:100))
}
func request(goal: String = "click Next") throws -> JevRequest {
    try JevRequest(goal:goal,observation:observation(),apps:[AppCandidate(id:"chrome",name:"Chrome")],history:[])
}
func response(_ request: JevRequest, operation: String = "click", selected: [String:String] = [:],
              complete: Double = 0, sensitive: Double = 0, present: Double = 1) throws -> JevResponse {
    var answers: [String:Any] = [:]
    for (name,offered) in request.choices {
        let choice = name == "operation" ? operation : (selected[name] ?? (name == "click_target" ? "e0" : name == "focus_target" ? "e1" : offered.sorted().first!))
        answers[name] = ["type":"choice","choice":choice,"confidence":1.0,
                         "probabilities":Dictionary(uniqueKeysWithValues:offered.map { ($0,$0 == choice ? 1.0 : 0.0) })]
    }
    for (key,value) in ["is_command":1.0,"complete":complete,"sensitive":sensitive,"present":present] {
        answers[key] = ["type":"noul","noul":value]
    }
    answers["visual_target"] = ["type":"box","box":["top":0.1,"bottom":0.2,"left":0.1,"right":0.2],"confidence":0.99]
    return try JevResponse.decode(JSONSerialization.data(withJSONObject:["model":JevRequest.model,"answers":answers,"usage":["input_tokens":100,"output_tokens":20]]))
}

final class CoreTests: XCTestCase {
    func testWireContractUsesReferencedImageAndPinnedModel() throws {
        let q = try request()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:q.body) as? [String:Any])
        XCTAssertEqual(body["model"] as? String,"jev-1.14.0")
        let state = try XCTUnwrap(body["state"] as? [String:Any])
        let assets = try XCTUnwrap(body["assets"] as? [String:Any])
        let ref = try XCTUnwrap(state["screenshot"] as? String)
        let asset = try XCTUnwrap(assets[ref] as? [String:Any])
        XCTAssertEqual(asset["format"] as? String,"jpg")
        XCTAssertNotNil(asset["data_base64"])
        XCTAssertNotNil(state["supplementary_accessibility"])
        let questions = try XCTUnwrap(body["questions"] as? [String:[String:Any]])
        XCTAssertEqual(questions["visual_target"]?["type"] as? String,"box")
        XCTAssertNil(questions["visual_target"]?["criteria"])
        XCTAssertEqual(questions["present"]?["type"] as? String,"noul")
    }
    func testRecordedFixtureParses() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"box-response",withExtension:"json",subdirectory:"Fixtures"))
        let decoded = try JevResponse.decode(Data(contentsOf:url))
        XCTAssertEqual(decoded.answers["target"]?.box?.left,0.25)
    }
    func testUnknownModelRejected() throws {
        let data = Data(#"{"model":"jev-1.13.0","answers":{}}"#.utf8)
        XCTAssertThrowsError(try JevResponse.decode(data))
    }
    func testChoiceRejectsInventedIDsAndWrongArgmax() throws {
        let data = Data(#"{"model":"jev-1.14.0","answers":{"target":{"type":"choice","choice":"a","confidence":1,"probabilities":{"a":0.1,"b":0.9}}}}"#.utf8)
        let value = try JevResponse.decode(data)
        XCTAssertThrowsError(try value.choice("target",offered:["a","b"]))
        XCTAssertThrowsError(try value.choice("target",offered:["b","c"]))
    }
    func testProbabilitySumAndMissingConfidenceRejected() throws {
        for json in [#"{"choice":"a","probabilities":{"a":1,"b":1},"confidence":1}"#,
                     #"{"choice":"a","probabilities":{"a":1,"b":0}}"#] {
            let answer = json.dropLast() + #","type":"choice"}"#
            let data = Data("{\"model\":\"jev-1.14.0\",\"answers\":{\"t\":\(answer)}}".utf8)
            let value = try JevResponse.decode(data)
            XCTAssertThrowsError(try value.choice("t",offered:["a","b"]))
        }
    }
    func testBoxRequiresPresence() throws {
        let q = try request(); let r = try response(q,operation:"visualClick",present:0.1)
        XCTAssertThrowsError(try q.action(from:r,observation:observation()))
    }
    func testBoxMappingRetinaIndependentAndNegativeOrigin() throws {
        let geometry = ImageGeometry(pixelWidth:1200,pixelHeight:800,content:Rect(0,0,1200,800),desktopCrop:Rect(-1920,100,600,400))
        let p = try geometry.desktopPoint(for:Box(top:0.25,bottom:0.75,left:0.25,right:0.75))
        XCTAssertEqual(p,Point(-1620,300))
    }
    func testPaddingAndDegenerateBoxesRejected() throws {
        let geometry = try ImageGeometry.fitted(crop:Rect(0,0,100,1000))
        XCTAssertEqual(geometry.pixelWidth,280)
        XCTAssertThrowsError(try geometry.desktopPoint(for:Box(top:0,bottom:0.2,left:0,right:0.1)))
        XCTAssertThrowsError(try geometry.desktopPoint(for:Box(top:0.5,bottom:0.5,left:0.4,right:0.6)))
        XCTAssertThrowsError(try geometry.desktopPoint(for:Box(top:0,bottom:1,left:.nan,right:1)))
    }
    func testScalingMaintainsAspectAndLimits() throws {
        let g = try ImageGeometry.fitted(crop:Rect(0,0,3840,2160))
        XCTAssertEqual(g.pixelWidth,1280); XCTAssertEqual(g.pixelHeight,720)
        XCTAssertThrowsError(try ImageGeometry.fitted(crop:Rect(0,0,0,100)))
    }
    func testSecureNormalizationOmitsControlsAndValues() throws {
        let secret = Control(id:"secret",role:"AXSecureTextField",label:"private-password",frame:Rect(0,0,20,20),secure:true)
        XCTAssertFalse(secret.label.contains("private-password"))
        XCTAssertTrue(Control.normalized([secret]).isEmpty)
        let encoded = try JSONEncoder().encode(Control.normalized([secret]))
        XCTAssertFalse(String(decoding:encoded,as:UTF8.self).contains("private-password"))
    }
    func testCandidateBudgetAndDeterministicAppOrdering() throws {
        let apps = (0..<100).map { AppCandidate(id:"a\($0)",name:"Application \($0)") } + [AppCandidate(id:"chrome",name:"Chrome")]
        let candidates = Candidates(goal:"Open Chrome",observation:observation(),apps:apps)
        XCTAssertEqual(candidates.apps.count,40); XCTAssertEqual(candidates.apps.first?.id,"chrome")
        XCTAssertLessThanOrEqual(candidates.texts.count,24)
    }
    func testLiteralDutchEnglishSpansAndURLSafety() {
        let spans = Candidates.spans("Type 'Hello, hoe gaat het?' in het tekstveld")
        XCTAssertTrue(spans.contains("Hello, hoe gaat het?"))
        XCTAssertFalse(Candidates.safeURL("file:///etc/passwd"))
        XCTAssertFalse(Candidates.safeURL("javascript:alert(1)"))
        XCTAssertFalse(Candidates.safeURL("https://user:password@example.org"))
        XCTAssertTrue(Candidates.safeURL("https://github.com"))
    }
    func testWakePhrasePreservesMixedLanguagePunctuation() {
        XCTAssertEqual(WakePhrase.command(in:"Hey Jeff, Type ‘Hello, hoe gaat het?’"),"Type ‘Hello, hoe gaat het?’")
        XCTAssertNil(WakePhrase.command(in:"I said hey Jev yesterday"))
        XCTAssertNil(WakePhrase.command(in:"hey jevil delete"))
    }
    func testPartialCannotExecuteAndBilingualStopCanCancel() {
        XCTAssertEqual(InputRouter.route("Hey Jev, delete the file",final:false),.ignore)
        XCTAssertEqual(InputRouter.route("Stop!",final:false),.stop)
        XCTAssertEqual(InputRouter.route("Annuleer",final:true),.stop)
    }
    func testOrdinarySpeechIgnoredAndExplicitDictationNotExecuted() {
        XCTAssertEqual(InputRouter.route("open the door please",final:true),.ignore)
        XCTAssertEqual(InputRouter.route("Hey Jev, dicteer delete all files",final:true),.dictation("delete all files"))
        XCTAssertEqual(InputRouter.route("Hey Jev, open een new tab",final:true),.command("open een new tab"))
    }
    func testCorrectionsAndConfirmationRouting() {
        XCTAssertEqual(InputRouter.route("Nee, de andere",final:true),.correction("Nee, de andere"))
        XCTAssertEqual(InputRouter.route("bevestig",final:true,confirmationPending:true),.confirm)
        XCTAssertEqual(InputRouter.route("bevestig",final:true,confirmationPending:false),.ignore)
        XCTAssertEqual(InputRouter.route("nee",final:true,confirmationPending:true),.cancel)
    }
    func testSensitiveGateCannotBeRemovedByModel() {
        var action = Action(.shortcut,label:"enter"); action.shortcut = .enter; action.sensitive = false
        XCTAssertTrue(action.requiresConfirmation)
        XCTAssertTrue(Action(.visualClick,label:"unknown icon").requiresConfirmation)
        XCTAssertTrue(Action(.click,label:"Verwijderen").requiresConfirmation)
    }
    func testDoneRequiresIndependentCompletionEvidence() throws {
        let q = try request()
        XCTAssertThrowsError(try q.action(from:response(q,operation:"done",complete:0.5),observation:observation()))
        XCTAssertEqual(try q.action(from:response(q,operation:"done",complete:0.99),observation:observation()).operation,.done)
    }
    func testTypingFocusesTargetBeforeInserting() throws {
        let q = try request(goal:"type hello")
        let wrongFocus = Observation(pid:123,app:"Chrome",window:observation().window,controls:observation().controls,focusedID:nil,
            geometry:observation().geometry,jpeg:Data([1]),signature:[0])
        XCTAssertEqual(try q.action(from:response(q,operation:"typeText",selected:["text":"t0"]),observation:wrongFocus).operation,.focus)
    }
    func testUtteranceSilenceAndMaximumDuration() {
        var segmenter = UtteranceSegmenter()
        XCTAssertNil(segmenter.append([Float](repeating:0,count:16000)))
        XCTAssertNil(segmenter.append([Float](repeating:0.2,count:3200)))
        XCTAssertNotNil(segmenter.append([Float](repeating:0,count:12800)))
        XCTAssertNotNil(segmenter.append([Float](repeating:0.2,count:240000)))
    }
}

@MainActor final class World: DesktopControlling {
    var apps = [AppCandidate(id:"chrome",name:"Chrome")]
    var state: UInt8 = 0, actions: [Action] = [], changes = true, fresh = true
    var observations = 0
    func observe() async throws -> Observation { observations += 1; return observation(state:state) }
    func isFresh(_ observation: Observation, for action: Action) async throws -> Bool { fresh }
    func execute(_ action: Action, observed: Observation) async throws { actions.append(action); if changes { state += 30 } }
}
@MainActor final class ScriptedDecider: Deciding {
    var steps: [String], index = 0
    var hook: (() -> Void)?
    init(_ steps: [String]) { self.steps = steps }
    func decide(_ request: JevRequest) async throws -> JevResponse {
        hook?()
        let op = steps[min(index,steps.count-1)]; index += 1
        return try response(request,operation:op,complete:op == "done" ? 1 : 0)
    }
}
@MainActor final class LoopTests: XCTestCase {
    func testMultiStepRealLoopObservesWorldAfterEachAction() async throws {
        let world = World(), decider = ScriptedDecider(["click","click","done"])
        let loop = GoalLoop(desktop:world,decider:decider)
        try await loop.run(goal:"Click next twice")
        XCTAssertEqual(world.actions.count,2); XCTAssertEqual(world.observations,3)
        XCTAssertEqual(loop.history.count,2)
    }
    func testSameScreenRepeatedActionStops() async throws {
        let world = World(); world.changes = false
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["click"]))
        do { try await loop.run(goal:"Click next"); XCTFail("Expected repeat guard") } catch { }
        XCTAssertEqual(world.actions.count,1)
    }
    func testStaleStateNeverExecutes() async throws {
        let world = World(); world.fresh = false
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["click"]))
        do { try await loop.run(goal:"Click next"); XCTFail("Expected stale guard") } catch { }
        XCTAssertTrue(world.actions.isEmpty); XCTAssertEqual(world.observations,3)
    }
    func testCancelWhileDecisionReturnsPreventsAction() async throws {
        let world = World(), decider = ScriptedDecider(["click"])
        let loop = GoalLoop(desktop:world,decider:decider)
        decider.hook = { loop.stop() }
        do { try await loop.run(goal:"Click next"); XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertTrue(world.actions.isEmpty)
    }
    func testConfirmationExpiryNeverExecutes() async throws {
        let world = World(), loop = GoalLoop(desktop:World(),decider:ScriptedDecider(["visualClick"]))
        _ = world
        loop.confirmationLifetime = 0.01
        do { try await loop.run(goal:"Click icon"); XCTFail("Expected expiry") } catch { }
        XCTAssertNil(loop.pendingAction)
    }
    func testStopClearsPendingConfirmation() async throws {
        let world = World(), decider = ScriptedDecider(["visualClick"])
        let loop = GoalLoop(desktop:world,decider:decider)
        loop.onEvent = { if $0.phase == .paused { loop.stop() } }
        do { try await loop.run(goal:"Click icon"); XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertTrue(world.actions.isEmpty); XCTAssertNil(loop.pendingAction)
    }
    func testConfirmationDoesNotSurviveChangedScreen() async throws {
        let world = World(); world.fresh = false
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["visualClick"]))
        loop.onEvent = { if $0.phase == .paused { loop.resolveConfirmation(true) } }
        do { try await loop.run(goal:"Click icon"); XCTFail("Expected stale rejection") } catch { }
        XCTAssertTrue(world.actions.isEmpty)
    }
    func testBoundedWaiting() async throws {
        let world = World(), loop = GoalLoop(desktop:World(),decider:ScriptedDecider(["wait"]))
        _ = world
        loop.maxSteps = 2
        do { try await loop.run(goal:"Wait for page"); XCTFail("Expected step limit") } catch { }
    }
    func testCorrectionContextIsBoundedAndPreserved() async throws {
        let world = World(), loop = GoalLoop(desktop:World(),decider:ScriptedDecider(["done"]))
        _ = world
        let context = (0..<10).map { HistoryEntry(action:"action \($0)",outcome:"observed") }
        try await loop.run(goal:"Nee, de andere",context:context)
        XCTAssertEqual(loop.history.count,3); XCTAssertEqual(loop.history.first?.action,"action 7")
    }
}
