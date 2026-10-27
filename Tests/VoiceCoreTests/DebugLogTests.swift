import XCTest
import Foundation
import CZlib
@testable import VoiceCore

final class DebugLogTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }
    private func files(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    /// Independent parser checks central offsets, sizes, raw DEFLATE, CRCs, and final EOCD.
    private func unpack(_ url: URL) throws -> [String:Data] {
        let bytes = try Data(contentsOf:url)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i+1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i+2) << 16 }
        XCTAssertEqual(u32(bytes.count-22),0x06054b50)
        let count = u16(bytes.count-12), centralSize = u32(bytes.count-10), centralOffset = u32(bytes.count-6)
        XCTAssertEqual(centralOffset+centralSize+22,bytes.count)
        var cursor = centralOffset, result: [String:Data] = [:]
        for _ in 0..<count {
            XCTAssertEqual(u32(cursor),0x02014b50)
            let packed = u32(cursor+20), size = u32(cursor+24), nameSize = u16(cursor+28), local = u32(cursor+42)
            let name = String(decoding:bytes[(cursor+46)..<(cursor+46+nameSize)],as:UTF8.self)
            XCTAssertEqual(u32(local),0x04034b50)
            let start = local+30+u16(local+26)+u16(local+28)
            let compressed = bytes.subdata(in:start..<(start+packed))
            var stream = z_stream(), output = Data(count:max(1,size))
            XCTAssertEqual(inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)),Z_OK)
            defer { inflateEnd(&stream) }
            let status = output.withUnsafeMutableBytes { dst in
                compressed.withUnsafeBytes { src in
                    stream.next_in = UnsafeMutablePointer(mutating:src.bindMemory(to:Bytef.self).baseAddress); stream.avail_in = uInt(packed)
                    stream.next_out = dst.bindMemory(to:Bytef.self).baseAddress; stream.avail_out = uInt(dst.count)
                    return inflate(&stream,Z_FINISH)
                }
            }
            XCTAssertEqual(status,Z_STREAM_END); output.count = size
            let crc = output.withUnsafeBytes { crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(size)) }
            XCTAssertEqual(Int(crc),u32(cursor+16))
            result[name] = output; cursor += 46+nameSize
        }
        return result
    }
    func testOptInAndLosslessPayloads() throws {
        let dir = try directory(), log = DebugLog(directory:dir)
        log.event("disabled"); log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.path))
        log.setEnabled(true)
        let data = Data("{\"unknown_field\":{\"nested\":[1,2,3]},\"text\":\"Hallo 👋\"}".utf8)
        log.record("model.response",data:data,fields:["request_id":"abc"])
        log.flush()
        let parts = try files(dir); XCTAssertEqual(parts.count,1)
        let values = try unpack(parts[0])
        XCTAssertTrue(values.values.contains(data))
        let metadata = try values.filter { $0.key.hasSuffix(".event.json") }.values.map {
            try JSONSerialization.jsonObject(with:$0) as! [String:String]
        }
        XCTAssertTrue(metadata.contains { $0["request_id"] == "abc" && $0["kind"] == "model.response" })
        log.setEnabled(false)
        let before = try Data(contentsOf:parts[0])
        log.event("disabled"); log.flush()
        XCTAssertEqual(try Data(contentsOf:parts[0]),before)
        XCTAssertNil(log.lastError)
        if FileManager.default.isExecutableFile(atPath:"/usr/bin/unzip") {
            let unzip = Process(); unzip.executableURL = URL(fileURLWithPath:"/usr/bin/unzip")
            unzip.arguments = ["-t",parts[0].path]; unzip.standardOutput = Pipe(); unzip.standardError = Pipe()
            try unzip.run(); unzip.waitUntilExit(); XCTAssertEqual(unzip.terminationStatus,0)
        }
    }
    func testRotationRetentionAndRestart() throws {
        let dir = try directory(), log = DebugLog(directory:dir,partLimit:2400,totalLimit:6000)
        log.setEnabled(true)
        // Deterministic poorly compressible bytes exercise actual compressed-size accounting.
        var state: UInt64 = 42
        let payload = Data((0..<900).map { _ -> UInt8 in state = state &* 6364136223846793005 &+ 1; return UInt8(truncatingIfNeeded:state >> 32) })
        for _ in 0..<20 { log.record("image",data:payload,ext:"jpg"); log.flush() }
        let parts = try files(dir)
        XCTAssertGreaterThan(parts.count,1)
        var total = 0
        for part in parts {
            let size = try Data(contentsOf:part).count; total += size; XCTAssertLessThanOrEqual(size,2400)
            XCTAssertTrue(try unpack(part).values.contains(payload))
        }
        XCTAssertLessThanOrEqual(total,6000)
        XCTAssertNil(log.lastError)
        log.setEnabled(false)
        let reopened = DebugLog(directory:dir,partLimit:2400,totalLimit:6000)
        reopened.setEnabled(true); reopened.event("restarted"); reopened.flush()
        for part in try files(dir) { _ = try unpack(part) }
        XCTAssertNil(reopened.lastError)
    }
    func testOversizedPayloadAndCrashCleanup() throws {
        let dir = try directory(), log = DebugLog(directory:dir,partLimit:2400,totalLimit:6000)
        log.setEnabled(true); log.flush()
        let corrupt = dir.appendingPathComponent("debug-crashed.zip")
        try Data([1,2,3]).write(to:corrupt)
        let unrelated = dir.appendingPathComponent("keep.txt"); try Data([4]).write(to:unrelated)
        log.setEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath:corrupt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:unrelated.path))
        log.setEnabled(true)
        log.capture("oversized",estimatedBytes:17_000_000,ext:"txt") { XCTFail("Should not allocate oversized capture"); return Data() }
        log.event("after_drop"); log.flush()
        let metadata = try files(dir).filter { $0.pathExtension == "zip" }.flatMap { try unpack($0).filter { $0.key.hasSuffix(".event.json") }.values }
        XCTAssertTrue(metadata.contains { String(decoding:$0,as:UTF8.self).contains("\"dropped_before\":\"1\"") })
    }
    func testRevealSealsPartAndReportsIOFailure() throws {
        let dir = try directory(), log = DebugLog(directory:dir)
        log.setEnabled(true); log.event("before_reveal"); log.prepareForSharing()
        let sealed = try XCTUnwrap(files(dir).first), before = try Data(contentsOf:sealed)
        log.event("after_reveal"); log.flush()
        XCTAssertEqual(try Data(contentsOf:sealed),before)
        XCTAssertEqual(try files(dir).count,2)
        for file in try files(dir) { _ = try unpack(file) }
        let blocked = dir.appendingPathComponent("not-a-directory")
        try Data([1]).write(to:blocked)
        let failed = DebugLog(directory:blocked)
        failed.setEnabled(true); failed.event("unwritable"); failed.flush()
        XCTAssertNotNil(failed.lastError)
    }

}
