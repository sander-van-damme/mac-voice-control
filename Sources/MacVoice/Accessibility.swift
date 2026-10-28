import AppKit
import ApplicationServices
import VoiceCore

struct AXSnapshot {
    let pid: pid_t
    let window: AXUIElement?
    let frame: Rect
    var visualWindow: VisibleWindow? = nil
    let controls: [Control], references: [String: AXUIElement]
    let focusedID: String?, secureFocus: Bool, secureRegions: [Rect], incomplete: Bool
}

/// AX is synchronous IPC. Keep bounded traversal off the UI thread.
final class AccessibilityReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacVoice.accessibility", qos: .userInitiated)
    private var enabledProcesses = Set<pid_t>()
    private var lastPoke: [pid_t: Date] = [:]
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    static func frame(_ element: AXUIElement) -> Rect? {
        guard let p = attribute(element,kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(element,kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p,to:AXValue.self),.cgPoint,&point),
              AXValueGetValue(unsafeBitCast(s,to:AXValue.self),.cgSize,&size) else { return nil }
        let r = Rect(point.x,point.y,size.width,size.height); return r.valid ? r : nil
    }
    static func secure(_ element: AXUIElement) -> Bool {
        let role = attribute(element,kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element,kAXSubroleAttribute) as? String ?? ""
        return role.localizedCaseInsensitiveContains("secure") || subrole.localizedCaseInsensitiveContains("secure") ||
            (attribute(element,"AXProtectedContent") as? Bool == true)
    }
    static func label(_ element: AXUIElement) -> String {
        guard !secure(element) else { return "[secure]" }
        for key in [kAXTitleAttribute,kAXDescriptionAttribute,kAXHelpAttribute,kAXPlaceholderValueAttribute] {
            if let value = attribute(element,key) as? String, !value.isEmpty { return String(value.prefix(120)) }
        }
        // Never use AXValue as a fallback label: it can leak a filled secret.
        return ""
    }
    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element,&names) == .success else { return [] }
        return names as? [String] ?? []
    }
    static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.08)
        return element(attribute(app,kAXFocusedWindowAttribute)) ?? element(attribute(app,kAXMainWindowAttribute))
    }
    static func focusedElement(_ pid: pid_t) -> AXUIElement? {
        element(attribute(AXUIElementCreateApplication(pid),kAXFocusedUIElementAttribute))
    }
    func read(pid: pid_t, chromium: Bool, fallback: VisibleWindow? = nil) async throws -> AXSnapshot {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.collect(pid: pid, chromium: chromium, fallback:fallback) }) }
        }
    }
    private func collect(pid: pid_t, chromium: Bool, fallback: VisibleWindow?) throws -> AXSnapshot {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system,0.08)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.08)
        if chromium && (!enabledProcesses.contains(pid) || Date().timeIntervalSince(lastPoke[pid] ?? .distantPast) > 5) {
            // Only re-poke when the prior traversal had no web area (lastPoke is refreshed below).
            AXUIElementSetAttributeValue(app,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue)
            AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue)
            enabledProcesses.insert(pid); lastPoke[pid] = Date()
        }
        let focused = Self.focusedElement(pid)
        let secureFocus = focused.map(Self.secure) ?? false
        guard let window = Self.focusedWindow(pid), let frame = Self.frame(window) else {
            guard let fallback = fallback ?? WindowCatalog.foreground(pid:pid,windows:WindowCatalog.current()),
                  fallback.pid == pid else {
                let bounds = CGDisplayBounds(CGMainDisplayID())
                return AXSnapshot(pid:pid,window:nil,frame:Rect(bounds.minX,bounds.minY,bounds.width,bounds.height),controls:[],references:[:],focusedID:nil,secureFocus:secureFocus,secureRegions:[],incomplete:true)
            }
            let regions = secureFocus ? focused.flatMap(Self.frame).map { [$0] } ?? [] : []
            return AXSnapshot(pid:pid,window:nil,frame:fallback.frame,visualWindow:fallback,
                controls:[],references:[:],focusedID:nil,secureFocus:secureFocus,secureRegions:regions,incomplete:true)
        }
        var nodes: [(AXUIElement,Int)] = [(window,0)], visited = Set<CFHashCode>()
        var controls: [Control] = [], refs: [String: AXUIElement] = [:], regions: [Rect] = []
        var focusedID: String?, webArea = false, count = 0, truncated = false
        let start = MonotonicTime.now
        while let (node,depth) = nodes.popLast(), count < 2000,
              MonotonicTime.now-start < 0.7 {
            guard depth < 24 else { truncated = true; continue }
            guard visited.insert(CFHash(node)).inserted else { continue }
            count += 1
            let role = Self.attribute(node,kAXRoleAttribute) as? String ?? ""
            if role == "AXWebArea" { webArea = true }
            if Self.secure(node) {
                if let r = Self.frame(node) { regions.append(r) }
                continue // Do not inspect secure labels, values, descendants, or descriptions.
            }
            let children = Self.attribute(node,kAXChildrenAttribute) as? [AXUIElement] ?? []
            if children.count > 200 { truncated = true }
            nodes.append(contentsOf: children.prefix(200).reversed().map { ($0,depth+1) })
            guard let rect = Self.frame(node), intersects(rect,frame) else { continue }
            let actions = Self.actions(node)
            let text = ["AXTextField","AXTextArea","AXComboBox","AXSearchField"].contains(role)
            let press = actions.contains(kAXPressAction)
            guard press || text || role == "AXStaticText" || role == "AXLink" else { continue }
            // Static text is supplementary evidence, not an executable target.
            let id = "e\(controls.count)"
            let control = Control(id:id,role:role,label:Self.label(node),frame:rect,
                enabled:Self.attribute(node,kAXEnabledAttribute) as? Bool ?? true,canPress:press,canFocus:text)
            controls.append(control); refs[id] = node
            if let focused, CFEqual(focused,node) { focusedID = id }
        }
        if webArea { lastPoke[pid] = Date() }
        // Always mask the focused secure field even when it fell beyond the walk budget.
        if secureFocus, let focused, let rect = Self.frame(focused) { regions.append(rect) }
        controls.sort { ($0.canPress || $0.canFocus) && !($1.canPress || $1.canFocus) }
        return AXSnapshot(pid:pid,window:window,frame:frame,controls:controls,references:refs,
            focusedID:focusedID,secureFocus:secureFocus,secureRegions:regions,
            incomplete:truncated || !nodes.isEmpty || (chromium && !webArea))
    }
    private func intersects(_ a: Rect, _ b: Rect) -> Bool {
        a.x < b.x+b.width && a.x+a.width > b.x && a.y < b.y+b.height && a.y+a.height > b.y
    }
}
