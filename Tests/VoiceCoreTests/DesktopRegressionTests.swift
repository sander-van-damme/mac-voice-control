import XCTest
@testable import VoiceCore

final class DesktopRegressionTests: XCTestCase {
    func testOfficeShortNamesRemainAvailableBeyondOldBudget() {
        let office = AppCandidate(id:"com.microsoft.Powerpoint",name:"Microsoft PowerPoint")
        let apps = (0..<150).map { AppCandidate(id:"system\($0)",name:"A System Helper \($0)") } + [office]
        let candidates = Candidates(goal:"Open PowerPoint",observation:observation(),apps:apps)
        XCTAssertEqual(candidates.apps.first,office)
        XCTAssertEqual(candidates.apps.count,151)
        XCTAssertFalse(office.mentioned(in:"Open PowerPointless"))
    }
    func testInteractiveTargetBeyondFirstSixtyIsRetained() {
        let controls = (0..<100).map { Control(id:"e\($0)",role:"AXButton",label:"Button \($0)",frame:Rect(0,Double($0),10,10),canPress:true) }
        XCTAssertEqual(Control.normalized(controls).last?.id,"e99")
    }
    func testScrollContractAndVisualFallback() throws {
        let request = LanguageRequest(goal:"scroll down",mode:.nextAction,observation:observation(),apps:[],history:[],includeScreen:true)
        XCTAssertEqual(try LanguageAction(operation:.scroll,scroll:-5).resolve(for:request).scroll,-5)
        XCTAssertThrowsError(try LanguageAction(operation:.scroll,scroll:500).resolve(for:request))
        let point = Point(-1800,200)
        XCTAssertEqual(try LanguageAction(operation:.visualClick,point:point).resolve(for:request).point,point)
        XCTAssertThrowsError(try LanguageAction(operation:.drag,point:point,endPoint:Point(99999,0)).resolve(for:request))
        XCTAssertThrowsError(try LanguageAction(operation:.done).resolve(for:request))
    }
    func testCompletionUncertaintyCanRecover() throws {
        let q = try request()
        XCTAssertThrowsError(try q.action(from:response(q,operation:"done",complete:0.93),observation:observation())) {
            XCTAssertTrue($0 is DecisionUncertainty)
        }
    }
}
