import Foundation

public enum TaskState: String, Codable, Sendable { case pending, completed, blocked }
public enum TaskObjective: String, Codable, Sendable { case openApp, navigate, findContent, openNewest, goal }
public struct TaskStep: Codable, Equatable, Sendable {
    public let id: Int, objective: TaskObjective, instruction: String, successCondition: String
    public let target: String?
    public var state: TaskState = .pending
}
public struct TaskPlan: Codable, Equatable, Sendable {
    public let originalGoal: String
    public var steps: [TaskStep]
    public var current: TaskStep? { steps.first { $0.state == .pending } }
    public func query(for step: TaskStep) -> String? {
        steps.last { $0.objective == .findContent && $0.id <= step.id }?.target
    }
    public var complete: Bool { !steps.isEmpty && steps.allSatisfy { $0.state == .completed } }
}

/// Objectives contain no selectors, coordinates or invented UI objects. Unknown clauses stay intact.
public struct TaskPlanner: Sendable {
    public init() {}
    public func plan(_ goal: String, apps: [AppCandidate]) -> TaskPlan {
        // Corrections retain their original authority/context rather than splitting historical clauses.
        let parts = goal.hasPrefix("User correction (takes priority):") ? [goal] : Self.clauses(goal)
        let steps = parts.enumerated().map { index, clause -> TaskStep in
            var kind = TaskObjective.goal, target: String?, condition = "Current state independently supports every requirement of this objective"
            if case let .direct(actions) = CommandRouter.route(clause,apps:apps), let a = actions.first {
                if a.operation == .openApp { kind = .openApp; target = a.target; condition = "Requested application is foreground" }
                if a.operation == .openURL { kind = .navigate; target = a.text; condition = "Requested URL is observed in the active browser document" }
            }
            let normalized = CommandRouter.normalize(clause)
            if normalized.range(of:#"\b(newest|latest|nieuwste|recentste)\b"#,options:.regularExpression) != nil,
               normalized.range(of:#"\b(open|select|selecteer)\b"#,options:.regularExpression) != nil {
                kind = .openNewest; condition = "Dated matching results were compared and the selected destination is now open"
            } else if let query = Self.searchQuery(clause) {
                kind = .findContent; target = query; condition = "Relevant content is observed after search/navigation; typed text alone is insufficient"
            }
            return TaskStep(id:index,objective:kind,instruction:clause,successCondition:condition,target:target)
        }
        return TaskPlan(originalGoal:goal,steps:steps)
    }
    public static func clauses(_ goal: String) -> [String] {
        // Never split inside quotes or a URL. Only a conjunction followed by an action verb is a boundary.
        let pattern = #"(?:,\s*|\s+(?:and then|and|then|en dan|en|daarna)\s+)(?=(?:open|go|ga|find|zoek|search|click|klik|select|selecteer|scroll|write|schrijf|fill|vul)\b)"#
        guard let re = try? NSRegularExpression(pattern:pattern,options:.caseInsensitive) else { return [goal] }
        var parts: [String] = [], start = goal.startIndex
        for m in re.matches(in:goal,range:NSRange(goal.startIndex...,in:goal)) {
            guard let r = Range(m.range,in:goal) else { continue }
            let prefix = goal[..<r.lowerBound]
            let straight = prefix.filter { $0 == "\"" }.count
            let single = prefix.filter { $0 == "'" }.count
            guard straight % 2 == 0, single % 2 == 0, prefix.filter({ $0 == "“" }).count == prefix.filter({ $0 == "”" }).count else { continue }
            parts.append(String(goal[start..<r.lowerBound]).trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:",")))); start = r.upperBound
        }
        parts.append(String(goal[start...]).trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:","))))
        return parts.count <= 8 ? parts.filter { !$0.isEmpty } : [goal]
    }
    public static func searchQuery(_ clause: String) -> String? {
        guard var value = CommandRouter.capture(#"^(?:search(?:\s+(?:this website|this site|the website))?\s+for|search|find|zoek naar|zoek|vind)\s+(.+)$"#,clause) else { return nil }
        value = value.replacingOccurrences(of:#"(?i)\s+(?:on this (?:website|site)|op deze (?:website|site))\.?$"#,with:"",options:.regularExpression)
        value = value.replacingOccurrences(of:#"(?i)^(?:the |de |het )"#,with:"",options:.regularExpression)
        value = value.replacingOccurrences(of:#"(?i)\s+(?:page|pagina)$"#,with:"",options:.regularExpression)
        value = value.trimmingCharacters(in:CharacterSet(charactersIn:" .,\"“”'"))
        guard !value.isEmpty, value.count <= 120, Self.clauses(value).count == 1,
              value.range(of:#"(?i)\b(password|wachtwoord|credit card|api key|token)\b"#,options:.regularExpression) == nil else { return nil }
        return value
    }
}

public enum TaskCompletionVerifier {
    public static func publicEvidence(_ o: Observation) -> String {
        o.controls.filter { !$0.canFocus }.map(\.label).joined(separator:" ")+" "+(o.browser?.text ?? "")
    }
    public static func verifies(_ step: TaskStep, in o: Observation, apps: [AppCandidate], history: [HistoryEntry], newestDestination: String? = nil, searchBaseline: String? = nil) -> Bool {
        switch step.objective {
        case .openApp: return apps.first { $0.id == step.target }?.mentioned(in:o.app) == true
        case .navigate:
            guard let url = o.browser?.url, let target = step.target,
                  URLComponents(string:target)?.query == nil, URLComponents(string:target)?.fragment == nil else { return false }
            return BrowserContext.canonicalURL(url) == BrowserContext.canonicalURL(target)
        case .findContent:
            guard let query = step.target, !history.isEmpty else { return false }
            let evidence = publicEvidence(o)
            if step.instruction.range(of:#"(?i)^(search|zoek)\b"#,options:.regularExpression) != nil {
                guard let searchBaseline, evidence != searchBaseline else { return false }
            }
            return query.split(whereSeparator: \.isWhitespace).allSatisfy { evidence.localizedCaseInsensitiveContains(String($0)) }
        case .openNewest:
            guard let destination = newestDestination, let current = o.browser?.url else { return false }
            return BrowserContext.canonicalURL(destination) == BrowserContext.canonicalURL(current)
        case .goal: return true // Jev's independent completion head + fresh scene remain required.
        }
    }
}

public struct TaskProgressTracker: Sendable {
    public private(set) var plan: TaskPlan
    public private(set) var blockedReason: String?
    public init(plan: TaskPlan) { self.plan = plan }
    public mutating func advance() {
        if let i = plan.steps.firstIndex(where: { $0.state == .pending }) { plan.steps[i].state = .completed }
    }
    public mutating func block(_ reason: String) {
        blockedReason = reason
        if let i = plan.steps.firstIndex(where: { $0.state == .pending }) { plan.steps[i].state = .blocked }
    }
}
