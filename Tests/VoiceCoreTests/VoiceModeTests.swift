import XCTest
@testable import VoiceCore

final class VoiceModeTests: XCTestCase {
    func testContinuousCommandsNeedNoWakePhrase() {
        XCTAssertEqual(InputRouter.route("open Chrome",final:true,wakeRequired:false),.command("open Chrome"))
        XCTAssertEqual(InputRouter.route("open Chrome",final:true),.ignore)
        XCTAssertEqual(InputRouter.route("dictate Hello there",final:true,wakeRequired:false),.dictation("Hello there"))
        XCTAssertEqual(InputRouter.route("stop",final:false,wakeRequired:false),.stop)
        XCTAssertEqual(InputRouter.route("open Chrome",final:false,wakeRequired:false),.ignore)
    }
    func testHeldSentenceIncludesPausesUntilReleaseAndResets() throws {
        var buffer = PushToTalkBuffer()
        try buffer.append([Float](repeating:0.2,count:2000))
        try buffer.append([Float](repeating:0,count:16000))
        try buffer.append([Float](repeating:0.3,count:2000))
        XCTAssertEqual(buffer.finish().count,20000)
        XCTAssertTrue(buffer.finish().isEmpty)
        try buffer.append([Float](repeating:0,count:32000))
        XCTAssertTrue(buffer.finish().isEmpty,"A silent hold must not be sent to ASR")
    }
    func testLongHeldSentenceCannotBecomeTruncatedCommand() throws {
        var buffer = PushToTalkBuffer()
        XCTAssertThrowsError(try buffer.append([Float](repeating:0.2,count:240000)))
        XCTAssertTrue(buffer.finish().isEmpty)
    }
}
