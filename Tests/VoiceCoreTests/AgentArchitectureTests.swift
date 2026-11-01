import XCTest
@testable import VoiceCore

final class CommandRouterTests: XCTestCase {
    let apps = [AppCandidate(id:"com.google.Chrome",name:"Google Chrome"),AppCandidate(id:"com.apple.finder",name:"Finder")]
    func testAnchoredBilingualAndMixedDirectCommands() {
        for goal in ["Open Chrome.","open Finder","Open Downloads","open een new tab","open een nieuw tabblad","Scroll omlaag","go back","switch to the previous tab"] {
            guard case let .direct(actions) = CommandRouter.route(goal,apps:apps) else { return XCTFail(goal) }
            XCTAssertEqual(actions.count,1)
        }
    }
    func testAmbiguityAndAdditionalClausesKeepFullGoal() {
        for goal in ["open something","maybe open Chrome","open Chrome or Finder","open Chrome and delete everything","open the previous one","scroll down twice"] {
            XCTAssertEqual(CommandRouter.route(goal,apps:apps),.goal,goal)
        }
    }
    func testOnlyKnownBrowserLaunchAndExplicitURLCanBatch() {
        guard case let .direct(actions) = CommandRouter.route("Open Chrome and go to example.org/CaseSensitive",apps:apps) else { return XCTFail() }
        XCTAssertEqual(actions.map(\.operation),[.openApp,.openURL])
        XCTAssertEqual(actions.last?.text,"https://example.org/CaseSensitive")
        XCTAssertEqual(CommandRouter.route("Open Finder and go to example.org",apps:apps),.goal)
    }
    func testLiteralPayloadNeverBecomesActions() {
        guard case let .direct(actions) = CommandRouter.route("type Open Chrome and delete files!",apps:apps) else { return XCTFail() }
        XCTAssertEqual(actions.count,1); XCTAssertEqual(actions[0].operation,.typeText)
        XCTAssertEqual(actions[0].text,"Open Chrome and delete files!")
    }
    func testQuotedTypingDoesNotInsertCommandSuffixOrGuessANamedTarget() {
        guard case let .direct(actions) = CommandRouter.route("type 'Hello, hoe gaat het?' in het tekstveld",apps:apps) else { return XCTFail() }
        XCTAssertEqual(actions[0].text,"Hello, hoe gaat het?")
        XCTAssertEqual(CommandRouter.route("type 'Hello' into Name",apps:apps),.goal)
        XCTAssertEqual(CommandRouter.route("type 'Hello' and open Finder",apps:apps),.goal)
    }
    func testPlannerRetainsObjectivesAndQuotedConjunctions() {
        let goal = "Open Chrome, go to example.org, search for newsletters, and open the newest matching result"
        let plan = TaskPlanner().plan(goal,apps:apps)
        XCTAssertEqual(plan.originalGoal,goal)
        XCTAssertEqual(plan.steps.map(\.objective),[.openApp,.navigate,.findContent,.openNewest])
        XCTAssertEqual(plan.steps[2].target,"newsletters")
        XCTAssertEqual(TaskPlanner.clauses("search for \"news and open letters\" and open results").count,2)
    }
    func testEachSearchObjectiveKeepsItsOwnQuery() {
        let plan = TaskPlanner().plan("search for newsletters and search for pricing and open the newest result",apps:apps)
        XCTAssertEqual(plan.query(for:plan.steps[0]),"newsletters")
        XCTAssertEqual(plan.query(for:plan.steps[1]),"pricing")
        XCTAssertEqual(plan.query(for:plan.steps[2]),"pricing")
    }
    func testDeterministicQueryExtractionDoesNotGuessSecrets() {
        XCTAssertEqual(TaskPlanner.searchQuery("Find the newsletter archive on this website"),"newsletter archive")
        XCTAssertEqual(TaskPlanner.searchQuery("Zoek naar nieuwsbrieven"),"nieuwsbrieven")
        XCTAssertNil(TaskPlanner.searchQuery("find my password"))
    }
}

final class SemanticDecisionTests: XCTestCase {
    func testStructuredRequestHasNoImageQuestionsAssetsOrUnavailableOperations() throws {
        var o = observation(); o.source = .accessibility
        let q = try JevRequest(goal:"click Next",observation:o,apps:[],history:[])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:q.body) as? [String:Any])
        let state = try XCTUnwrap(json["state"] as? [String:Any])
        let questions = try XCTUnwrap(json["questions"] as? [String:Any])
        XCTAssertEqual(q.mode,.structured); XCTAssertNil(json["assets"]); XCTAssertNil(state["screenshot"])
        XCTAssertNil(questions["present"]); XCTAssertNil(questions["visual_target"])
        XCTAssertFalse(q.choices["operation"]!.contains("openURL")); XCTAssertNil(q.choices["url"])
        XCTAssertTrue(q.choices["operation"]!.contains("requestVision"))
    }
    func testUnusedSpeculativeHeadCannotBreakSelectedAction() throws {
        var o = observation(); o.source = .accessibility
        let q = try JevRequest(goal:"click Next",observation:o,apps:[],history:[])
        var r = try response(q)
        var answers = r.answers
        answers["text"] = JevAnswer(type:"choice",choice:"invented")
        r = JevResponse(model:r.model,answers:answers,usage:nil)
        XCTAssertEqual(try q.action(from:r,observation:o).target,"e0")
        answers["click_target"] = JevAnswer(type:"choice",choice:"invented")
        XCTAssertThrowsError(try q.action(from:JevResponse(model:r.model,answers:answers,usage:nil),observation:o))
    }
    func testUnknownSemanticButtonStillRequiresConsent() {
        var o = observation(); o.source = .accessibility
        var action = Action(.click,label:"Next"); action.target = "e0"
        XCTAssertTrue(ActionSafety.requiresConfirmation(action,observation:o))
    }
    func testNewestNeedsDatesForEveryMatchingResultAndUniqueMaximum() {
        func link(_ id: String,_ date: String?) -> Control {
            Control(id:id,role:"link",label:"Newsletters",frame:Rect(0,0,100,20),canPress:true,destination:"https://example.org/"+id,date:date)
        }
        XCTAssertNil(BrowserSelection.newest(query:"newsletters",controls:[link("a",nil),link("b","2026-10-01")]))
        XCTAssertNil(BrowserSelection.newest(query:"newsletters",controls:[link("a","2026-10-01"),link("b","2026-10-01")]))
        XCTAssertEqual(BrowserSelection.newest(query:"newsletters",controls:[link("a","2026-09-01"),link("b","2026-10-01")])?.id,"b")
    }
    func testNavigationSanitizationAndSemanticStateChanges() {
        XCTAssertEqual(BrowserContext.canonicalURL("https://example.org/path?token=secret#private"),"https://example.org/path")
        var a = observation(), b = observation(); a.source = .accessibility; b.source = .accessibility
        XCTAssertTrue(a.sameScene(as:b))
        b = Observation(pid:a.pid,app:a.app,window:a.window,controls:[],geometry:a.geometry,jpeg:Data(),signature:[]); b.source = .accessibility
        XCTAssertFalse(a.sameScene(as:b))
    }
    func testNavigationNeedsObservedDestination() {
        let p = TaskPlanner().plan("go to example.org",apps:[])
        XCTAssertFalse(TaskCompletionVerifier.verifies(p.steps[0],in:observation(),apps:[],history:[]))
    }
}

@MainActor private final class DirectWorld: DesktopControlling, DirectCommandExecuting {
    let apps = [AppCandidate(id:"chrome",name:"Chrome")]
    var actions: [Action] = [], verified = true, hook: (() -> Void)?
    func observe() async throws -> Observation { observation() }
    func isFresh(_ observation: Observation,for action: Action) async throws -> Bool { true }
    func execute(_ action: Action,observed: Observation) async throws { actions.append(action) }
    func executeDirect(_ action: Action) async throws -> DirectResult { actions.append(action); return DirectResult(verified:verified) }
    func executeDirect(_ action: Action, validate: @MainActor () throws -> Void) async throws -> DirectResult {
        await Task.yield(); hook?(); try validate()
        return try await executeDirect(action)
    }
}
@MainActor final class FastLoopTests: XCTestCase {
    func testDirectBypassesAllDecisionCallsAndScreenshots() async throws {
        let world = DirectWorld(), decider = ScriptedDecider(["clarify"])
        let actual = GoalLoop(desktop:world,decider:decider)
        try await actual.run(goal:"open Chrome")
        XCTAssertEqual(world.actions.count,1); XCTAssertEqual(decider.index,0)
        XCTAssertEqual(actual.metrics.counts["screenshots_sent",default:0],0)
        XCTAssertTrue(actual.metrics.success)
    }
    func testUnverifiedDirectBatchStopsBeforeDependentNavigation() async throws {
        let world = DirectWorld(); world.verified = false
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["clarify"]))
        do { try await loop.run(goal:"open Chrome and go to example.org"); XCTFail() } catch { }
        XCTAssertEqual(world.actions.count,1); XCTAssertFalse(loop.metrics.success)
    }
    func testStopAtDirectExecutionBoundaryDoesNotAct() async throws {
        let world = DirectWorld()
        let actual = GoalLoop(desktop:world,decider:ScriptedDecider(["clarify"]))
        actual.onEvent = { if $0.phase == .executing { actual.stop() } }
        do { try await actual.run(goal:"open Chrome"); XCTFail() } catch is CancellationError { }
        XCTAssertTrue(world.actions.isEmpty)
    }
    func testDirectPreparationCannotCrossTheWholeTaskDeadline() async throws {
        let world = DirectWorld(); var now = 0.0
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["clarify"]),clock:{ now })
        loop.timeBudget = 1; world.hook = { now = 2 }
        do { try await loop.run(goal:"open Chrome"); XCTFail() } catch { }
        XCTAssertTrue(world.actions.isEmpty)
    }
    func testStopDuringDirectPreparationPreventsDispatch() async throws {
        let world = DirectWorld()
        let actual = GoalLoop(desktop:world,decider:ScriptedDecider(["clarify"]))
        world.hook = { actual.stop() }
        do { try await actual.run(goal:"open Chrome"); XCTFail() } catch is CancellationError { }
        XCTAssertTrue(world.actions.isEmpty); XCTAssertEqual(actual.metrics.outcome,"cancelled")
    }
    func testDispatchIsNotFalselyReportedAsVerifiedCompletion() async throws {
        let world = DirectWorld(); world.verified = false
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["clarify"]))
        try await loop.run(goal:"scroll down")
        XCTAssertEqual(loop.metrics.outcome,"dispatched_unverified"); XCTAssertFalse(loop.metrics.success)
    }
}
