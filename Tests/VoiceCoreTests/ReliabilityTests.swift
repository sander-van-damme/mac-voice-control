import XCTest
@testable import VoiceCore

final class InputSafetyTests: XCTestCase {
    func testDecisionCannotUseRecycledElementIDOnAnotherObservation() throws {
        let q = try request()
        var other = observation(); other.id = UUID()
        XCTAssertThrowsError(try q.action(from:response(q),observation:other))
    }
    func testConversationKeepsOriginalAndOnlyLatestCorrection() {
        var memory = ConversationMemory()
        memory.begin("Open Chrome and search for HumanEyes",at:10)
        _ = memory.correct("Nee, Safari",at:11,active:true)
        let revised = memory.correct("Actually, Chrome",at:12,active:true)
        XCTAssertEqual(memory.originalGoal,"Open Chrome and search for HumanEyes")
        XCTAssertEqual(memory.latestCorrection,"Actually, Chrome")
        XCTAssertFalse(revised!.contains("Nee, Safari"))
        XCTAssertTrue(revised!.hasPrefix("User correction (takes priority): Actually, Chrome"))
    }
    func testCorrectionsExpireAndStopClearsAuthority() {
        var memory = ConversationMemory(); memory.begin("Open Chrome",at:10)
        memory.finished(at:20)
        XCTAssertTrue(memory.acceptsCorrection(at:35,active:false))
        XCTAssertFalse(memory.acceptsCorrection(at:35.01,active:false))
        XCTAssertFalse(memory.acceptsCorrection(at:19,active:false))
        XCTAssertTrue(memory.acceptsCorrection(at:100,active:true))
        memory.clear()
        XCTAssertNil(memory.correct("Nee, de andere",at:21,active:true))
        XCTAssertFalse(memory.acceptsCorrection(at:21,active:false))
    }
    func testBackgroundCorrectionsCannotStartWorkWithoutContext() {
        for text in ["Actually I prefer tea", "Nee, dat bedoel ik niet", "No, the other one"] {
            XCTAssertEqual(InputRouter.route(text,final:true),.ignore)
        }
        XCTAssertEqual(InputRouter.route("Actually, go back",final:true,correctionAllowed:true),.correction("Actually, go back"))
    }
    func testAudioGapIncludingMissingFirstChunkInvalidatesUtterance() {
        var audio = AudioContinuity()
        XCTAssertTrue(audio.accept(sequence:0)); XCTAssertTrue(audio.accept(sequence:1))
        XCTAssertFalse(audio.accept(sequence:3)); XCTAssertFalse(audio.accept(sequence:4))
        var lostPrefix = AudioContinuity()
        XCTAssertFalse(lostPrefix.accept(sequence:1))
    }
    func testOldOrInvalidSpeechIsRejected() {
        XCTAssertTrue(SpeechFreshness.accepts(endedAt:10,now:15))
        XCTAssertFalse(SpeechFreshness.accepts(endedAt:10,now:15.01))
        XCTAssertFalse(SpeechFreshness.accepts(endedAt:10,now:9))
        XCTAssertFalse(SpeechFreshness.accepts(endedAt:.nan,now:15))
    }
    func testSensitiveLabelsRequireConsentInBothLanguages() {
        for label in ["Buy now", "Share", "Allow access", "Versturen", "Delen", "Koop nu", "Toestaan", "Indienen"] {
            XCTAssertTrue(Action(.click,label:label).requiresConfirmation,label)
        }
    }
    func testBilingualSyntheticRoutingCorpus() throws {
        struct Row: Decodable { let language: String, text: String, kind: String, payload: String? }
        let url = try XCTUnwrap(Bundle.module.url(forResource:"bilingual-routing",withExtension:"json",subdirectory:"Fixtures"))
        let rows = try JSONDecoder().decode([Row].self,from:Data(contentsOf:url))
        XCTAssertEqual(Set(rows.map(\.language)),["nl","en","mixed"])
        for row in rows {
            let actual = InputRouter.route(row.text,final:true)
            let expected: RoutedInput
            switch row.kind {
            case "command": expected = .command(try XCTUnwrap(row.payload))
            case "dictation": expected = .dictation(try XCTUnwrap(row.payload))
            case "stop": expected = .stop
            default: expected = .ignore
            }
            XCTAssertEqual(actual,expected,row.text)
            if row.kind != "stop" { XCTAssertEqual(InputRouter.route(row.text,final:false),.ignore) }
        }
    }
}

@MainActor final class AuthorityTests: XCTestCase {
    func testStopAtExecutionBoundaryPreventsInput() async throws {
        let world = World()
        let checked = GoalLoop(desktop:world,decider:ScriptedDecider(["click"]))
        checked.onEvent = { if $0.phase == .executing { checked.stop() } }
        do { try await checked.run(goal:"Click Next"); XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertTrue(world.actions.isEmpty)
    }
    func testStopBeforeDecisionDoesNotStartNetworkRequest() async throws {
        let world = World(), decider = ScriptedDecider(["click"])
        let loop = GoalLoop(desktop:world,decider:decider)
        loop.onEvent = { if $0.phase == .deciding { loop.stop() } }
        do { try await loop.run(goal:"Click Next"); XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(decider.index,0); XCTAssertTrue(world.actions.isEmpty)
    }
    func testSlowDecisionCannotActAfterWholeGoalDeadline() async throws {
        let world = World(), decider = ScriptedDecider(["click"])
        var now: TimeInterval = 10
        let loop = GoalLoop(desktop:world,decider:decider,clock:{ now })
        loop.timeBudget = 1; decider.hook = { now = 12 }
        do { try await loop.run(goal:"Click Next"); XCTFail("Expected deadline") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Time limit")) }
        XCTAssertTrue(world.actions.isEmpty)
    }
    func testDirectDeadlineRejectsConfirmationWhenTimerHasNotRun() async throws {
        let world = World()
        var now: TimeInterval = 10
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["visualClick"]),clock:{ now })
        loop.confirmationLifetime = 2
        loop.onEvent = { event in
            if event.phase == .paused, let id = loop.pendingConfirmationID {
                now = 12 // No suspension: the cleanup timer has not run.
                loop.resolveConfirmation(true,id:id)
            }
        }
        do { try await loop.run(goal:"Click the icon"); XCTFail("Expected expiry") } catch { }
        XCTAssertTrue(world.actions.isEmpty); XCTAssertNil(loop.pendingConfirmationID)
    }
    func testOldConfirmationCannotResolveNewPrompt() async throws {
        let world = World()
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["visualClick","done"]))
        let oldID = UUID()
        loop.onEvent = { event in
            if event.phase == .paused, let id = loop.pendingConfirmationID {
                loop.resolveConfirmation(true,id:oldID)
                XCTAssertEqual(loop.pendingConfirmationID,id)
                XCTAssertNotNil(loop.pendingAction)
                loop.resolveConfirmation(true,id:id)
            }
        }
        try await loop.run(goal:"Click the icon")
        XCTAssertEqual(world.actions.count,1)
        XCTAssertNil(loop.pendingConfirmationID)
    }
    func testConsentCannotExpireDuringFreshnessCheckThenAct() async throws {
        let world = World()
        var now: TimeInterval = 10
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["visualClick"]),clock:{ now })
        loop.confirmationLifetime = 2
        loop.onEvent = { event in
            if event.phase == .paused, let id = loop.pendingConfirmationID { loop.resolveConfirmation(true,id:id) }
        }
        world.freshHook = { now = 12 }
        do { try await loop.run(goal:"Click icon"); XCTFail("Expected expiry") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Confirmation expired")) }
        XCTAssertTrue(world.actions.isEmpty)
    }
    func testTaskCancellationResumesPendingConfirmation() async throws {
        let world = World()
        let loop = GoalLoop(desktop:world,decider:ScriptedDecider(["visualClick"]))
        let prompted = expectation(description:"Prompt displayed")
        loop.onEvent = { if $0.phase == .paused { prompted.fulfill() } }
        let task = Task { try await loop.run(goal:"Click icon") }
        await fulfillment(of:[prompted],timeout:2)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertNil(loop.pendingAction); XCTAssertNil(loop.pendingConfirmationID)
        XCTAssertTrue(world.actions.isEmpty)
    }
}
