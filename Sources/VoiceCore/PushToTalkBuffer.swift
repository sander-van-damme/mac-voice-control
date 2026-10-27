import Foundation

/// Held audio is finalized only by release, never by pauses inside the sentence.
public struct PushToTalkBuffer: Sendable {
    private var samples: [Float] = []
    public init() {}
    public mutating func append(_ chunk: [Float]) throws {
        guard samples.count + chunk.count < 240_000 else {
            samples.removeAll(); throw VoiceError("Keep push-to-talk commands under 15 seconds.")
        }
        samples += chunk
    }
    public mutating func finish() -> [Float] {
        defer { samples.removeAll(keepingCapacity:true) }
        return samples.count >= 1600 ? samples : []
    }
}
