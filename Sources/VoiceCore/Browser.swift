import Foundation

public enum PerceptionSource: String, Codable, Sendable { case visual, accessibility, browser }
public enum ObservationPreference: Equatable, Sendable { case automatic, semantic, visual }

public struct BrowserContext: Codable, Equatable, Sendable {
    public let tabID: Int, documentID: String, revision: Int
    public let url: String, title: String, text: String
    public let hasUnsupportedContent: Bool
    public init(tabID: Int, documentID: String, revision: Int, url: String, title: String, text: String,
                hasUnsupportedContent: Bool = false) {
        self.tabID = tabID; self.documentID = documentID; self.revision = revision
        self.url = Self.canonicalURL(url); self.title = String(title.prefix(160)); self.text = String(text.prefix(6000))
        self.hasUnsupportedContent = hasUnsupportedContent
    }
    /// Strip query/fragment/userinfo from observations, never from authorized navigation payloads.
    public static func canonicalURL(_ value: String) -> String {
        guard var u = URLComponents(string:value), ["http","https"].contains(u.scheme?.lowercased() ?? ""),
              let host = u.host, !host.isEmpty else { return "" }
        u.user = nil; u.password = nil; u.query = nil; u.fragment = nil
        u.scheme = u.scheme?.lowercased(); u.host = host.lowercased()
        if u.path == "/" { u.path = "" }
        return u.string ?? ""
    }
}

public struct BrowserSnapshot: Codable, Sendable {
    public let context: BrowserContext
    public let controls: [Control]
    public let focusedID: String?
    public let secureFocus: Bool
    public init(context: BrowserContext, controls: [Control], focusedID: String? = nil, secureFocus: Bool = false) {
        self.context = context; self.controls = Control.normalized(controls); self.focusedID = focusedID; self.secureFocus = secureFocus
    }
}

/// Only code-owned commands cross the native messaging boundary. No script/selector field exists.
public struct BrowserCommand: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case observe, validate, act, cancel }
    public let id: UUID, runID: UUID, kind: Kind, expiresAt: TimeInterval
    public var connectionID: UUID?
    public var context: BrowserContext?
    public var action: Action?
    public init(runID: UUID, kind: Kind, context: BrowserContext? = nil, action: Action? = nil, lifetime: Double = 3) {
        id = UUID(); self.runID = runID; self.kind = kind; self.context = context; self.action = action
        expiresAt = Date().timeIntervalSince1970 + lifetime
    }
}
public struct BrowserReply: Codable, Sendable {
    public let id: UUID
    public let ok: Bool
    public let snapshot: BrowserSnapshot?
    public let error: String?
}

public enum BrowserSelection {
    /// Dates must be explicitly supplied by visible <time datetime> or visible ISO text, never inferred.
    public static func newest(query: String, controls: [Control]) -> Control? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = controls.filter { c in
            c.enabled && c.canPress && c.role == "link" &&
            !words.isEmpty && words.allSatisfy { (c.label+" "+(c.context ?? "")).lowercased().contains($0) }
        }
        guard !matches.isEmpty, matches.allSatisfy({ validDate($0.date) && $0.destination.map { !$0.isEmpty } == true }) else { return nil }
        let sorted = matches.sorted { $0.date! > $1.date! }
        guard sorted.count == 1 || sorted[0].date != sorted[1].date else { return nil }
        return sorted.first
    }
    private static func validDate(_ value: String?) -> Bool {
        guard let value, value.range(of:#"^\d{4}-\d{2}-\d{2}$"#,options:.regularExpression) != nil else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
        formatter.calendar = Calendar(identifier:.gregorian); formatter.timeZone = TimeZone(secondsFromGMT:0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from:value).map { formatter.string(from:$0) == value } == true
    }
}
