import Foundation

public enum TextIntent: String, Codable, Sendable { case literal, searchQuery, formValue, generatedWriting, transformation }
public struct TextPayload: Codable, Equatable, Sendable {
    public let value: String
    public let intent: TextIntent
    public let provenance: String
    public init(value: String, intent: TextIntent, provenance: String) {
        self.value = value; self.intent = intent; self.provenance = provenance
    }
}
public enum TextTargetSafety {
    public static func validate(_ payload: TextPayload, target: Control) throws {
        try InsertionSafety.validate(payload.value)
        guard target.canFocus, !target.secure, target.enabled else { throw VoiceError("No authorized editable field.") }
        if payload.intent == .searchQuery {
            guard ["searchbox","AXSearchField"].contains(target.role) ||
                    target.label.range(of:#"(?i)\b(search|zoek|zoeken)\b"#,options:.regularExpression) != nil else {
                throw VoiceError("Derived search text can only be inserted into an observed search field.")
            }
        }
    }
}
