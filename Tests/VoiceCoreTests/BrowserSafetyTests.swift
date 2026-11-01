import XCTest
@testable import VoiceCore

final class BrowserSafetyTests: XCTestCase {
    func testMailboxRejectsWorldReadableDirectoryAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let bad = root.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at:bad,withIntermediateDirectories:false,attributes:[.posixPermissions:0o755])
        XCTAssertThrowsError(try BrowserMailbox(directory:bad).prepare())
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
        XCTAssertThrowsError(try BrowserMailbox(directory:link).prepare())
        let box = BrowserMailbox(directory:root)
        XCTAssertThrowsError(try box.write(Data(),name:"../escape"))
        try box.write(Data([1,2,3]),name:"valid.response")
        XCTAssertEqual(try box.read(name:"valid.response"),Data([1,2,3]))
    }
    func testDerivedQueryCannotBeTypedIntoUnrelatedReplyField() {
        let payload = TextPayload(value:"newsletters",intent:.searchQuery,provenance:"deterministic_goal_extraction")
        let reply = Control(id:"reply",role:"textbox",label:"Reply",frame:Rect(0,0,100,40),canFocus:true)
        XCTAssertThrowsError(try TextTargetSafety.validate(payload,target:reply))
        let search = Control(id:"search",role:"searchbox",label:"Search",frame:Rect(0,0,100,40),canFocus:true)
        XCTAssertNoThrow(try TextTargetSafety.validate(payload,target:search))
    }
    func testIrrelevantBrowserRevisionDoesNotDefeatRepeatGuard() throws {
        var a = observation(), b = observation(); a.source = .browser; b.source = .browser
        a.browser = BrowserContext(tabID:1,documentID:"doc",revision:1,url:"https://example.org",title:"Page",text:"Same text")
        b.browser = BrowserContext(tabID:1,documentID:"doc",revision:2,url:"https://example.org",title:"Page",text:"Same text")
        XCTAssertTrue(a.sameScene(as:b))
        b.browser = BrowserContext(tabID:2,documentID:"doc",revision:2,url:"https://example.org",title:"Page",text:"Same text")
        XCTAssertFalse(a.sameScene(as:b))
    }
    func testModelCannotOfferAnUnobservedDropdownOrImageAction() throws {
        var o = observation(); o.source = .browser
        let q = try JevRequest(goal:"choose Newsletters",observation:o,apps:[],history:[])
        XCTAssertFalse(q.choices["operation"]!.contains("selectOption"))
        XCTAssertFalse(q.choices["operation"]!.contains("visualClick"))
        XCTAssertThrowsError(try q.action(from:response(q,operation:"selectOption"),observation:o))
    }
    func testSearchCompletionCannotBeEstablishedByFocusOrTypingAlone() {
        let step = TaskPlanner().plan("search for Next",apps:[]).steps[0]
        let o = observation(), history = [HistoryEntry(action:"Focus Search",outcome:"Screen changed; goal success not yet established")]
        XCTAssertFalse(TaskCompletionVerifier.verifies(step,in:o,apps:[],history:history))
        XCTAssertFalse(TaskCompletionVerifier.verifies(step,in:o,apps:[],history:history,searchBaseline:TaskCompletionVerifier.publicEvidence(o)))
        XCTAssertTrue(TaskCompletionVerifier.verifies(step,in:o,apps:[],history:history,searchBaseline:"No earlier matching result"))
    }
    func testTaskProgressCannotCompleteABlockedObjective() {
        var tracker = TaskProgressTracker(plan:TaskPlanner().plan("find the missing file",apps:[]))
        tracker.block("Not observed")
        XCTAssertFalse(tracker.plan.complete); XCTAssertNil(tracker.plan.current)
        tracker.advance(); XCTAssertFalse(tracker.plan.complete)
    }
}
