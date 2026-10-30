import Foundation

public enum CommandRoute: Equatable, Sendable {
    case direct([Action]), goal, visual, writing
}

/// Whole-command grammar: uncertain or additional clauses always retain the full goal.
public enum CommandRouter {
    public static func route(_ original: String, apps: [AppCandidate]) -> CommandRoute {
        let text = normalize(original)
        guard !text.isEmpty, original.count <= 1000 else { return .goal }
        if LanguageRouting.canGenerate(original) { return .writing }
        if let payload = capture(#"^(?:dictate|dicteer)\s+(.+)$"#, original) {
            var a = Action(.typeText,label:"Insert literal text"); a.text = payload
            return .direct([a])
        }
        if let rawPayload = capture(#"^(?:type|typ)\s+(.+)$"#, original) {
            var payload = rawPayload
            if ["\"","'","“"].contains(String(rawPayload.prefix(1))) {
                guard let quoted = capture(#"^[\"'“]([^\"'”]+)[\"'”](?:\s+(?:in|into)\s+(?:(?:this|the current|the|dit|het huidige|het)\s+)?(?:text field|field|tekstveld|veld))?[.!]?$"#,rawPayload) else { return .goal }
                payload = quoted
            } else if rawPayload.range(of:#"(?i)\s+(?:in|into)\s+"#,options:.regularExpression) != nil { return .goal }
            // Target is resolved only against the live, safe, already focused field.
            var a = Action(.typeText,label:"Insert literal text"); a.text = payload
            return .direct([a])
        }
        let clauses = TaskPlanner.clauses(original)
        if clauses.count == 2,
           let a = direct(clauses[0], apps:apps), a.operation == .openApp,
           let b = direct(clauses[1], apps:apps), b.operation == .openURL,
           let app = apps.first(where: { $0.id == a.target }),
           ["chrome","safari","firefox","edge","brave"].contains(where: { app.name.lowercased().contains($0) }) {
            return .direct([a,b])
        }
        if clauses.count == 1, let action = direct(original,apps:apps) { return .direct([action]) }
        if text.range(of:#"\b(green|groene|icon|icoon|top right|rechtsboven|second|tweede)\b"#,options:.regularExpression) != nil { return .visual }
        return .goal
    }
    public static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator:" ")
            .trimmingCharacters(in:CharacterSet(charactersIn:" .,!?:;"))
    }
    static func capture(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern:pattern,options:.caseInsensitive),
              let m = re.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),
              let r = Range(m.range(at:1),in:text) else { return nil }
        return String(text[r])
    }
    private static func direct(_ original: String, apps: [AppCandidate]) -> Action? {
        let text = normalize(original)
        if let rawTarget = capture(#"^(?:open|launch|activate|start|go to|ga naar)\s+(?:the |de |het )?(.+)$"#,original.trimmingCharacters(in:.whitespacesAndNewlines)) {
            let target = normalize(rawTarget)
            if ["downloads","downloads folder","map downloads"].contains(target) { return Action(.openDownloads,label:"Open Downloads") }
            let named = apps.filter { app in
                normalize(app.name) == target || (app.mentioned(in:target) &&
                    ["chrome","finder","safari","firefox","edge","brave"].contains(target))
            }
            if named.count == 1 { var a = Action(.openApp,label:"Open \(named[0].name)"); a.target = named[0].id; return a }
            let address = rawTarget.trimmingCharacters(in:CharacterSet(charactersIn:" .,!?;"))
            let value = address.lowercased().hasPrefix("https://") || address.lowercased().hasPrefix("http://") ? address : "https://"+address
            if !target.contains(where: \.isWhitespace), target.contains("."), Candidates.safeURL(value) {
                var a = Action(.openURL,label:"Open \(value)"); a.text = value; return a
            }
        }
        if let direction = capture(#"^(?:scroll|scrol)\s+(down|up|omlaag|omhoog)$"#,text) {
            var a = Action(.scroll,label:"Scroll \(direction)"); a.scroll = ["down","omlaag"].contains(direction) ? -5 : 5; return a
        }
        let grammar: [(String,Shortcut)] = [
            (#"^(?:open|create|maak|openen)?\s*(?:(?:a|een) )?(?:new tab|nieuw tabblad|nieuwe tab)$"#,.newTab),
            (#"^(?:close|sluit) (?:the |het |de )?(?:current |huidige )?(?:tab|tabblad)$"#,.closeTab),
            (#"^(?:(?:switch|go|ga|wissel) (?:to |naar )?)?(?:the |het |de )?(?:previous tab|vorige tab|vorige tabblad)$"#,.previousTab),
            (#"^(?:(?:switch|go|ga|wissel) (?:to |naar )?)?(?:the |het |de )?(?:next tab|volgende tab|volgende tabblad)$"#,.nextTab),
            (#"^(?:go back|back|ga terug|terug)$"#,.back), (#"^(?:go forward|forward|ga vooruit|vooruit)$"#,.forward)]
        for (pattern,key) in grammar where text.range(of:pattern,options:.regularExpression) != nil {
            var a = Action(.shortcut,label:"Key: \(key.rawValue)"); a.shortcut = key; return a
        }
        return nil
    }
}

public struct DirectResult: Sendable {
    public let verified: Bool
    public let dispatchedAt: TimeInterval?
    public init(verified: Bool, dispatchedAt: TimeInterval? = nil) { self.verified = verified; self.dispatchedAt = dispatchedAt }
}
@MainActor public protocol DirectCommandExecuting {
    func executeDirect(_ action: Action) async throws -> DirectResult
}
