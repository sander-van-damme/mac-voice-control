import Foundation

@MainActor public protocol DesktopControlling {
    var apps: [AppCandidate] { get }
    func observe() async throws -> Observation
    func isFresh(_ observation: Observation, for action: Action) async throws -> Bool
    func execute(_ action: Action, observed: Observation) async throws
}
public enum SessionPhase: String, Sendable {
    case stopped = "Stopped", listening = "Listening", transcribing = "Transcribing", observing = "Observing"
    case deciding = "Deciding", executing = "Executing", paused = "Paused", completed = "Completed", failed = "Needs attention"
}
public struct SessionEvent: Sendable {
    public let phase: SessionPhase, message: String
    public var timings: [String: Double] = [:]
    public var tokens: Int = 0
    public var cost: Double = 0
    public init(_ phase: SessionPhase, _ message: String) { self.phase = phase; self.message = message }
}

@MainActor public final class GoalLoop {
    private let desktop: DesktopControlling, decider: Deciding
    private var generation = UUID()
    private var confirmation: CheckedContinuation<Bool,Never>?
    private var confirmationTimer: Task<Void,Never>?
    public private(set) var pendingAction: Action?
    public private(set) var history: [HistoryEntry] = []
    public var onEvent: (SessionEvent) -> Void = { _ in }
    public var maxSteps = 20
    public var timeBudget: Double = 90
    public var confirmationLifetime: Double = 25
    public init(desktop: DesktopControlling, decider: Deciding) { self.desktop = desktop; self.decider = decider }
    public func stop() {
        generation = UUID(); resolveConfirmation(false)
    }
    public func resolveConfirmation(_ allowed: Bool) {
        confirmationTimer?.cancel(); confirmationTimer = nil
        let c = confirmation; confirmation = nil; pendingAction = nil; c?.resume(returning: allowed)
    }
    private func check(_ run: UUID) throws {
        try Task.checkCancellation()
        guard generation == run else { throw CancellationError() }
    }
    private func confirm(_ action: Action, run: UUID) async throws -> Bool {
        try check(run)
        pendingAction = action
        let result = await withCheckedContinuation { continuation in
            confirmation = continuation
            confirmationTimer = Task { [weak self] in
                guard let self else { return }
                do { try await Task.sleep(nanoseconds: UInt64(confirmationLifetime * 1_000_000_000)) }
                catch { return }
                resolveConfirmation(false)
            }
            onEvent(SessionEvent(.paused,"Confirm: \(action.label). Say ‘confirm’ / ‘bevestig’, or cancel."))
        }
        try check(run); return result
    }
    public func run(goal: String, context: [HistoryEntry] = []) async throws {
        stop(); let run = generation
        history = Array(context.suffix(3))
        let started = ProcessInfo.processInfo.systemUptime
        var previous: Observation?, previousAction: Action?, noChanges = 0, waits = 0, stale = 0
        var attempts: [(Observation,String)] = []
        for _ in 0..<maxSteps {
            try check(run)
            guard ProcessInfo.processInfo.systemUptime-started < timeBudget else { throw VoiceError("Time limit reached. Please give a smaller command.") }
            onEvent(SessionEvent(.observing,"Looking at the current window…"))
            let o = try await desktop.observe(); try check(run)
            if let previous, let action = previousAction {
                let changed = !o.sameScene(as: previous)
                if action.operation != .wait { noChanges = changed ? 0 : noChanges + 1 }
                history.append(HistoryEntry(action: action.label, outcome: changed ? "Screen changed; goal success not yet established" : "No visible screen change"))
                history = Array(history.suffix(6))
            }
            guard noChanges < 3 else { throw VoiceError("The screen is not changing. I stopped to avoid repeating actions.") }
            let request = try JevRequest(goal: goal, observation: o, apps: desktop.apps, history: history)
            onEvent(SessionEvent(.deciding,"Choosing the next action…"))
            let t = ProcessInfo.processInfo.systemUptime
            let response = try await decider.decide(request); try check(run)
            let action = try request.action(from: response, observation: o)
            var event = SessionEvent(.deciding,action.label)
            event.timings = o.timings; event.timings["jev_ms"] = (ProcessInfo.processInfo.systemUptime-t)*1000
            event.tokens = response.usage?.input_tokens ?? 0; event.cost = response.usage?.estimatedCostUSD ?? 0
            onEvent(event)
            if action.operation == .done {
                guard try await desktop.isFresh(o,for:action) else { continue }
                try check(run); onEvent(SessionEvent(.completed,"The goal appears complete.")); return
            }
            if action.operation == .clarify { throw VoiceError("Please clarify the target or give a smaller command. No action was taken.") }
            if action.operation == .wait {
                waits += 1
                guard waits <= 4 else { throw VoiceError("The page is still unavailable. Please try again when it is ready.") }
            } else { waits = 0 }
            if attempts.filter({ o.sameScene(as: $0.0) && action.fingerprint == $0.1 }).count >= 1 && action.operation != .wait {
                throw VoiceError("That action was already attempted on this screen. Please correct the target.")
            }
            if action.requiresConfirmation {
                guard try await confirm(action, run: run) else { throw VoiceError("Action cancelled or confirmation expired.") }
            }
            try check(run)
            guard try await desktop.isFresh(o, for: action) else {
                stale += 1; previous = nil; previousAction = nil
                guard stale < 3 else { throw VoiceError("The window keeps changing. I stopped before acting on an outdated target.") }
                continue
            }
            try check(run)
            onEvent(SessionEvent(.executing,action.label))
            let actionStart = ProcessInfo.processInfo.systemUptime
            try await desktop.execute(action, observed: o); try check(run)
            var executed = SessionEvent(.executing,action.label)
            executed.timings["action_ms"] = (ProcessInfo.processInfo.systemUptime-actionStart)*1000
            if attempts.isEmpty { executed.timings["command_to_first_action_ms"] = (ProcessInfo.processInfo.systemUptime-started)*1000 }
            onEvent(executed)
            attempts.append((o,action.fingerprint)); previous = o; previousAction = action
            try await Task.sleep(nanoseconds: action.operation == .wait ? 750_000_000 : 220_000_000)
        }
        throw VoiceError("Step limit reached. Please give a smaller command.")
    }
}
