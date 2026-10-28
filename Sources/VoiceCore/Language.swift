import Foundation

public enum LanguageMode: String, Codable, Sendable { case prepareText, nextAction }

/// The helper sees a bounded snapshot. It has no OS tools, shell, or executor.
public struct LanguageRequest: Sendable {
    public let id: UUID
    public let goal: String
    public let mode: LanguageMode
    public let observation: Observation
    public let apps: [AppCandidate]
    public let history: [HistoryEntry]
    public let includeScreen: Bool
    public let preparedTexts: [String]
    public init(goal: String, mode: LanguageMode, observation: Observation, apps: [AppCandidate],
                history: [HistoryEntry], includeScreen: Bool, preparedTexts: [String] = []) {
        id = UUID(); self.goal = goal; self.mode = mode; self.observation = observation
        self.apps = Array(Candidates(goal:goal,observation:observation,apps:apps).apps)
        self.history = Array(history.suffix(6)); self.includeScreen = includeScreen
        self.preparedTexts = Array(preparedTexts.prefix(1))
    }
}

public protocol LanguageHelping: Sendable {
    func assist(_ request: LanguageRequest) async throws -> LanguageReply
}

public struct LanguageReply: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, action, clarify }
    public let requestID: UUID
    public let observationID: UUID
    public let kind: Kind
    public let text: String?
    public let action: LanguageAction?
    public let message: String
    public init(requestID: UUID, observationID: UUID, kind: Kind, text: String? = nil,
                action: LanguageAction? = nil, message: String = "") {
        self.requestID = requestID; self.observationID = observationID; self.kind = kind
        self.text = text; self.action = action; self.message = message
    }
    public static func decode(_ data: Data) throws -> LanguageReply {
        guard data.count <= 32_000 else { throw VoiceError("Language assistance returned too much data.") }
        do { return try JSONDecoder().decode(Self.self,from:data) }
        catch { throw VoiceError("Language assistance returned an invalid proposal. No action was taken.") }
    }
    public func validate(for request: LanguageRequest) throws {
        guard requestID == request.id, observationID == request.observation.id else {
            throw VoiceError("Language assistance belongs to an older request. No action was taken.")
        }
        guard message.count <= 500 else { throw VoiceError("Language assistance returned an oversized message.") }
        switch kind {
        case .text:
            guard action == nil, let text else { throw VoiceError("Missing prepared text.") }
            try InsertionSafety.validate(text)
            guard request.preparedTexts.isEmpty || request.preparedTexts.contains(text) else {
                throw VoiceError("The language helper changed text already prepared for this task.")
            }
            // Literal insertion remains literal. Only an explicit writing request permits new prose.
            let candidates = Candidates(goal:request.goal,observation:request.observation,apps:request.apps)
            guard LanguageRouting.canGenerate(request.goal) || request.goal.contains(text) || candidates.urls.contains(text) else {
                throw VoiceError("The prepared text does not match your words. Please dictate the exact text.")
            }
        case .action:
            guard request.mode == .nextAction, text == nil, action != nil else {
                throw VoiceError("Unexpected language action.")
            }
        case .clarify:
            guard action == nil, text == nil else { throw VoiceError("Invalid clarification proposal.") }
        }
    }
}

/// Wire proposals are converted to the same Action used by Jev, then checked by the goal loop.
public struct LanguageAction: Codable, Sendable {
    public let operation: Operation
    public let target: String?
    public let text: String?
    public let shortcut: Shortcut?
    public let point: Point?
    public let endPoint: Point?
    public let keys: [String]?
    public let scroll: Int?
    public init(operation: Operation, target: String? = nil, text: String? = nil,
                shortcut: Shortcut? = nil, scroll: Int? = nil, point: Point? = nil, endPoint: Point? = nil, keys: [String]? = nil) {
        self.operation = operation; self.target = target; self.text = text
        self.shortcut = shortcut; self.scroll = scroll; self.point = point; self.endPoint = endPoint; self.keys = keys
    }
    public func resolve(for request: LanguageRequest) throws -> Action {
        let o = request.observation
        guard !o.secureFocus else { throw VoiceError("Move focus away from secure fields.") }
        let named = request.apps.filter { $0.mentioned(in:request.goal) }
        if named.count == 1, !named[0].mentioned(in:o.app), ![.openApp,.wait].contains(operation) {
            throw VoiceError("The requested application is not in front. No action was taken.")
        }
        var result = Action(operation,label:operation.rawValue)
        switch operation {
        case .click, .focus, .typeText:
            guard request.includeScreen else { throw VoiceError("Enable screen context for help with desktop targets.") }
            guard let target, let control = o.controls.first(where:{$0.id == target}), control.enabled,
                  !control.secure, (operation == .click ? control.canPress : control.canFocus) else {
                throw VoiceError("The proposed control is not in the current observation.")
            }
            result.target = target; result.label = "\(operation.rawValue): \(control.label)"
            // An LLM cannot downgrade the uncertainty of a click or authorize a submission.
            result.sensitive = operation == .click
            if operation == .typeText {
                guard let text else { throw VoiceError("Missing insertion text.") }
                let reply = LanguageReply(requestID:request.id,observationID:o.id,kind:.text,text:text)
                try reply.validate(for:request)
                if o.focusedID != target { return Action(.focus,label:"Focus \(control.label)").targeting(target) }
                result.text = text; result.label = "Type ‘\(text.prefix(80))’ into \(control.label)"
            }
        case .openApp:
            guard let target, request.apps.contains(where:{$0.id == target}),
                  named.count != 1 || named[0].id == target else { throw VoiceError("The proposed application does not match your request.") }
            result.target = target; result.label = "Open \(request.apps.first(where:{$0.id == target})!.name)"
        case .openURL:
            guard let text, Candidates.safeURL(text),
                  Candidates(goal:request.goal,observation:o,apps:request.apps).urls.contains(text) else {
                throw VoiceError("The proposed URL was not supplied in your command.")
            }
            result.text = text; result.label = "Open \(text)"
        case .shortcut:
            guard let shortcut else { throw VoiceError("Missing shortcut.") }
            result.shortcut = shortcut; result.label = "Key: \(shortcut.rawValue)"
        case .scroll:
            guard let scroll, scroll != 0, abs(scroll) <= 25 else { throw VoiceError("Invalid proposed scroll.") }
            result.scroll = scroll
        case .wait, .openDownloads: break
        case .keyCombo:
            guard let keys, !keys.isEmpty, keys.count <= 5 else { throw VoiceError("Invalid keyboard combination.") }
            result.keys = keys
        case .visualClick, .rightClick, .doubleClick, .drag, .movePointer:
            guard request.includeScreen, let point, o.geometry.desktopCrop.contains(point) else { throw VoiceError("Visual target is outside the observed display.") }
            result.point = point; result.endPoint = endPoint
            if operation == .drag { guard let endPoint, o.geometry.desktopCrop.contains(endPoint) else { throw VoiceError("Invalid drag destination.") } }
        case .done:
            guard request.includeScreen, !request.history.isEmpty else { throw VoiceError("Completion requires observed action history and screen context.") }
        case .clarify, .requestLanguage:
            throw VoiceError("That operation must be resolved by Jev or the user.")
        }
        return result
    }
}

private extension Action {
    func targeting(_ id: String) -> Action { var value = self; value.target = id; return value }
}

public enum LanguageRouting {
    public static func canGenerate(_ goal: String) -> Bool {
        let value = goal.lowercased()
        if ["type ","typ ","enter ","dictate ","dicteer "].contains(where:value.hasPrefix) { return false }
        let unquoted = value.replacingOccurrences(of:#"[\"“][^\"”]*[\"”]|'[^']*'"#,with:"",options:.regularExpression)
        let pattern = #"\b(write|compose|draft|rewrite|rephrase|summarize|summarise|translate|schrijf|herschrijf|formuleer|vertaal|samenvatten)\b"#
        return unquoted.range(of:pattern,options:.regularExpression) != nil
    }
}
