import Foundation

@MainActor public protocol DesktopControlling {
    var apps: [AppCandidate] { get }
    var supportsTaskPlanning: Bool { get }
    var captureCount: Int? { get }
    func observe() async throws -> Observation
    func observe(preference: ObservationPreference) async throws -> Observation
    func waitForChange(after observation: Observation, action: Action) async throws
    func cancelPendingActions()
    func isFresh(_ observation: Observation, for action: Action) async throws -> Bool
    func execute(_ action: Action, observed: Observation) async throws
}
public extension DesktopControlling {
    var supportsTaskPlanning: Bool { false }
    var captureCount: Int? { nil }
    func observe(preference: ObservationPreference) async throws -> Observation { try await observe() }
    func waitForChange(after observation: Observation, action: Action) async throws {
        try await Task.sleep(nanoseconds: action.operation == .wait ? 100_000_000 : 30_000_000)
    }
    func cancelPendingActions() {}
}
public enum SessionPhase: String, Codable, Sendable {
    case stopped = "Stopped", listening = "Listening", transcribing = "Transcribing", observing = "Observing"
    case deciding = "Deciding", assisting = "Language assistance", executing = "Executing", paused = "Paused", completed = "Completed", failed = "Needs attention"
}
public struct SessionEvent: Codable, Sendable {
    public let phase: SessionPhase, message: String
    public var timings: [String: Double] = [:]
    public var tokens: Int = 0
    public var cost: Double = 0
    public init(_ phase: SessionPhase, _ message: String) { self.phase = phase; self.message = message }
}

@MainActor public final class GoalLoop {
    private let desktop: DesktopControlling, decider: Deciding
    private let language: (any LanguageHelping)?
    private let languageScreenContext: Bool
    private var generation = UUID()
    private var metricsRunID: UUID?
    private var confirmation: CheckedContinuation<Bool,Never>?
    private var confirmationTimer: Task<Void,Never>?
    private var confirmationDeadline: TimeInterval?
    private let clock: () -> TimeInterval
    public private(set) var pendingConfirmationID: UUID?
    public private(set) var pendingAction: Action?
    public private(set) var pendingObservation: Observation?
    public private(set) var metrics = CommandMetrics()
    public private(set) var progress: TaskProgressTracker?
    public var onMetrics: (CommandMetrics) -> Void = { _ in }
    public private(set) var history: [HistoryEntry] = []
    public var onEvent: (SessionEvent) -> Void = { _ in }
    public var maxSteps = 20
    public var timeBudget: Double = 90
    public var confirmationLifetime: Double = 25
    public init(desktop: DesktopControlling, decider: Deciding, language: (any LanguageHelping)? = nil,
                languageScreenContext: Bool = false,
                clock: @escaping () -> TimeInterval = { MonotonicTime.now }) {
        self.desktop = desktop; self.decider = decider; self.clock = clock
        self.language = language; self.languageScreenContext = languageScreenContext
    }
    public func stop() {
        generation = UUID(); finishConfirmation(false); desktop.cancelPendingActions()
    }
    public func resolveConfirmation(_ allowed: Bool, id: UUID) {
        DebugLog.shared.event("confirmation.resolved",["id":id.uuidString,"allowed":String(allowed),"current":String(pendingConfirmationID == id)])
        guard pendingConfirmationID == id else { return }
        // A timer can be delayed by suspension or IPC. It never extends consent.
        finishConfirmation(allowed && clock() < (confirmationDeadline ?? -.infinity))
    }
    private func finishConfirmation(_ allowed: Bool) {
        if let id = pendingConfirmationID { DebugLog.shared.event("confirmation.finished",["id":id.uuidString,"allowed":String(allowed)]) }
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
        DebugLog.shared.value("confirmation.requested",action,fields:["id":confirmationID.uuidString,"observation_id":observation.id.uuidString,"expires_at":String(expiresAt)])
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
        metricsRunID = run; metrics = CommandMetrics(); progress = nil
        DebugLog.shared.event("goal.started",["run_id":run.uuidString,"goal":goal])
        defer { DebugLog.shared.value("goal.history",history,fields:["run_id":run.uuidString]) }
        history = Array(context.suffix(3))
        guard timeBudget.isFinite, timeBudget > 0, timeBudget <= 3600, maxSteps > 0,
              confirmationLifetime.isFinite, (0...300).contains(confirmationLifetime) else { throw VoiceError("Invalid execution limits.") }
        let started = clock(), deadline = started+timeBudget
        var metrics = CommandMetrics()
        let captureCountAtStart = desktop.captureCount
        defer {
            if let start = captureCountAtStart, let end = desktop.captureCount { metrics.counts["screenshots_captured"] = max(0,end-start) }
            metrics.timings["task_completion_ms"] = max(0,(clock()-started)*1000)
            if metrics.outcome == "running" { metrics.outcome = Task.isCancelled || generation != run ? "cancelled" : "failed" }
            if metricsRunID == run { self.metrics = metrics; onMetrics(metrics) }
        }
        do {
            let routingStart = MonotonicTime.now
            let route = CommandRouter.route(goal,apps:desktop.apps)
            metrics.add("intent_routing_ms",milliseconds:(MonotonicTime.now-routingStart)*1000)
            if let direct = desktop as? any DirectCommandExecuting, case let .direct(actions) = route {
                var verified = true
                for action in actions {
                    try check(run,deadline:deadline)
                    onEvent(SessionEvent(.executing,action.label)); try check(run,deadline:deadline)
                    let actionStart = MonotonicTime.now
                    var executionStart = actionStart
                    let firstAction = metrics.counts["actions",default:0] == 0
                    let result: DirectResult
                    if action.requiresConfirmation {
                        let observation = try await desktop.observe(preference:.semantic)
                        metrics.count("confirmations")
                        guard let expiry = try await confirm(action,observation:observation,run:run,deadline:deadline) else { throw VoiceError("Action cancelled or confirmation expired.") }
                        guard try await desktop.isFresh(observation,for:action) else { throw VoiceError("The confirmed target changed.") }
                        try check(run,deadline:deadline)
                        guard clock() < expiry else { throw VoiceError("Confirmation expired while checking the target.") }
                        executionStart = MonotonicTime.now
                        try await desktop.execute(action,observed:observation)
                        result = DirectResult(verified:false,dispatchedAt:executionStart)
                    } else { result = try await direct.executeDirect(action,validate: { try self.check(run,deadline:deadline) }) }
                    try check(run,deadline:deadline)
                    if firstAction { metrics.timings["command_to_first_action_ms"] = max(0,((result.dispatchedAt ?? actionStart)-started)*1000) }
                    metrics.add("action_ms",milliseconds:(MonotonicTime.now-executionStart)*1000); metrics.count("actions")
                    verified = verified && result.verified
                    // A dependent action never follows an unverified launch/navigation.
                    if actions.count > 1 && !result.verified { throw VoiceError("The previous action could not be verified. The remaining actions were stopped.") }
                }
                metrics.success = verified; metrics.outcome = verified ? "verified" : "dispatched_unverified"
                var event = SessionEvent(verified ? .completed : .listening,verified ? "Command verified." : "Command sent; its outcome could not be verified.")
                event.timings = metrics.timings; onEvent(event); return
            }
            let planningStart = MonotonicTime.now
            progress = desktop.supportsTaskPlanning ? TaskProgressTracker(plan:TaskPlanner().plan(goal,apps:desktop.apps)) : nil
            metrics.add("planning_ms",milliseconds:(MonotonicTime.now-planningStart)*1000)
            var preference = ObservationPreference.automatic, visionRequested = false
            var newestDestination: String?
            var searchBaseline: String?
            var previous: Observation?, previousAction: Action?, noChanges = 0, waits = 0, stale = 0
            var attempts: [(Observation,String)] = []
            var preparedTexts: [String] = [], languageCalls = 0
            var preparationAttempted = false
            for _ in 0..<maxSteps {
                try check(run, deadline: deadline)
                onEvent(SessionEvent(.observing,"Looking at the current window…"))
                try check(run, deadline: deadline)
                let o = try await desktop.observe(preference:preference); try check(run, deadline: deadline)
                for (stage,ms) in o.timings { metrics.add(stage,milliseconds:ms) }
                if !o.jpeg.isEmpty { metrics.count("screenshots_captured") }
                if let previous, let action = previousAction {
                    let changed = !o.sameScene(as: previous)
                    if action.operation != .wait { noChanges = changed ? 0 : noChanges + 1 }
                    history.append(HistoryEntry(action: action.label, outcome: changed ? "Screen changed; goal success not yet established" : "No visible screen change"))
                    history = Array(history.suffix(6))
                }
                guard noChanges < 3 else { throw VoiceError("The screen is not changing. I stopped to avoid repeating actions.") }
                // Text is prepared once. Observe again after helper latency before selecting a target.
                if let language, !preparationAttempted, LanguageRouting.canGenerate(goal) {
                    preparationAttempted = true; languageCalls += 1
                    onEvent(SessionEvent(.assisting,"Preparing the requested text…")); try check(run,deadline:deadline)
                    let request = LanguageRequest(goal:goal,mode:.prepareText,observation:o,apps:desktop.apps,
                        history:history,includeScreen:languageScreenContext)
                    let languageStart = MonotonicTime.now
                    metrics.count("language_requests")
                    if languageScreenContext && !o.jpeg.isEmpty { metrics.count("screenshots_sent") }
                    let reply = try await language.assist(request);
                    metrics.add("language_model_ms",milliseconds:(MonotonicTime.now-languageStart)*1000); try check(run,deadline:deadline)
                    try reply.validate(for:request)
                    guard reply.kind == .text, let text = reply.text else {
                        throw VoiceError(reply.message.isEmpty ? "Please specify the text you want written." : reply.message)
                    }
                    preparedTexts = [text]; previous = nil; previousAction = nil
                    continue
                }
                if let step = progress?.plan.current {
                    onEvent(SessionEvent(.observing,"Objective \(step.id+1)/\(progress!.plan.steps.count): \(step.instruction)"))
                    try check(run,deadline:deadline)
                }
                let searchQuery = progress?.plan.current.flatMap { progress?.plan.query(for:$0) }
                let request = try JevRequest(goal: goal, observation: o, apps: desktop.apps, history: history,
                    preparedTexts:preparedTexts,languageAvailable:language != nil && languageCalls < 3,objective:progress?.plan.current,searchQueries:progress?.plan.current?.objective == .findContent ? (searchQuery.map { [$0] } ?? []) : [])
                onEvent(SessionEvent(.deciding,"Choosing the next action…"))
                try check(run, deadline: deadline)
                let t = MonotonicTime.now
                metrics.count("jev_requests"); metrics.count("jev_request_bytes",by:request.body.count)
                if request.mode == .visual { metrics.count("screenshots_sent") }
                let response = try await decider.decide(request); try check(run, deadline: deadline)
                metrics.add("jev_ms",milliseconds:(MonotonicTime.now-t)*1000)
                metrics.count("jev_input_tokens",by:response.usage?.input_tokens ?? 0)
                metrics.estimatedCostUSD += response.usage?.estimatedCostUSD ?? 0
                var action: Action
                do { action = try request.action(from: response, observation: o) }
                catch is DecisionUncertainty where language != nil && languageCalls < 3 {
                    action = Action(.requestLanguage,label:"Resolve the uncertain next step")
                }
                catch is LanguageNeeded where language != nil && languageCalls < 3 {
                    action = Action(.requestLanguage,label:"Prepare the exact insertion text")
                }
                var event = SessionEvent(.deciding,action.label)
                event.timings = o.timings; event.timings["jev_ms"] = (MonotonicTime.now-t)*1000
                event.tokens = response.usage?.input_tokens ?? 0; event.cost = response.usage?.estimatedCostUSD ?? 0
                onEvent(event)
                if action.operation == .requestLanguage || (action.operation == .clarify && language != nil && languageCalls < 3) {
                    guard let language, languageCalls < 3 else { throw VoiceError("Language assistance limit reached. Please give a smaller command.") }
                    languageCalls += 1
                    onEvent(SessionEvent(.assisting,"Getting help with the next step…")); try check(run,deadline:deadline)
                    let help = LanguageRequest(goal:goal,mode:.nextAction,observation:o,apps:desktop.apps,
                        history:history,includeScreen:languageScreenContext,preparedTexts:preparedTexts)
                    let languageStart = MonotonicTime.now
                    metrics.count("language_requests")
                    if languageScreenContext && !o.jpeg.isEmpty { metrics.count("screenshots_sent") }
                    let reply = try await language.assist(help);
                    metrics.add("language_model_ms",milliseconds:(MonotonicTime.now-languageStart)*1000); try check(run,deadline:deadline)
                    try reply.validate(for:help)
                    switch reply.kind {
                    case .text:
                        preparedTexts = [reply.text!]; previous = nil; previousAction = nil
                        continue
                    case .action: action = try reply.action!.resolve(for:help)
                    case .clarify: throw VoiceError(reply.message.isEmpty ? "Please clarify the requested action." : reply.message)
                    }
                }
                if action.operation == .requestVision {
                    guard !visionRequested else { throw VoiceError("Visual context is still insufficient. Please clarify the target.") }
                    visionRequested = true; preference = .visual; previous = nil; previousAction = nil; continue
                }
                if progress?.plan.current?.objective == .openNewest, [.click,.visualClick,.openURL].contains(action.operation) {
                    guard let query = searchQuery,
                          let selected = BrowserSelection.newest(query:query,controls:o.controls), action.operation == .click, selected.id == action.target,
                          let destination = selected.destination else {
                        throw VoiceError("The newest matching result cannot be determined from the visible dated results. No result was opened.")
                    }
                    newestDestination = destination
                }
                DebugLog.shared.value("action.proposed",action,fields:["run_id":run.uuidString,"observation_id":o.id.uuidString])
                if action.operation == .done {
                    guard try await desktop.isFresh(o,for:action) else { continue }
                    try check(run, deadline: deadline)
                    if let step = progress?.plan.current {
                        guard TaskCompletionVerifier.verifies(step,in:o,apps:desktop.apps,history:history,newestDestination:newestDestination,searchBaseline:searchBaseline) else {
                            throw VoiceError("The objective's outcome could not be verified: \(step.successCondition)")
                        }
                        progress?.advance(); searchBaseline = nil; newestDestination = nil
                        if progress?.plan.complete != true { previous = nil; previousAction = nil; visionRequested = false; preference = .automatic; continue }
                    }
                    metrics.success = true; metrics.outcome = "verified"
                    onEvent(SessionEvent(.completed,"The requested goal was verified.")); return
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
                if ActionSafety.requiresConfirmation(action,observation:o) {
                    metrics.count("confirmations")
                    guard let expiry = try await confirm(action, observation:o, run: run, deadline: deadline) else { throw VoiceError("Action cancelled or confirmation expired.") }
                    consentDeadline = expiry
                }
                try check(run, deadline: deadline)
                let freshnessStart = MonotonicTime.now
                let fresh = try await desktop.isFresh(o,for:action)
                metrics.add("freshness_check_ms",milliseconds:(MonotonicTime.now-freshnessStart)*1000)
                guard fresh else {
                    stale += 1; metrics.count("stale_rejections"); previous = nil; previousAction = nil
                    guard stale < 3 else { throw VoiceError("The window keeps changing. I stopped before acting on an outdated target.") }
                    continue
                }
                try check(run, deadline: deadline)
                onEvent(SessionEvent(.executing,action.label))
                try check(run, deadline: deadline)
                guard clock() < consentDeadline else { throw VoiceError("Confirmation expired while checking the target. Please repeat the command.") }
                let actionStart = MonotonicTime.now
                if progress?.plan.current?.objective == .findContent,
                   action.operation == .click || action.shortcut == .enter {
                    searchBaseline = TaskCompletionVerifier.publicEvidence(o)
                }
                if metrics.counts["actions",default:0] == 0 { metrics.timings["command_to_first_action_ms"] = (clock()-started)*1000 }
                try await desktop.execute(action, observed: o); metrics.count("actions"); try check(run, deadline: deadline)
                var executed = SessionEvent(.executing,action.label)
                executed.timings["action_ms"] = (MonotonicTime.now-actionStart)*1000
                metrics.add("action_ms",milliseconds:executed.timings["action_ms"]!)
                if attempts.isEmpty { executed.timings["command_to_first_action_ms"] = metrics.timings["command_to_first_action_ms"] }
                onEvent(executed)
                attempts.append((o,action.fingerprint)); previous = o; previousAction = action
                let waitStart = MonotonicTime.now
                try await desktop.waitForChange(after:o,action:action); try check(run,deadline:deadline)
                metrics.add("post_action_wait_ms",milliseconds:(MonotonicTime.now-waitStart)*1000)
            }
            throw VoiceError("Step limit reached. Please give a smaller command.")
        } catch {
            metrics.outcome = error is CancellationError ? "cancelled" : "failed"
            metrics.failureCode = error is CancellationError ? "cancelled" : "execution_or_verification_failed"
            if metricsRunID == run { progress?.block(error.localizedDescription) }
            throw error
        }
    }
}
