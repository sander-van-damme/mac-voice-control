import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Private, short-lived IPC files. No TCP listener; Native Messaging is restricted to our extension ID.
/// Polling adds <=20ms per direction. Payloads are deleted after consumption, including cancellation.
public struct BrowserMailbox: Sendable {
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("MacVoiceControl/BrowserBridge",isDirectory:true)
    }
    public func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let a = try fm.attributesOfItem(atPath:directory.path)
        guard a[.type] as? FileAttributeType == .typeDirectory,
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0,
              directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
            throw VoiceError("Browser bridge directory must be private, owned by you, and contain no symlinks.")
        }
    }
    public func write(_ data: Data, name: String) throws {
        guard data.count <= 900_000, validName(name) else { throw VoiceError("Invalid browser IPC message.") }
        try prepare()
        let url = directory.appendingPathComponent(name)
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    public func read(name: String) throws -> Data? {
        guard validName(name) else { throw VoiceError("Invalid browser IPC name.") }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        let a = try FileManager.default.attributesOfItem(atPath:url.path)
        guard a[.type] as? FileAttributeType == .typeRegular,
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0,
              (a[.size] as? NSNumber)?.intValue ?? Int.max <= 900_000 else { throw VoiceError("Unsafe browser IPC file.") }
        return try Data(contentsOf:url)
    }
    public func remove(_ name: String) { if validName(name) { try? FileManager.default.removeItem(at:directory.appendingPathComponent(name)) } }
    private func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 120 && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0) }
    }
}

@MainActor public final class BrowserConnection {
    private let mailbox: BrowserMailbox
    private var runID = UUID()
    private var boundConnectionID: UUID?
    public init(mailbox: BrowserMailbox = BrowserMailbox()) { self.mailbox = mailbox }
    public var connected: Bool {
        guard let data = try? mailbox.read(name:"heartbeat.json"),
              let value = try? JSONDecoder().decode(Heartbeat.self,from:data) else { return false }
        return abs(Date().timeIntervalSince1970-value.time) < 3
    }
    public func cancel() {
        let old = runID; runID = UUID()
        guard let connectionID = boundConnectionID else { return }
        var command = BrowserCommand(runID:old,kind:.cancel,lifetime:3)
        command.connectionID = connectionID; boundConnectionID = nil
        try? mailbox.write(JSONEncoder().encode(command),name:command.id.uuidString+".request")
    }
    public func send(_ kind: BrowserCommand.Kind, context: BrowserContext? = nil, action: Action? = nil) async throws -> BrowserReply {
        try Task.checkCancellation()
        guard connected else { throw VoiceError("Chrome extension is not connected.") }
        let run = runID
        var command = BrowserCommand(runID:run,kind:kind,context:context,action:action)
        if boundConnectionID == nil, let data = try mailbox.read(name:"heartbeat.json") { boundConnectionID = try JSONDecoder().decode(Heartbeat.self,from:data).id }
        command.connectionID = boundConnectionID
        let name = command.id.uuidString
        try mailbox.write(JSONEncoder().encode(command),name:name+".request")
        defer { mailbox.remove(name+".request"); mailbox.remove(name+".response") }
        while Date().timeIntervalSince1970 < command.expiresAt {
            try Task.checkCancellation()
            guard run == runID else { throw CancellationError() }
            if let data = try mailbox.read(name:name+".response") {
                let reply = try JSONDecoder().decode(BrowserReply.self,from:data)
                guard reply.id == command.id else { throw VoiceError("Mismatched browser response.") }
                guard reply.ok else { throw VoiceError("Browser refused the operation. Observe again or use Accessibility/vision.") }
                return reply
            }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        throw VoiceError("Browser response timed out. The action will not be replayed; inspect the current page before continuing.")
    }
    private struct Heartbeat: Decodable { let id: UUID; let time: TimeInterval }
}
