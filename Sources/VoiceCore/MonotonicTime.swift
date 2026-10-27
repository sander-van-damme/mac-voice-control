import Foundation

/// A process-local time base that keeps advancing while the Mac sleeps.
public enum MonotonicTime {
    private static let origin = ContinuousClock.now
    public static var now: TimeInterval {
        let elapsed = origin.duration(to:ContinuousClock.now).components
        return Double(elapsed.seconds)+Double(elapsed.attoseconds)/1_000_000_000_000_000_000
    }
}
