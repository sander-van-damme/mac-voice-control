import Foundation

/// A dropped microphone chunk invalidates an utterance, including a lost prefix.
public struct AudioContinuity: Sendable {
    private var expected: UInt64 = 0
    public init() {}
    public mutating func accept(sequence: UInt64) -> Bool {
        guard sequence == expected else { return false }
        expected &+= 1; return true
    }
}

public enum SpeechFreshness {
    public static let maximumAge: TimeInterval = 5
    public static func accepts(endedAt: TimeInterval, now: TimeInterval) -> Bool {
        endedAt.isFinite && now.isFinite && now >= endedAt && now-endedAt <= maximumAge
    }
}

public struct SpeechTranscript: Sendable {
    public let text: String
    public let inferenceMilliseconds: Double
    /// Includes endpoint silence, queueing and inference; end is estimated by local energy VAD.
    public let endToTranscriptMilliseconds: Double
    public init(text: String, inferenceMilliseconds: Double, endToTranscriptMilliseconds: Double) {
        self.text = text; self.inferenceMilliseconds = inferenceMilliseconds
        self.endToTranscriptMilliseconds = endToTranscriptMilliseconds
    }
}
