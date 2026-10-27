import Foundation

// Adapted from savka777/jev-use, MIT, b22e568. See THIRD_PARTY_NOTICES.md.
public enum WakePhrase {
    public static func command(in utterance: String, after phrase: String = "hey jev") -> String? {
        func words(_ text: String) -> [(String, Range<String.Index>)] {
            var result: [(String, Range<String.Index>)] = [], start: String.Index?
            for index in text.indices {
                if text[index].isLetter || text[index].isNumber { if start == nil { start = index } }
                else if let beginning = start {
                    result.append((String(text[beginning..<index]).lowercased(), beginning..<index)); start = nil
                }
            }
            if let start { result.append((String(text[start...]).lowercased(), start..<text.endIndex)) }
            return result
        }
        let expected = words(phrase), spoken = words(utterance)
        guard !expected.isEmpty, spoken.count >= expected.count else { return nil }
        let e = expected.map { $0.0 }, s = spoken.prefix(expected.count).map { $0.0 }
        guard e == s || (e == ["hey","jev"] && s == ["hey","jeff"]) else { return nil }
        return String(utterance[spoken[expected.count-1].1.upperBound...].drop(while: {
            $0.isWhitespace || ",.:;!?—–-".contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum RoutedInput: Equatable, Sendable {
    case ignore, stop, confirm, cancel, command(String), dictation(String), correction(String)
}
public enum InputRouter {
    static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
    public static func isStop(_ text: String) -> Bool {
        ["stop","stop now","stop nu","cancel","cancel that","annuleer","annuleren","stop jev"].contains(normalized(text))
    }
    public static func route(_ text: String, final: Bool, confirmationPending: Bool = false,
                             correctionAllowed: Bool = false) -> RoutedInput {
        // Partials can only remove authority, never authorize an action.
        if isStop(text) { return .stop }
        guard final else { return .ignore }
        let raw = WakePhrase.command(in: text) ?? text
        let lower = normalized(raw)
        if confirmationPending {
            if ["confirm","yes confirm","bevestig","ja bevestig"].contains(lower) { return .confirm }
            if ["no","nee","cancel","annuleer"].contains(lower) { return .cancel }
        }
        if (correctionAllowed || WakePhrase.command(in:text) != nil) &&
            (lower.hasPrefix("nee,") || lower.hasPrefix("nee ") || lower.hasPrefix("actually ") || lower.hasPrefix("actually,") || lower.hasPrefix("no, ")) {
            return .correction(String(raw.prefix(1000)))
        }
        guard WakePhrase.command(in: text) != nil, !lower.isEmpty else { return .ignore }
        if isStop(raw) { return .stop }
        for prefix in ["dictate ", "dicteer "] where lower.hasPrefix(prefix) {
            return .dictation(String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .command(String(raw.prefix(1000)))
    }
}

public struct Candidates: Sendable {
    public let controls: [Control], apps: [AppCandidate], texts: [String], urls: [String]
    public init(goal: String, observation: Observation, apps: [AppCandidate]) {
        controls = observation.controls.filter { $0.enabled && !$0.secure }
        // Goal matches first, then running/common apps; deterministic tie order.
        self.apps = Array(apps.sorted {
            let a = $0.mentioned(in:goal), b = $1.mentioned(in:goal)
            return a != b ? a : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.prefix(40))
        texts = Self.spans(goal)
        var found: [String] = []
        let pattern = #"(?:https?://)?(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?:/[^\s\"']*)?"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for m in regex.matches(in: goal, range: NSRange(goal.startIndex..., in: goal)) {
                if let range = Range(m.range, in: goal) {
                    let value = String(goal[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                    found.append(value.hasPrefix("http") ? value : "https://" + value)
                }
            }
        }
        for (name,url) in [("github","https://github.com"),("google","https://www.google.com"),("gmail","https://mail.google.com")] where goal.localizedCaseInsensitiveContains(name) { found.append(url) }
        urls = Array(Self.unique(found).filter(Self.safeURL).prefix(12))
    }
    public static func safeURL(_ value: String) -> Bool {
        guard let u = URLComponents(string: value), ["https","http"].contains(u.scheme?.lowercased() ?? ""),
              let host = u.host, !host.isEmpty, u.user == nil, u.password == nil else { return false }
        return !value.contains("\n") && !value.contains("\r")
    }
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>(); return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    public static func spans(_ goal: String) -> [String] {
        let bounded = String(goal.prefix(1000))
        var values: [String] = []
        let patterns = [#"[\"“]([^\"”]+)[\"”]"#, #"'([^']+)'"#,
                        #"(?i)(?:type|typ|schrijf|search for|search|zoek naar|zoek|dictate|dicteer)\s+(.+)"#]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: bounded, range: NSRange(bounded.startIndex..., in: bounded)) {
                if let r = Range(m.range(at: 1), in: bounded) { values.append(String(bounded[r])) }
            }
        }
        // A following action clause isn't part of a search/typing payload.
        let delimiter = #"(?i)\s+(?:(?:and|en|then|daarna)\s+(?:open|click|klik|go|ga|scroll|select|selecteer)|(?:in|into)\s+(?:the|het|de)\s+(?:text|tekst|field|veld))\b"#
        if let re = try? NSRegularExpression(pattern:delimiter) {
            for value in values {
                if let match = re.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)),
                   let range = Range(match.range,in:value) { values.insert(String(value[..<range.lowerBound]),at:0) }
            }
        }
        let words = bounded.split(whereSeparator: \.isWhitespace).map(String.init)
        // Suffix spans let Jev choose a literal payload without a generative text helper.
        for i in 0..<min(words.count,20) { values.append(words[i...].joined(separator: " ")) }
        return Array(unique(values).prefix(24))
    }
}

/// Energy endpointing is deliberately isolated so a learned VAD can replace it.
public struct UtteranceSegmenter: Sendable {
    private var samples: [Float] = [], preRoll: [Float] = []
    private var silent = 0, voiced = 0
    private var discardingLongUtterance = false
    public var threshold: Float = 0.012
    public private(set) var discardedUtterances = 0
    public private(set) var completedTrailingSilence: TimeInterval = 0
    public init() {}
    public mutating func append(_ chunk: [Float]) -> [Float]? {
        guard !chunk.isEmpty else { return nil }
        let rms = sqrt(chunk.reduce(Float(0)) { $0 + $1*$1 } / Float(chunk.count))
        if discardingLongUtterance {
            silent = rms >= threshold ? 0 : silent + chunk.count
            if silent >= 12800 { discardingLongUtterance = false; silent = 0 }
            return nil
        }
        if rms >= threshold {
            if samples.isEmpty { samples = preRoll; preRoll.removeAll(keepingCapacity: true) }
            samples += chunk; voiced += chunk.count; silent = 0
        } else if !samples.isEmpty { samples += chunk; silent += chunk.count }
        else { preRoll += chunk; if preRoll.count > 3200 { preRoll.removeFirst(preRoll.count-3200) } }
        if samples.count >= 240_000 && silent < 12800 {
            // A length cap is not proof the speaker finished. Discard until silence,
            // instead of executing a truncated instruction as a final transcript.
            samples.removeAll(keepingCapacity:true); voiced = 0; silent = 0
            discardedUtterances += 1
            discardingLongUtterance = true
            return nil
        }
        if !samples.isEmpty && silent >= 12_800 {
            completedTrailingSilence = Double(silent)/16000
            let result = voiced >= 1600 ? samples : nil
            samples.removeAll(keepingCapacity: true); silent = 0; voiced = 0
            return result
        }
        return nil
    }
}
