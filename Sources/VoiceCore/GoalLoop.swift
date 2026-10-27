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
    private var confirmationDeadline: TimeInterval?
    private let clock: () -> TimeInterval
    public private(set) var pendingConfirmationID: UUID?
    public private(set) var pendingAction: Action?
    public private(set) var pendingObservation: Observation?
    public private(set) var history: [HistoryEntry] = []
    public var onEvent: (SessionEvent) -> Void = { _ in }
    public var maxSteps = 20
    public var timeBudget: Double = 90
    public var confirmationLifetime: Double = 25
    public init(desktop: DesktopControlling, decider: Deciding,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.desktop = desktop; self.decider = decider; self.clock = clock
    }
    public func stop() {
        generation = UUID(); finishConfirmation(false)
    }
    public func resolveConfirmation(_ allowed: Bool, id: UUID) {
        guard pendingConfirmationID == id else { return }
        // A timer can be delayed by suspension or IPC. It never extends consent.
        finishConfirmation(allowed && clock() < (confirmationDeadline ?? -.infinity))
    }
    private func finishConfirmation(_ allowed: Bool) {
        confirmationTimer?.cancel(); confirmationTimer = nil
        let c = confirmation; confirmation = nil; pendingAction = nil; pendingObservation = nil
        pendingConfirmationID = nil; confirmationDeadline = nil; c?.resume(returning: allowed)
    }
    private func check(_ run: UUID, deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard generation == run else { throw CancellationError() }
        guard clock() < deadline else { throw VoiceError("Time limit reached. Please give a smaller command.") }
    }
    private func confirm(_ action: Action, observation: Observation, run: UUID, deadline: TimeInterval) async throws -> TimeInterval? {
        try check(run, deadline: deadline)
        let lifetime = min(confirmationLifetime, deadline-clock())
        guard lifetime.isFinite, lifetime > 0 else { throw VoiceError("Confirmation expired.") }
        let expiresAt = clock()+lifetime
        let confirmationID = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning:false); return }
                confirmation = continuation
                pendingAction = action; pendingObservation = observation
                pendingConfirmationID = confirmationID; confirmationDeadline = expiresAt
                confirmationTimer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000)) }
                    catch { return }
                    guard let self, self.generation == run, self.pendingConfirmationID == confirmationID else { return }
                    self.finishConfirmation(false)
                }
                onEvent(SessionEvent(.paused,"Confirm: \(action.label). Say ‘confirm’ / ‘bevestig’, or cancel."))
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                self.finishConfirmation(false)
            }
        }
        try check(run, deadline: deadline); return result ? expiresAt : nil
    }
    public func run(goal: String, context: [HistoryEntry] = []) async throws {
        stop(); let run = generation
        history = Array(context.suffix(3))
        guard timeBudget.isFinite, timeBudget > 0, timeBudget <= 3600, maxSteps > 0,
              confirmationLifetime.isFinite, (0...300).contains(confirmationLifetime) else { throw VoiceError("Invalid execution limits.") }
        let started = clock(), deadline = started+timeBudget
        var previous: Observation?, previousAction: Action?, noChanges = 0, waits = 0, stale = 0
        var attempts: [(Observation,String)] = []
        for _ in 0..<maxSteps {
            try check(run, deadline: deadline)
            onEvent(SessionEvent(.observing,"Looking at the current window…"))
            try check(run, deadline: deadline)
            let o = try await desktop.observe(); try check(run, deadline: deadline)
            if let previous, let action = previousAction {
                let changed = !o.sameScene(as: previous)
                if action.operation != .wait { noChanges = changed ? 0 : noChanges + 1 }
                history.append(HistoryEntry(action: action.label, outcome: changed ? "Screen changed; goal success not yet established" : "No visible screen change"))
                history = Array(history.suffix(6))
            }
            guard noChanges < 3 else { throw VoiceError("The screen is not changing. I stopped to avoid repeating actions.") }
            let request = try JevRequest(goal: goal, observation: o, apps: desktop.apps, history: history)
            onEvent(SessionEvent(.deciding,"Choosing the next action…"))
            try check(run, deadline: deadline)
            let t = ProcessInfo.processInfo.systemUptime
            let response = try await decider.decide(request); try check(run, deadline: deadline)
            let action = try request.action(from: response, observation: o)
            var event = SessionEvent(.deciding,action.label)
            event.timings = o.timings; event.timings["jev_ms"] = (ProcessInfo.processInfo.systemUptime-t)*1000
            event.tokens = response.usage?.input_tokens ?? 0; event.cost = response.usage?.estimatedCostUSD ?? 0
            onEvent(event)
            if action.operation == .done {
                guard try await desktop.isFresh(o,for:action) else { continue }
                try check(run, deadline: deadline); onEvent(SessionEvent(.completed,"The goal appears complete.")); return
            }
            if action.operation == .clarify { throw VoiceError("Please clarify the target or give a smaller command. No action was taken.") }
            if action.operation == .wait {
                waits += 1
                guard waits <= 4 else { throw VoiceError("The page is still unavailable. Please try again when it is ready.") }
            } else { waits = 0 }
            if attempts.filter({ o.sameScene(as: $0.0) && action.fingerprint == $0.1 }).count >= 1 && action.operation != .wait {
                throw VoiceError("That action was already attempted on this screen. Please correct the target.")
            }
            var consentDeadline = deadline
            if action.requiresConfirmation {
                guard let expiry = try await confirm(action, observation:o, run: run, deadline: deadline) else { throw VoiceError("Action cancelled or confirmation expired.") }
                consentDeadline = expiry
            }
            try check(run, deadline: deadline)
            guard try await desktop.isFresh(o, for: action) else {
                stale += 1; previous = nil; previousAction = nil
                guard stale < 3 else { throw VoiceError("The window keeps changing. I stopped before acting on an outdated target.") }
                continue
            }
            try check(run, deadline: deadline)
            onEvent(SessionEvent(.executing,action.label))
            try check(run, deadline: deadline)
            guard clock() < consentDeadline else { throw VoiceError("Confirmation expired while checking the target. Please repeat the command.") }
            let actionStart = ProcessInfo.processInfo.systemUptime
            try await desktop.execute(action, observed: o); try check(run, deadline: deadline)
            var executed = SessionEvent(.executing,action.label)
            executed.timings["action_ms"] = (ProcessInfo.processInfo.systemUptime-actionStart)*1000
            if attempts.isEmpty { executed.timings["command_to_first_action_ms"] = (clock()-started)*1000 }
            onEvent(executed)
            attempts.append((o,action.fingerprint)); previous = o; previousAction = action
            try await Task.sleep(nanoseconds: action.operation == .wait ? 750_000_000 : 220_000_000)
        }
        throw VoiceError("Step limit reached. Please give a smaller command.")
    }
}
