import XCTest
import AVFoundation
@testable import MacVoice

final class DebugAudioTests: XCTestCase {
    func testAACRoundTripHasExpectedDurationAndCompression() throws {
        let samples = (0..<32000).map { Float(sin(Double($0)*2*Double.pi*440/16000)*0.2) }
        let data = try DebugAudio.encode(samples)
        XCTAssertLessThan(data.count,16000) // Two seconds at 24 kbit/s plus AAC/ADTS overhead.
        XCTAssertEqual(data.prefix(2),Data([0xff,0xf1]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".aac")
        defer { try? FileManager.default.removeItem(at:url) }
        try data.write(to:url)
        let file = try AVAudioFile(forReading:url)
        XCTAssertEqual(file.fileFormat.sampleRate,16000)
        XCTAssertEqual(file.fileFormat.channelCount,1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:64000))
        try file.read(into:buffer)
        XCTAssertGreaterThan(buffer.frameLength,30000)
        XCTAssertLessThan(buffer.frameLength,36000) // AAC encoder delay/padding is expected.
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertGreaterThan((0..<Int(buffer.frameLength)).map { abs(channel[$0]) }.max() ?? 0,0.1)
    }
}
