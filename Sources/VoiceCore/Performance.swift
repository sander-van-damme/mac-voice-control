import Foundation

/// Content-free aggregates. No transcript, URL, label, image, or model payload is stored here.
public struct CommandMetrics: Codable, Sendable {
    public var timings: [String: Double] = [:]
    public var counts: [String: Int] = [:]
    public var success = false
    public var outcome = "running"
    public var failureCode: String?
    public var estimatedCostUSD: Double = 0
    public init() {}
    public mutating func add(_ stage: String, milliseconds: Double) { timings[stage,default:0] += max(0,milliseconds) }
    public mutating func count(_ key: String, by value: Int = 1) { counts[key,default:0] += value }
}
