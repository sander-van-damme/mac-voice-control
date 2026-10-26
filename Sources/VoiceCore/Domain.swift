import Foundation

public struct VoiceError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public struct Rect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
    public var center: Point { Point(x + width / 2, y + height / 2) }
    public func contains(_ p: Point) -> Bool { valid && p.x >= x && p.y >= y && p.x <= x + width && p.y <= y + height }
    public func near(_ r: Rect, tolerance: Double = 2) -> Bool {
        zip([x,y,width,height], [r.x,r.y,r.width,r.height]).allSatisfy { abs($0 - $1) <= tolerance }
    }
}

public struct Box: Codable, Equatable, Sendable {
    public let top: Double, bottom: Double, left: Double, right: Double
    public init(top: Double, bottom: Double, left: Double, right: Double) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }
    public var valid: Bool {
        [top,bottom,left,right].allSatisfy { $0.isFinite && (0...1).contains($0) } && left < right && top < bottom
    }
}

/// Image pixels and desktop points deliberately have separate coordinate spaces.
public struct ImageGeometry: Codable, Equatable, Sendable {
    public let pixelWidth: Int, pixelHeight: Int
    public let content: Rect
    public let desktopCrop: Rect
    public init(pixelWidth: Int, pixelHeight: Int, content: Rect, desktopCrop: Rect) {
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.content = content; self.desktopCrop = desktopCrop
    }
    public static func fitted(crop: Rect, maxSide: Int = 1280) throws -> ImageGeometry {
        guard crop.valid, (280...1568).contains(maxSide) else { throw VoiceError("Invalid capture geometry.") }
        let scale = min(1, Double(maxSide) / max(crop.width, crop.height))
        let w = max(1, Int((crop.width * scale).rounded())), h = max(1, Int((crop.height * scale).rounded()))
        let pw = max(280,w), ph = max(280,h)
        return ImageGeometry(pixelWidth: pw, pixelHeight: ph,
            content: Rect(Double(pw-w)/2, Double(ph-h)/2, Double(w), Double(h)), desktopCrop: crop)
    }
    public func desktopPoint(for box: Box) throws -> Point {
        guard box.valid, content.valid, desktopCrop.valid else { throw VoiceError("Invalid visual target.") }
        let a = Point(box.left * Double(pixelWidth), box.top * Double(pixelHeight))
        let b = Point(box.right * Double(pixelWidth), box.bottom * Double(pixelHeight))
        guard content.contains(a), content.contains(b), b.x - a.x >= 2, b.y - a.y >= 2 else {
            throw VoiceError("The visual target is too small or outside the captured screen.")
        }
        let px = (a.x + b.x)/2, py = (a.y + b.y)/2
        return Point(desktopCrop.x + (px-content.x)/content.width * desktopCrop.width,
                     desktopCrop.y + (py-content.y)/content.height * desktopCrop.height)
    }
}

public struct Control: Codable, Equatable, Sendable {
    public let id: String, role: String, label: String
    public let frame: Rect
    public let enabled: Bool, canPress: Bool, canFocus: Bool, secure: Bool
    public init(id: String, role: String, label: String, frame: Rect, enabled: Bool = true,
                canPress: Bool = false, canFocus: Bool = false, secure: Bool = false) {
        self.id = id; self.role = role; self.label = secure ? "[secure]" : String(label.prefix(120))
        self.frame = frame; self.enabled = enabled; self.canPress = canPress; self.canFocus = canFocus; self.secure = secure
    }
    public static func normalized(_ controls: [Control], limit: Int = 60) -> [Control] {
        var seen = Set<String>()
        return Array(controls.filter { !$0.secure && $0.frame.valid && seen.insert($0.id).inserted }.prefix(limit))
    }
}

public struct AppCandidate: Codable, Equatable, Sendable {
    public let id: String, name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct Observation: Sendable {
    public var id = UUID()
    public var acquiredAt = ProcessInfo.processInfo.systemUptime
    public let pid: Int32, app: String, window: Rect
    public let controls: [Control], focusedID: String?, secureFocus: Bool, accessibilityIncomplete: Bool
    public let geometry: ImageGeometry, jpeg: Data, signature: [UInt8]
    public var timings: [String: Double] = [:]
    public init(pid: Int32, app: String, window: Rect, controls: [Control], focusedID: String? = nil,
                secureFocus: Bool = false, accessibilityIncomplete: Bool = false, geometry: ImageGeometry,
                jpeg: Data, signature: [UInt8]) {
        self.pid = pid; self.app = app; self.window = window; self.controls = Control.normalized(controls)
        self.focusedID = focusedID; self.secureFocus = secureFocus; self.accessibilityIncomplete = accessibilityIncomplete
        self.geometry = geometry; self.jpeg = jpeg; self.signature = signature
    }
    public func sameScene(as other: Observation) -> Bool {
        guard pid == other.pid, window.near(other.window), signature.count == other.signature.count,
              !signature.isEmpty else { return false }
        let differences = zip(signature,other.signature).map { abs(Int($0)-Int($1)) }
        let changed = differences.filter { $0 > 12 }.count
        return changed <= max(1, signature.count/100) && differences.reduce(0,+) < signature.count * 2
    }
}

public enum Operation: String, Codable, CaseIterable, Sendable {
    case click, visualClick, focus, typeText, shortcut, scroll, openApp, openURL, openDownloads, wait, done, clarify
}
public enum Shortcut: String, Codable, CaseIterable, Sendable {
    case newTab, previousTab, nextTab, back, forward, addressBar, enter, escape, closeTab
}
public struct Action: Equatable, Sendable {
    public let operation: Operation
    public var target: String? = nil
    public var text: String? = nil
    public var shortcut: Shortcut? = nil
    public var scroll: Int = 0
    public var point: Point? = nil
    public var sensitive = false
    public var label: String
    public init(_ operation: Operation, label: String) { self.operation = operation; self.label = label }
    public var fingerprint: String { "\(operation.rawValue)|\(target ?? "")|\(text ?? "")|\(shortcut?.rawValue ?? "")|\(scroll)|\(point?.x ?? 0),\(point?.y ?? 0)" }
    public var requiresConfirmation: Bool {
        sensitive || operation == .visualClick || shortcut == .enter || shortcut == .closeTab ||
        ["send","delete","remove","share","pay","purchase","submit","publish","verzend","verstuur","verwijder","deel","betalen","kopen","publiceer"].contains { label.lowercased().contains($0) }
    }
}

public struct HistoryEntry: Codable, Sendable {
    public let action: String, outcome: String
    public init(action: String, outcome: String) { self.action = action; self.outcome = outcome }
}
