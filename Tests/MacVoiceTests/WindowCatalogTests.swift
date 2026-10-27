import XCTest
import CoreGraphics
import VoiceCore
@testable import MacVoice

final class WindowCatalogTests: XCTestCase {
    private let frame = Rect(-1800,-100,1200,800)
    private func entry(id: Int = 5, pid: Int = 100, alpha: Double = 1, width: Double = 1200) -> [String:Any] {
        [kCGWindowNumber as String:id,kCGWindowOwnerPID as String:pid,kCGWindowLayer as String:0,
         kCGWindowAlpha as String:alpha,
         kCGWindowBounds as String:CGRect(x:-1800,y:-100,width:width,height:800).dictionaryRepresentation]
    }
    func testMetadataParsingPreservesNegativeOriginAndRejectsInvisibleOrInvalidWindows() {
        let parsed = WindowCatalog.parse([entry(),entry(id:6,alpha:0),entry(id:7,width:0),[:]])
        XCTAssertEqual(parsed,[VisibleWindow(id:5,pid:100,frame:frame,layer:0)])
    }
    func testFallbackChoosesTopNormalWindowForRequestedProcess() {
        let popup = VisibleWindow(id:2,pid:100,frame:frame,layer:3)
        let other = VisibleWindow(id:3,pid:200,frame:frame,layer:0)
        let desired = VisibleWindow(id:5,pid:100,frame:frame,layer:0)
        XCTAssertEqual(WindowCatalog.foreground(pid:100,windows:[popup,other,desired]),desired)
        XCTAssertNil(WindowCatalog.foreground(pid:300,windows:[popup,other,desired]))
    }
    func testReplacedOrMovedWindowIsStaleEvenForSameProcess() {
        let old = VisibleWindow(id:5,pid:100,frame:frame,layer:0)
        XCTAssertTrue(WindowCatalog.unchanged(old,windows:[old]))
        XCTAssertFalse(WindowCatalog.unchanged(old,windows:[VisibleWindow(id:6,pid:100,frame:frame,layer:0)]))
        XCTAssertFalse(WindowCatalog.unchanged(old,windows:[VisibleWindow(id:5,pid:100,frame:Rect(-1700,-100,1200,800),layer:0)]))
    }
    func testCoveredTargetCannotUseScreenshotOnlyFallback() {
        let target = VisibleWindow(id:5,pid:100,frame:frame,layer:0), point = frame.center
        let covering = VisibleWindow(id:9,pid:200,frame:frame,layer:4)
        XCTAssertTrue(WindowCatalog.exposed(target,at:point,windows:[target]))
        XCTAssertFalse(WindowCatalog.exposed(target,at:point,windows:[covering,target]))
        XCTAssertFalse(WindowCatalog.exposed(target,at:Point(2000,2000),windows:[target]))
    }
    func testWindowOfSameAppCannotReplaceIntendedVisualTarget() {
        let target = VisibleWindow(id:5,pid:100,frame:frame,layer:0)
        let dialog = VisibleWindow(id:6,pid:100,frame:frame,layer:0)
        XCTAssertFalse(WindowCatalog.exposed(target,at:frame.center,windows:[dialog,target]))
    }
}
