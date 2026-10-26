import AppKit
import ApplicationServices
import Carbon
import VoiceCore

@MainActor final class MacDesktop: DesktopControlling {
    private let reader = AccessibilityReader()
    private var snapshots: [UUID: AXSnapshot] = [:]
    private var appURLs: [String: URL] = [:]
    private(set) var apps: [AppCandidate] = []
    init() { refreshApps() }
    func refreshApps() {
        var found: [String: AppCandidate] = [:]
        for root in ["/Applications","/System/Applications","/System/Library/CoreServices", NSHomeDirectory()+"/Applications"] {
            guard let iterator = FileManager.default.enumerator(at:URL(fileURLWithPath:root),includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { continue }
            for case let url as URL in iterator where url.pathExtension == "app" {
                guard let bundle = Bundle(url:url), let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
                let name = bundle.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
                found[id] = AppCandidate(id:id,name:name); appURLs[id] = url
            }
        }
        apps = found.values.sorted { $0.name < $1.name }
    }
    func observe() async throws -> Observation {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw VoiceError("Enable Accessibility for Mac Voice Control in System Settings.") }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !["com.apple.loginwindow","com.apple.SecurityAgent"].contains(app.bundleIdentifier ?? "") else {
            throw VoiceError("Bring the application you want to control to the front.")
        }
        let t = ProcessInfo.processInfo.systemUptime
        let bundle = app.bundleIdentifier ?? ""
        let chromium = ["chrome","chromium","brave","edge","electron"].contains { bundle.lowercased().contains($0) }
        let ax = try await reader.read(pid:app.processIdentifier,chromium:chromium)
        try Task.checkCancellation()
        let axTime = (ProcessInfo.processInfo.systemUptime-t)*1000
        // Mask known secure regions, refuse secure focus, and require explicit consent
        // because an incomplete AX tree cannot identify every visually displayed secret.
        guard !IsSecureEventInputEnabled(), !ax.secureFocus else { throw VoiceError("A secure field has focus. Move focus away from passwords before continuing.") }
        let captureStart = ProcessInfo.processInfo.systemUptime
        let screen = try await ScreenCapture.capture(window:ax.frame,redactions:ax.secureRegions)
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let current = AccessibilityReader.focusedWindow(app.processIdentifier), CFEqual(current,ax.window),
              AccessibilityReader.frame(current)?.near(ax.frame) == true else { throw VoiceError("The foreground window changed during capture. Please try again.") }
        var o = Observation(pid:app.processIdentifier,app:app.localizedName ?? "Application",window:ax.frame,controls:ax.controls,
            focusedID:ax.focusedID,secureFocus:ax.secureFocus,accessibilityIncomplete:ax.incomplete,
            geometry:screen.geometry,jpeg:screen.jpeg,signature:screen.signature)
        o.timings = ["accessibility_ms":axTime,"capture_ms":(ProcessInfo.processInfo.systemUptime-captureStart)*1000]
        if snapshots.count > 3 { snapshots.removeAll() }
        snapshots[o.id] = ax
        return o
    }
    func isFresh(_ o: Observation, for action: Action) async throws -> Bool {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime-o.acquiredAt < 35,
              let ax = snapshots[o.id], basicGuard(o,ax:ax) else { return false }
        if action.operation == .wait { return true }
        if let id = action.target, [.click,.focus,.typeText].contains(action.operation) {
            guard let element = ax.references[id], let old = o.controls.first(where:{$0.id == id}),
                  !AccessibilityReader.secure(element), AccessibilityReader.frame(element)?.near(old.frame) == true,
                  AccessibilityReader.label(element) == old.label else { return false }
            if action.operation == .typeText {
                guard let focus = AccessibilityReader.focusedElement(o.pid), CFEqual(focus,element) else { return false }
            }
        }
        let fresh = try await ScreenCapture.capture(window:o.window,redactions:ax.secureRegions)
        try Task.checkCancellation()
        let now = Observation(pid:o.pid,app:o.app,window:o.window,controls:[],geometry:fresh.geometry,jpeg:fresh.jpeg,signature:fresh.signature)
        return basicGuard(o,ax:ax) && o.sameScene(as:now)
    }
    private func basicGuard(_ o: Observation, ax: AXSnapshot) -> Bool {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == o.pid,
              let window = AccessibilityReader.focusedWindow(o.pid), CFEqual(window,ax.window),
              AccessibilityReader.frame(window)?.near(o.window) == true else { return false }
        if let focus = AccessibilityReader.focusedElement(o.pid), AccessibilityReader.secure(focus) { return false }
        return true
    }
    func execute(_ action: Action, observed o: Observation) async throws {
        try Task.checkCancellation()
        guard let ax = snapshots[o.id], basicGuard(o,ax:ax) else { throw VoiceError("The target window changed. No input was sent.") }
        switch action.operation {
        case .click,.focus:
            guard let id = action.target, let node = ax.references[id], !AccessibilityReader.secure(node),
                  let old = o.controls.first(where:{$0.id == id}), AccessibilityReader.frame(node)?.near(old.frame) == true else { throw VoiceError("The control is no longer available.") }
            try Task.checkCancellation()
            let error = action.operation == .click ? AXUIElementPerformAction(node,kAXPressAction as CFString) :
                AXUIElementSetAttributeValue(node,kAXFocusedAttribute as CFString,kCFBooleanTrue)
            guard error == .success else { throw VoiceError("The application refused the accessibility action. Try describing a visual target.") }
        case .visualClick:
            guard let p = action.point, o.geometry.desktopCrop.contains(p) else { throw VoiceError("Invalid visual click.") }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(p.x),Float(p.y),&hit) == .success,
                  let hit, !AccessibilityReader.secure(hit) else { throw VoiceError("The visual target cannot be verified safely.") }
            var pid: pid_t = 0; AXUIElementGetPid(hit,&pid)
            guard pid == o.pid else { throw VoiceError("Another window is covering the visual target.") }
            try Task.checkCancellation()
            if AccessibilityReader.actions(hit).contains(kAXPressAction),
               ["AXButton","AXLink","AXCheckBox","AXRadioButton"].contains(AccessibilityReader.attribute(hit,kAXRoleAttribute) as? String ?? "") {
                guard AXUIElementPerformAction(hit,kAXPressAction as CFString) == .success else { throw VoiceError("The visual control refused the action.") }
            } else {
                let point = CGPoint(x:p.x,y:p.y)
                guard let down = CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left),
                      let up = CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else { throw VoiceError("Could not create mouse input.") }
                down.post(tap:.cghidEventTap); up.post(tap:.cghidEventTap)
            }
        case .typeText:
            guard let id = action.target, let node = ax.references[id], let focus = AccessibilityReader.focusedElement(o.pid),
                  CFEqual(node,focus), !AccessibilityReader.secure(focus), !IsSecureEventInputEnabled(), let text = action.text,
                  text.utf16.count <= 2000 else { throw VoiceError("The intended text field is no longer focused.") }
            try InsertionSafety.validate(text)
            // Insert only; never select-all, clear a field, or touch the clipboard.
            for chunk in text.utf16.chunked(20) {
                try Task.checkCancellation()
                guard basicGuard(o,ax:ax), let live = AccessibilityReader.focusedElement(o.pid), CFEqual(live,node) else { throw VoiceError("Focus changed during typing; insertion stopped.") }
                guard let down = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true),
                      let up = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:false) else { throw VoiceError("Could not create keyboard input.") }
                chunk.withUnsafeBufferPointer { buffer in
                    down.keyboardSetUnicodeString(stringLength:chunk.count,unicodeString:buffer.baseAddress!)
                    up.keyboardSetUnicodeString(stringLength:chunk.count,unicodeString:buffer.baseAddress!)
                }
                down.post(tap:.cghidEventTap); up.post(tap:.cghidEventTap)
                try await Task.sleep(nanoseconds:10_000_000)
            }
        case .shortcut:
            guard let key = action.shortcut else { throw VoiceError("No keyboard shortcut selected.") }
            let mappings: [Shortcut:(CGKeyCode,CGEventFlags)] = [
                .newTab:(17,.maskCommand), .previousTab:(48,[.maskControl,.maskShift]), .nextTab:(48,.maskControl),
                .back:(33,.maskCommand), .forward:(30,.maskCommand), .addressBar:(37,.maskCommand),
                .enter:(36,[]), .escape:(53,[]), .closeTab:(13,.maskCommand)]
            let (code,flags) = mappings[key]!
            guard let down = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true),
                  let up = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:false) else { throw VoiceError("Could not create keyboard input.") }
            try Task.checkCancellation(); down.flags = flags; up.flags = []
            down.post(tap:.cghidEventTap); up.post(tap:.cghidEventTap)
        case .scroll:
            guard abs(action.scroll) <= 25,
                  let event = CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:Int32(action.scroll),wheel2:0,wheel3:0) else { throw VoiceError("Invalid scroll.") }
            // Deliver to the observed process, independent of where the user's pointer sits.
            try Task.checkCancellation(); event.postToPid(o.pid)
        case .openApp:
            guard let id = action.target, let url = appURLs[id] else { throw VoiceError("Application not installed.") }
            try Task.checkCancellation()
            _ = try await NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration())
        case .openURL:
            guard let value = action.text, Candidates.safeURL(value), let url = URL(string:value) else { throw VoiceError("Unsupported URL.") }
            try Task.checkCancellation()
            if let front = NSWorkspace.shared.frontmostApplication, let appURL = front.bundleURL,
               ["chrome","safari","firefox","brave","edge"].contains(where:{(front.bundleIdentifier ?? "").lowercased().contains($0)}) {
                _ = try await NSWorkspace.shared.open([url],withApplicationAt:appURL,configuration:NSWorkspace.OpenConfiguration())
            } else { guard NSWorkspace.shared.open(url) else { throw VoiceError("Could not open the website.") } }
        case .openDownloads:
            try Task.checkCancellation()
            guard let url = FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first, NSWorkspace.shared.open(url) else { throw VoiceError("Could not open Downloads.") }
        case .wait: break
        case .done,.clarify: throw VoiceError("Non-executable decision.")
        }
    }
}
private extension String.UTF16View {
    func chunked(_ size: Int) -> [[UInt16]] {
        // Preserve surrogate pairs at chunk boundaries.
        var result: [[UInt16]] = [], chunk: [UInt16] = []
        for unit in self {
            chunk.append(unit)
            if chunk.count >= size && !(0xD800...0xDBFF).contains(unit) { result.append(chunk); chunk = [] }
        }
        if !chunk.isEmpty { result.append(chunk) }; return result
    }
}
