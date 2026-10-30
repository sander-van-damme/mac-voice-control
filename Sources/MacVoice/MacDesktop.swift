import AppKit
import ApplicationServices
import Carbon
import VoiceCore

@MainActor final class MacDesktop: DesktopControlling, DirectCommandExecuting {
    var supportsTaskPlanning: Bool { true }
    private let browser = BrowserConnection()
    private let browserEnabled: Bool
    private var cachedObservation: Observation?
    private var executionGeneration = UUID()
    private var totalCaptures = 0
    var captureCount: Int? { totalCaptures }
    private func captureScreen(window: Rect, redactions: [Rect]) async throws -> CapturedScreen {
        let result = try await ScreenCapture.capture(window:window,redactions:redactions)
        totalCaptures += 1; return result
    }
    func cancelPendingActions() { executionGeneration = UUID(); browser.cancel(); cachedObservation = nil; snapshots.removeAll() }
    private let reader = AccessibilityReader()
    private var snapshots: [UUID: AXSnapshot] = [:]
    private var appURLs: [String: URL] = [:]
    private(set) var apps: [AppCandidate] = []
    init(browserEnabled: Bool = false) { self.browserEnabled = browserEnabled; refreshApps() }
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
    func observe() async throws -> Observation { try await observe(preference:.automatic) }
    func observe(preference: ObservationPreference) async throws -> Observation {
        if preference == .automatic, let cached = cachedObservation, MonotonicTime.now-cached.acquiredAt < 0.5 {
            cachedObservation = nil; return cached
        }
        cachedObservation = nil
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw VoiceError("Enable Accessibility for Mac Voice Control in System Settings.") }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !["com.apple.loginwindow","com.apple.SecurityAgent"].contains(app.bundleIdentifier ?? "") else {
            throw VoiceError("Bring the application you want to control to the front.")
        }
        let t = MonotonicTime.now
        let bundle = app.bundleIdentifier ?? ""
        let chromium = ["chrome","chromium","brave","edge","electron"].contains { bundle.lowercased().contains($0) }
        if browserEnabled, preference != .visual, bundle == "com.google.Chrome", browser.connected,
           let window = AccessibilityReader.focusedWindow(app.processIdentifier), let frame = AccessibilityReader.frame(window),
           !IsSecureEventInputEnabled() {
            do {
                let result = try await browser.send(.observe)
                try Task.checkCancellation()
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      let snapshot = result.snapshot, !snapshot.secureFocus, !snapshot.controls.isEmpty else {
                    throw VoiceError("Browser semantics unavailable.")
                }
                var o = Observation(pid:app.processIdentifier,app:app.localizedName ?? "Chrome",window:frame,
                    controls:snapshot.controls,focusedID:snapshot.focusedID,secureFocus:snapshot.secureFocus,
                    accessibilityIncomplete:snapshot.context.hasUnsupportedContent,geometry:try .fitted(crop:frame),jpeg:Data(),signature:[])
                o.source = .browser; o.browser = snapshot.context
                o.timings["browser_observation_ms"] = (MonotonicTime.now-t)*1000
                let ax = AXSnapshot(pid:app.processIdentifier,window:window,frame:frame,controls:[],references:[:],focusedID:nil,secureFocus:false,secureRegions:[],incomplete:true)
                snapshots[o.id] = ax; trimSnapshots(keeping:o.id)
                return o
            } catch is CancellationError { throw CancellationError() }
            catch { /* Read-only perception may fall back; failed actions never do. */ }
        }
        let ax = try await reader.read(pid:app.processIdentifier,chromium:chromium)
        try Task.checkCancellation()
        let axTime = (MonotonicTime.now-t)*1000
        // Mask known secure regions, refuse secure focus, and require explicit consent
        // because an incomplete AX tree cannot identify every visually displayed secret.
        guard !IsSecureEventInputEnabled(), !ax.secureFocus else { throw VoiceError("A secure field has focus. Move focus away from passwords before continuing.") }
        let semantic = preference == .semantic || (preference == .automatic && ax.controls.contains { $0.enabled && ($0.canPress || $0.canFocus) })
        let screen: CapturedScreen
        if semantic { screen = CapturedScreen(jpeg:Data(),signature:[],geometry:try .fitted(crop:ax.frame)) }
        else { screen = try await captureScreen(window:ax.frame,redactions:ax.secureRegions) }
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              windowUnchanged(ax) else { throw VoiceError("The foreground window changed during capture. Please try again.") }
        var o = Observation(pid:app.processIdentifier,app:app.localizedName ?? "Application",window:ax.frame,controls:ax.controls,
            focusedID:ax.focusedID,secureFocus:ax.secureFocus,accessibilityIncomplete:ax.incomplete,
            geometry:screen.geometry,jpeg:screen.jpeg,signature:screen.signature)
        o.source = semantic ? .accessibility : .visual
        o.timings = ["accessibility_ms":axTime]
        if !semantic { o.timings.merge(screen.timings) { _,new in new } }
        snapshots[o.id] = ax; trimSnapshots(keeping:o.id)
        DebugLog.shared.value("desktop.observation",o,fields:["observation_id":o.id.uuidString])
        DebugLog.shared.record("desktop.screenshot",data:o.jpeg,ext:"jpg",fields:["observation_id":o.id.uuidString])
        return o
    }
    func isFresh(_ o: Observation, for action: Action) async throws -> Bool {
        do {
            let result = try await checkFreshness(o,for:action)
            DebugLog.shared.event("desktop.freshness",["observation_id":o.id.uuidString,"fresh":String(result)])
            return result
        } catch {
            DebugLog.shared.event("desktop.freshness_error",["observation_id":o.id.uuidString,"error":error.localizedDescription])
            throw error
        }
    }
    private func checkFreshness(_ o: Observation, for action: Action) async throws -> Bool {
        try Task.checkCancellation()
        guard MonotonicTime.now-o.acquiredAt < 35,
              let ax = snapshots[o.id], basicGuard(o,ax:ax) else { return false }
        if o.source == .browser {
            guard let context = o.browser else { return false }
            _ = try await browser.send(.validate,context:context,action:action)
            try Task.checkCancellation(); return basicGuard(o,ax:ax)
        }
        if action.shortcut == .closeTab, o.source == .accessibility,
           !o.controls.contains(where: { ["AXRadioButton","AXTab"].contains($0.role) && ($0.selected == true || $0.checked == true) }) { return false }
        if action.operation == .wait { return true }
        if let id = action.target, [.click,.focus,.typeText].contains(action.operation) {
            guard let element = ax.references[id], let old = o.controls.first(where:{$0.id == id}),
                  !AccessibilityReader.secure(element), AccessibilityReader.attribute(element,kAXEnabledAttribute) as? Bool != false,
                  AccessibilityReader.frame(element)?.near(old.frame) == true,
                  AccessibilityReader.label(element) == old.label, AccessibilityReader.attribute(element,kAXRoleAttribute) as? String == old.role else { return false }
            if let selected = old.selected, AccessibilityReader.attribute(element,kAXSelectedAttribute) as? Bool != selected { return false }
            if let checked = old.checked, (AccessibilityReader.attribute(element,kAXValueAttribute) as? NSNumber).map({ $0.intValue != 0 }) != checked { return false }
            if action.operation == .typeText {
                guard let expected = ax.focusedValue, AccessibilityReader.safeFocusedValue(element) == expected else { return false }
                guard let focus = AccessibilityReader.focusedElement(o.pid), CFEqual(focus,element) else { return false }
            }
        }
        if o.source == .accessibility && action.target != nil { return basicGuard(o,ax:ax) }
        if o.source == .accessibility {
            let current = try await observe(preference:.semantic)
            return current.source == .accessibility && o.sameScene(as:current)
        }
        let fresh = try await captureScreen(window:o.window,redactions:ax.secureRegions)
        DebugLog.shared.record("desktop.freshness_screenshot",data:fresh.jpeg,ext:"jpg",fields:["observation_id":o.id.uuidString])
        try Task.checkCancellation()
        guard fresh.geometry == o.geometry else { return false }
        if action.operation == .visualClick {
            guard let point = action.point,
                  try ScreenCapture.targetUnchanged(previous:o.jpeg,current:fresh.jpeg,geometry:o.geometry,point:point) else { return false }
        }
        let now = Observation(pid:o.pid,app:o.app,window:o.window,controls:[],geometry:fresh.geometry,jpeg:fresh.jpeg,signature:fresh.signature)
        return basicGuard(o,ax:ax) && o.sameScene(as:now)
    }
    private func basicGuard(_ o: Observation, ax: AXSnapshot) -> Bool {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == o.pid,
              windowUnchanged(ax) else { return false }
        if let focus = AccessibilityReader.focusedElement(o.pid), AccessibilityReader.secure(focus) { return false }
        return true
    }
    private func windowUnchanged(_ ax: AXSnapshot) -> Bool {
        if let old = ax.window {
            guard let current = AccessibilityReader.focusedWindow(ax.pid) else { return false }
            return CFEqual(current,old) && AccessibilityReader.frame(current)?.near(ax.frame) == true
        }
        guard let old = ax.visualWindow else { return false }
        return WindowCatalog.unchanged(old,windows:WindowCatalog.current())
    }
    func execute(_ action: Action, observed o: Observation) async throws {
        DebugLog.shared.value("action.started",action,fields:["observation_id":o.id.uuidString])
        var completed = false
        defer { DebugLog.shared.event("action.finished",["observation_id":o.id.uuidString,"completed":String(completed)]) }
        try Task.checkCancellation()
        guard let ax = snapshots[o.id], basicGuard(o,ax:ax) else { throw VoiceError("The target window changed. No input was sent.") }
        if o.source == .browser, let context = o.browser,
           [.click,.focus,.typeText,.selectOption,.scroll,.wait,.openURL,.shortcut].contains(action.operation),
           action.operation != .shortcut || action.shortcut.map { [.back,.forward,.newTab,.closeTab,.previousTab,.nextTab].contains($0) } == true {
            try Task.checkCancellation()
            _ = try await browser.send(.act,context:context,action:action)
            completed = true; return
        }
        switch action.operation {
        case .click,.focus:
            guard let id = action.target, let node = ax.references[id], !AccessibilityReader.secure(node),
                  let old = o.controls.first(where:{$0.id == id}), AccessibilityReader.frame(node)?.near(old.frame) == true,
                  AccessibilityReader.label(node) == old.label, AccessibilityReader.attribute(node,kAXRoleAttribute) as? String == old.role, AccessibilityReader.attribute(node,kAXEnabledAttribute) as? Bool != false else { throw VoiceError("The control is no longer available.") }
            try Task.checkCancellation()
            let error = action.operation == .click ? AXUIElementPerformAction(node,kAXPressAction as CFString) :
                AXUIElementSetAttributeValue(node,kAXFocusedAttribute as CFString,kCFBooleanTrue)
            guard error == .success else { throw VoiceError("The application refused the accessibility action. Try describing a visual target.") }
        case .visualClick:
            guard let p = action.point, o.geometry.desktopCrop.contains(p) else { throw VoiceError("Invalid visual click.") }
            if let window = ax.visualWindow {
                guard WindowCatalog.exposed(window,at:p,windows:WindowCatalog.current()) else { throw VoiceError("Another window is covering the visual target.") }
            }
            var hit: AXUIElement?
            let hitResult = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(p.x),Float(p.y),&hit)
            if hitResult == .success, let hit {
                guard !AccessibilityReader.secure(hit) else { throw VoiceError("The target is a secure control.") }
                var pid: pid_t = 0; AXUIElementGetPid(hit,&pid)
                guard pid == o.pid else { throw VoiceError("Another window is covering the visual target.") }
            } else {
                guard let window = ax.visualWindow,
                      WindowCatalog.exposed(window,at:p,windows:WindowCatalog.current()) else {
                    throw VoiceError("The visual target cannot be verified safely.")
                }
            }
            try Task.checkCancellation()
            if let hit, hitResult == .success, AccessibilityReader.actions(hit).contains(kAXPressAction),
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
                  CFEqual(node,focus), !AccessibilityReader.secure(focus), ax.focusedValue != nil, AccessibilityReader.safeFocusedValue(focus) == ax.focusedValue, AccessibilityReader.hasInsertionPoint(focus), !IsSecureEventInputEnabled(), let text = action.text,
                  text.utf16.count <= 2000 else { throw VoiceError("The intended text field is no longer focused.") }
            try InsertionSafety.validate(text)
            // Insert only; never select-all, clear a field, or touch the clipboard.
            for chunk in text.utf16.chunked(20) {
                try Task.checkCancellation()
                guard snapshots[o.id] != nil, basicGuard(o,ax:ax), let live = AccessibilityReader.focusedElement(o.pid), CFEqual(live,node), AccessibilityReader.hasInsertionPoint(live) else { throw VoiceError("Focus changed during typing; insertion stopped.") }
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
        case .done,.clarify,.requestLanguage,.requestVision,.selectOption: throw VoiceError("Non-executable decision.")
        }
        completed = true
    }
    private func trimSnapshots(keeping id: UUID) {
        if snapshots.count > 8 { snapshots = snapshots.filter { $0.key == id } }
    }
    func waitForChange(after old: Observation, action: Action) async throws {
        let deadline = MonotonicTime.now + (action.operation == .wait ? 0.8 : 0.35)
        repeat {
            try Task.checkCancellation()
            let current = try await observe(preference:old.source == .visual ? .visual : .automatic)
            if !old.sameScene(as:current) { cachedObservation = current; return }
            cachedObservation = nil
            if MonotonicTime.now >= deadline { cachedObservation = current; return }
            try await Task.sleep(nanoseconds:35_000_000)
        } while true
    }
    func executeDirect(_ original: Action) async throws -> DirectResult {
        try await executeDirect(original,validate: { try Task.checkCancellation() })
    }
    func executeDirect(_ original: Action, validate: @MainActor () throws -> Void) async throws -> DirectResult {
        try validate()
        var action = original
        let executionRun = executionGeneration
        try Task.checkCancellation()
        if action.operation == .openApp {
            guard let id = action.target, let url = appURLs[id] else { throw VoiceError("Application not installed.") }
            let dispatchedAt = MonotonicTime.now
            _ = try await NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration())
            let deadline = MonotonicTime.now+1.5
            repeat {
                try Task.checkCancellation()
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id { return DirectResult(verified:true,dispatchedAt:dispatchedAt) }
                try await Task.sleep(nanoseconds:30_000_000)
            } while MonotonicTime.now < deadline
            return DirectResult(verified:false,dispatchedAt:dispatchedAt)
        }
        let o = try await observe(preference:.semantic)
        try validate()
        guard executionGeneration == executionRun else { throw CancellationError() }
        if action.operation == .shortcut {
            guard ["chrome","safari","firefox","edge","brave"].contains(where: { o.app.lowercased().contains($0) }) else {
                throw VoiceError("Bring a browser to the front for a tab or navigation command.")
            }
        }
        if action.operation == .typeText {
            guard let id = o.focusedID, let field = o.controls.first(where: { $0.id == id }), field.canFocus, !o.secureFocus else {
                throw VoiceError("Focus a non-secure editable field before dictating.")
            }
            action.target = id
            try InsertionSafety.validate(action.text ?? "")
        }
        guard try await isFresh(o,for:action) else { throw VoiceError("The target changed. Repeat the command.") }
        try Task.checkCancellation()
        try validate()
        guard executionGeneration == executionRun else { throw CancellationError() }
        let dispatchedAt = MonotonicTime.now
        try await execute(action,observed:o)
        try Task.checkCancellation()
        if action.operation == .openURL, let target = action.text {
            let deadline = MonotonicTime.now+1.5
            repeat {
                try await waitForChange(after:o,action:action)
                let now = try await observe(preference:.automatic)
                if URLComponents(string:target)?.query == nil, URLComponents(string:target)?.fragment == nil, now.browser?.url == BrowserContext.canonicalURL(target) { return DirectResult(verified:true,dispatchedAt:dispatchedAt) }
            } while MonotonicTime.now < deadline
        }
        return DirectResult(verified:false,dispatchedAt:dispatchedAt)
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
