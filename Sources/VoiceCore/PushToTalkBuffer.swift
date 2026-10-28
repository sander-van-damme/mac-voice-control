import Foundation

/// Held audio is finalized only by release, never by pauses inside the sentence.
public struct PushToTalkBuffer: Sendable {
    private var samples: [Float] = []
    private var voicedSamples = 0
    public init() {}
    public mutating func append(_ chunk: [Float]) throws {
        guard samples.count + chunk.count < 240_000 else {
            samples.removeAll(); voicedSamples = 0; throw VoiceError("Keep push-to-talk commands under 15 seconds.")
        }
        samples += chunk
        if !chunk.isEmpty {
            let rms = sqrt(chunk.reduce(Float(0)) { $0 + $1*$1 } / Float(chunk.count))
            if rms >= 0.012 { voicedSamples += chunk.count }
        }
    }
    public mutating func finish() -> [Float] {
        defer { samples.removeAll(keepingCapacity:true); voicedSamples = 0 }
        return voicedSamples >= 1600 ? samples : []
    }
}
