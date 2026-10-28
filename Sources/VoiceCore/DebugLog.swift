import Foundation
import CZlib

/// Opt-in, local-only diagnostic content. Never pass credentials or HTTP headers here.
/// A serial worker owns disk IO; bounded admission keeps slow disks from retaining audio indefinitely.
public final class DebugLog: @unchecked Sendable {
    public static let shared = DebugLog()
    public static let archiveLimit = 25_000_000
    public static let cacheLimit = 1_000_000_000
    public let directory: URL
    private let queue = DispatchQueue(label:"MacVoice.debug-log",qos:.utility)
    private let lock = NSLock()
    private var enabled = false, pending = 0, pendingEvents = 0, dropped = 0
    private var sequence: UInt64 = 0
    private var generation = UUID()
    private var failure: String?
    private var writer: DebugZIP?
    private let partLimit: Int, totalLimit: Int
    public init(directory: URL? = nil, partLimit: Int = DebugLog.archiveLimit, totalLimit: Int = DebugLog.cacheLimit) {
        self.directory = directory ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("MacVoiceControl/DebugLogs",isDirectory:true)
        self.partLimit = max(1024,partLimit); self.totalLimit = max(max(1024,partLimit),totalLimit)
    }
    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    public var lastError: String? { lock.lock(); defer { lock.unlock() }; return failure }
    /// Invalidate queued work on disable. An already running write completes before this returns.
    public func setEnabled(_ value: Bool) {
        lock.lock(); enabled = value; generation = UUID(); lock.unlock()
        queue.sync {
            writer = nil
            do {
                if value || FileManager.default.fileExists(atPath:directory.path) { try prepare() }
            } catch { report(error) }
        }
        if value {
            event("logging.enabled",["format":"1","app_version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development",
                "build_sha":Bundle.main.object(forInfoDictionaryKey:"BuildCommit") as? String ?? "unpackaged", "os":ProcessInfo.processInfo.operatingSystemVersionString])
        }
    }
    public func event(_ kind: String, _ fields: [String:String] = [:]) {
        guard isEnabled else { return }
        if let data = try? JSONSerialization.data(withJSONObject:fields,options:.sortedKeys) { record(kind,data:data) }
    }
    public func value<T: Encodable>(_ kind: String, _ value: T, fields: [String:String] = [:]) {
        guard isEnabled else { return }
        do { record(kind,data:try JSONEncoder().encode(value),fields:fields) }
        catch { event("logging.encoding_failed",["kind":kind,"error":error.localizedDescription]) }
    }
    public func record(_ kind: String, data: Data, ext: String = "json", fields: [String:String] = [:]) {
        capture(kind,estimatedBytes:data.count,ext:ext,fields:fields) { data }
    }
    /// Used for AAC encoding on the worker. The estimate includes retained input memory.
    public func capture(_ kind: String, estimatedBytes: Int, ext: String,
                        fields: [String:String] = [:], produce: @escaping @Sendable () throws -> Data) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        guard (0...16_000_000).contains(estimatedBytes) else { dropped += 1; lock.unlock(); return }
        let budget = estimatedBytes + fields.reduce(1024) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        guard pending + budget <= 32_000_000, pendingEvents < 256 else {
            dropped += 1; lock.unlock(); return
        }
        let token = generation, lost = dropped; dropped = 0; pending += budget; pendingEvents += 1
        sequence &+= 1; let eventSequence = sequence, monotonic = MonotonicTime.now
        let time = Date(), id = UUID().uuidString
        lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); pending -= budget; pendingEvents -= 1; lock.unlock() }
            lock.lock(); let valid = enabled && generation == token; lock.unlock()
            guard valid else { return }
            do {
                var metadata = fields
                metadata["kind"] = kind; metadata["id"] = id
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
                metadata["timestamp"] = formatter.string(from:time)
                metadata["monotonic_seconds"] = String(monotonic)
                metadata["sequence"] = String(eventSequence); metadata["session_id"] = token.uuidString
                metadata["dropped_before"] = String(lost)
                let safeExtension = ["json","jpg","aac","txt"].contains(ext) ? ext : "bin"
                let payload = try produce()
                guard payload.count <= 16_000_000 else { throw VoiceError("Debug payload exceeded 16 MB.") }
                let name = id+"."+safeExtension
                metadata["payload"] = name
                try append([(id+".event.json",try JSONSerialization.data(withJSONObject:metadata,options:.sortedKeys)),(name,payload)])
            } catch { writer = nil; report(error) }
        }
    }
    /// Flush before revealing the directory or terminating. All idle archives are valid standalone ZIPs.
    public func flush() { queue.sync {} }
    /// Seal the current part so uploads can read stable files while logging continues in a new part.
    public func prepareForSharing() {
        queue.sync {
            writer = nil
            do { try prepare() } catch { report(error) }
        }
    }
    private func report(_ error: Error) {
        lock.lock(); failure = "Debug logging: " + error.localizedDescription; lock.unlock()
    }
    private func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        // Only our generated ZIPs are managed. Remove a truncated last write after a crash.
        for file in try archives() {
            let handle = try FileHandle(forReadingFrom:file)
            let size = try handle.seekToEnd()
            if size >= 22 { try handle.seek(toOffset:size-22) }
            let tail = try handle.read(upToCount:22) ?? Data(); try handle.close()
            if size > UInt64(partLimit) || tail.prefix(4) != Data([0x50,0x4b,0x05,0x06]) { try fm.removeItem(at:file) }
        }
        try prune(reserving:0)
    }
    private func archives() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("debug-") && $0.pathExtension == "zip" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func prune(reserving bytes: Int) throws {
        let files = try archives()
        var total = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) }
        for file in files where total + bytes > totalLimit && file != writer?.url {
            let size = try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            try FileManager.default.removeItem(at:file); total -= size
        }
        guard total + bytes <= totalLimit else { throw VoiceError("Debug cache is full.") }
    }
    private func append(_ entries: [(String,Data)]) throws {
        let packed = try entries.map { try DebugZIP.Entry(name:$0.0,data:$0.1) }
        let growth = packed.reduce(0) { $0 + $1.size }
        guard growth + 22 <= partLimit else { throw VoiceError("Debug event exceeds the ZIP part limit.") }
        if let writer, writer.size + growth > partLimit || writer.count >= 10000 { self.writer = nil }
        if writer == nil {
            try prepare()
            let name = "debug-"+String(format:"%.3f",Date().timeIntervalSince1970)+"-"+UUID().uuidString+".zip"
            try prune(reserving:22)
            writer = try DebugZIP(url:directory.appendingPathComponent(name))
        }
        try prune(reserving:growth)
        try writer!.append(packed)
    }
}

/// ZIP32 with raw DEFLATE and CRC32. Central-directory bytes count toward rotation and retention.
private final class DebugZIP {
    struct Entry {
        let name: Data, compressed: Data, originalSize: Int, crc: UInt32
        var size: Int { 30 + name.count + compressed.count + 46 + name.count }
        init(name: String, data: Data) throws {
            self.name = Data(name.utf8); originalSize = data.count
            crc = data.withUnsafeBytes { UInt32(crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(data.count))) }
            var stream = z_stream()
            guard deflateInit2_(&stream,Z_BEST_COMPRESSION,Z_DEFLATED,-MAX_WBITS,8,Z_DEFAULT_STRATEGY,
                                ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw VoiceError("Cannot initialize debug compression.") }
            defer { deflateEnd(&stream) }
            var output = Data(count:Int(deflateBound(&stream,uLong(data.count))))
            let result = output.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    stream.next_in = UnsafeMutablePointer(mutating:src.bindMemory(to:Bytef.self).baseAddress)
                    stream.avail_in = uInt(data.count)
                    stream.next_out = dst.bindMemory(to:Bytef.self).baseAddress; stream.avail_out = uInt(dst.count)
                    return deflate(&stream,Z_FINISH)
                }
            }
            guard result == Z_STREAM_END else { throw VoiceError("Debug compression failed.") }
            output.count = Int(stream.total_out); compressed = output
        }
    }
    let url: URL
    private let handle: FileHandle
    private var offset = 0, central = Data()
    private(set) var count = 0
    var size: Int { offset + central.count + 22 }
    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw VoiceError("Cannot create debug archive.") }
        handle = try FileHandle(forWritingTo:url)
        try append([])
    }
    deinit { try? handle.close() }
    func append(_ entries: [Entry]) throws {
        try handle.seek(toOffset:UInt64(offset))
        for e in entries {
            var local = Data()
            local.le32(0x04034b50); local.le16(20); local.le16(0); local.le16(8)
            local.le16(0); local.le16(0x21); local.le32(e.crc)
            local.le32(UInt32(e.compressed.count)); local.le32(UInt32(e.originalSize))
            local.le16(UInt16(e.name.count)); local.le16(0); local.append(e.name); local.append(e.compressed)
            var c = Data()
            c.le32(0x02014b50); c.le16(20); c.le16(20); c.le16(0); c.le16(8)
            c.le16(0); c.le16(0x21); c.le32(e.crc); c.le32(UInt32(e.compressed.count)); c.le32(UInt32(e.originalSize))
            c.le16(UInt16(e.name.count)); c.le16(0); c.le16(0); c.le16(0); c.le16(0); c.le32(0); c.le32(UInt32(offset)); c.append(e.name)
            try handle.write(contentsOf:local); offset += local.count; central.append(c); count += 1
        }
        try handle.write(contentsOf:central)
        var end = Data(); end.le32(0x06054b50); end.le16(0); end.le16(0)
        end.le16(UInt16(count)); end.le16(UInt16(count)); end.le32(UInt32(central.count)); end.le32(UInt32(offset)); end.le16(0)
        try handle.write(contentsOf:end); try handle.truncate(atOffset:UInt64(size))
    }
}
private extension Data {
    mutating func le16(_ n: UInt16) { var n = n.littleEndian; Swift.withUnsafeBytes(of:&n) { append(contentsOf:$0) } }
    mutating func le32(_ n: UInt32) { var n = n.littleEndian; Swift.withUnsafeBytes(of:&n) { append(contentsOf:$0) } }
}
