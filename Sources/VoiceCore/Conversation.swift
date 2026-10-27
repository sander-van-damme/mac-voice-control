import Foundation

/// Authority for short, wake-free follow-ups. Contents stay in memory only.
public struct ConversationMemory: Sendable {
    public private(set) var originalGoal = ""
    public private(set) var latestCorrection: String?
    private var lastInteraction: TimeInterval = -.infinity
    public var correctionWindow: TimeInterval = 15
    public init() {}
    public mutating func begin(_ goal: String, at time: TimeInterval) {
        originalGoal = String(goal.prefix(1000)); latestCorrection = nil; lastInteraction = time
    }
    public func acceptsCorrection(at time: TimeInterval, active: Bool) -> Bool {
        !originalGoal.isEmpty && (active || (time >= lastInteraction && time-lastInteraction <= correctionWindow))
    }
    public mutating func correct(_ correction: String, at time: TimeInterval, active: Bool) -> String? {
        guard acceptsCorrection(at:time,active:active) else { return nil }
        latestCorrection = String(correction.prefix(1000)); lastInteraction = time
        return decisionGoal
    }
    public var decisionGoal: String {
        guard let latestCorrection else { return originalGoal }
        // Put the latest correction first so request bounds never discard it.
        return "User correction (takes priority): \(latestCorrection)\nOriginal goal: \(originalGoal)"
    }
    public mutating func finished(at time: TimeInterval) { lastInteraction = time }
    public mutating func clear() { originalGoal = ""; latestCorrection = nil; lastInteraction = -.infinity }
}
