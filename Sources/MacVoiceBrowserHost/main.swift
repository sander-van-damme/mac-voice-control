import Foundation
import VoiceCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Only Chrome invokes this executable. stdout is exclusively length-prefixed native messaging.
umask(0o077)
let mailbox: BrowserMailbox
#if DEBUG
if let i = CommandLine.arguments.firstIndex(of:"--test-directory"), CommandLine.arguments.indices.contains(i+1) {
    mailbox = BrowserMailbox(directory:URL(fileURLWithPath:CommandLine.arguments[i+1]))
} else { mailbox = BrowserMailbox() }
#else
mailbox = BrowserMailbox()
#endif
let connectionID = UUID()
let input = FileHandle.standardInput, output = FileHandle.standardOutput
let writeLock = NSLock()
func send(_ data: Data) throws {
    guard data.count <= 900_000 else { throw VoiceError("Oversized native message") }
    var length = UInt32(data.count).littleEndian
    writeLock.lock(); defer { writeLock.unlock() }
    try output.write(contentsOf:withUnsafeBytes(of:&length) { Data($0) })
    try output.write(contentsOf:data)
}
func exact(_ count: Int) throws -> Data? {
    var data = Data()
    while data.count < count {
        guard let next = try input.read(upToCount:count-data.count), !next.isEmpty else { return nil }
        data.append(next)
    }
    return data
}
do {
    try mailbox.prepare()
    // Chrome passes the requesting origin. Do not allow arbitrary extensions to use the bridge.
    guard CommandLine.arguments.dropFirst().first == "chrome-extension://jmfolbhhccnileefopndlkjokamifggp/" else { exit(1) }
    DispatchQueue.global(qos:.userInitiated).async {
        do {
            while let header = try exact(4) {
                let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8*$1.offset) }
                guard length > 0, length <= 900_000, let data = try exact(Int(length)) else { exit(1) }
                let reply = try JSONDecoder().decode(BrowserReply.self,from:data)
                try mailbox.write(data,name:reply.id.uuidString+".response")
            }
        } catch { }
        exit(0)
    }
    var lastHeartbeat: TimeInterval = 0
    while true {
        let now = Date().timeIntervalSince1970
        if now-lastHeartbeat > 1 {
            try mailbox.write(JSONSerialization.data(withJSONObject:["time":now,"id":connectionID.uuidString]),name:"heartbeat.json")
            lastHeartbeat = now
        }
        let files = try FileManager.default.contentsOfDirectory(at:mailbox.directory,includingPropertiesForKeys:[.contentModificationDateKey])
        // Cancellation messages precede actions already queued on disk.
        let commands = files.filter { $0.pathExtension == "request" }.compactMap { url -> (String,BrowserCommand,Data)? in
            guard let data = try? mailbox.read(name:url.lastPathComponent),
                  let c = try? JSONDecoder().decode(BrowserCommand.self,from:data) else { mailbox.remove(url.lastPathComponent); return nil }
            return (url.lastPathComponent,c,data)
        }.sorted { $0.1.kind == .cancel && $1.1.kind != .cancel }
        for (name,command,data) in commands {
            guard command.connectionID == connectionID else { continue }
            // Atomic claim prevents two native hosts from dispatching the same action.
            let claimed = name+".claimed"
            guard rename(mailbox.directory.appendingPathComponent(name).path,mailbox.directory.appendingPathComponent(claimed).path) == 0 else { continue }
            defer { mailbox.remove(claimed) }
            if command.expiresAt > now { try send(data) }
        }
        // Crash remnants never authorize another action and are removed after ten seconds.
        for url in files where url.lastPathComponent != "heartbeat.json" {
            if let date = try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate, now-date.timeIntervalSince1970 > 10 { mailbox.remove(url.lastPathComponent) }
        }
        Thread.sleep(forTimeInterval:0.02)
    }
} catch { exit(1) }
