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
    func performGlobalCommand(_ goal: String) async throws -> Bool {
        let text = goal.trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters))
        guard let match = text.range(of:#"^(?:open|launch|switch to|open de|start)\s+"#,options:[.regularExpression,.caseInsensitive]) else { return false }
        let name = String(text[match.upperBound...])
        refreshApps()
        let matches = apps.filter { $0.matchesName(name) || ($0.id == "com.google.Chrome" && name.lowercased() == "chrome") || ($0.id == "com.apple.finder" && name.lowercased() == "finder") }
        guard matches.count == 1, let target = matches.first, let url = appURLs[target.id] else { return false }
        try Task.checkCancellation()
        let app = try await NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration())
        app.activate(options:[])
        for _ in 0..<20 {
            try Task.checkCancellation()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        throw VoiceError("Application opened but did not become foreground.")
    }
    func directAction(_ goal: String, observation: Observation) -> Action? {
        let text = goal.lowercased().trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters))
        let shortcuts: [String:Shortcut] = ["open a new tab":.newTab,"new tab":.newTab,"open een nieuw tabblad":.newTab,"press enter":.enter,"druk op enter":.enter,"press escape":.escape,"go back":.back]
        if let shortcut = shortcuts[text] { var a = Action(.shortcut,label:"Key: " + shortcut.rawValue); a.shortcut = shortcut; return a }
        if text.hasPrefix("minimize ") || text.hasPrefix("minimaliseer ") {
            let names = apps.filter { $0.mentioned(in:text) }
            guard names.count == 1, names[0].mentioned(in:observation.app) else { return nil }
            var a = Action(.keyCombo,label:"Minimize " + observation.app); a.keys = ["command","m"]; return a
        }
        return nil
    }
    func observe() async throws -> Observation {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw VoiceError("Enable Accessibility for Mac Voice Control in System Settings.") }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !["com.apple.loginwindow","com.apple.SecurityAgent"].contains(app.bundleIdentifier ?? "") else {
            throw VoiceError("Bring the application you want to control to the front.")
        }
        let t = MonotonicTime.now
        let bundle = app.bundleIdentifier ?? ""
        let chromium = ["chrome","chromium","brave","edge","electron"].contains { bundle.lowercased().contains($0) }
        let ax = try await reader.read(pid:app.processIdentifier,chromium:chromium)
        try Task.checkCancellation()
        let axTime = (MonotonicTime.now-t)*1000
        // Mask known secure regions, refuse secure focus, and require explicit consent
        // because an incomplete AX tree cannot identify every visually displayed secret.
        guard !IsSecureEventInputEnabled(), !ax.secureFocus else { throw VoiceError("A secure field has focus. Move focus away from passwords before continuing.") }
        let captureStart = MonotonicTime.now
        let screen = try await ScreenCapture.capture(window:ax.frame,redactions:ax.secureRegions)
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              windowUnchanged(ax) else { throw VoiceError("The foreground window changed during capture. Please try again.") }
        var o = Observation(pid:app.processIdentifier,app:app.localizedName ?? "Application",window:ax.frame,controls:ax.controls,
            focusedID:ax.focusedID,secureFocus:ax.secureFocus,accessibilityIncomplete:ax.incomplete,
            geometry:screen.geometry,jpeg:screen.jpeg,signature:screen.signature)
        o.timings = ["accessibility_ms":axTime,"capture_ms":(MonotonicTime.now-captureStart)*1000]
        if snapshots.count > 3 { snapshots.removeAll() }
        snapshots[o.id] = ax
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
        DebugLog.shared.record("desktop.freshness_screenshot",data:fresh.jpeg,ext:"jpg",fields:["observation_id":o.id.uuidString])
        try Task.checkCancellation()
        guard fresh.geometry == o.geometry else { return false }
        if [.visualClick,.rightClick,.doubleClick,.drag,.movePointer].contains(action.operation) {
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
        guard let old = ax.visualWindow else { return AccessibilityReader.focusedWindow(ax.pid) == nil && WindowCatalog.foreground(pid:ax.pid,windows:WindowCatalog.current()) == nil }
        return WindowCatalog.unchanged(old,windows:WindowCatalog.current())
    }
    func execute(_ action: Action, observed o: Observation) async throws {
        DebugLog.shared.value("action.started",action,fields:["observation_id":o.id.uuidString])
        var completed = false
        defer { DebugLog.shared.event("action.finished",["observation_id":o.id.uuidString,"completed":String(completed)]) }
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
        case .rightClick, .doubleClick, .drag, .movePointer, .visualClick:
            guard let p = action.point, o.geometry.desktopCrop.contains(p) else { throw VoiceError("Invalid visual click.") }
            var hit: AXUIElement?
            let hitResult = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(p.x),Float(p.y),&hit)
            if hitResult == .success, let hit {
                var hitPID: pid_t = 0; AXUIElementGetPid(hit,&hitPID)
                guard hitPID != ProcessInfo.processInfo.processIdentifier else { throw VoiceError("Move the status overlay away from the target and try again.") }
                guard !AccessibilityReader.secure(hit) else { throw VoiceError("The target is a secure control.") }
            } else {
                guard o.geometry.desktopCrop.contains(p) else { throw VoiceError("Target is outside the observed display.") }
            }
            try Task.checkCancellation()
            if action.operation == .visualClick, let hit, hitResult == .success, AccessibilityReader.actions(hit).contains(kAXPressAction),
               ["AXButton","AXLink","AXCheckBox","AXRadioButton"].contains(AccessibilityReader.attribute(hit,kAXRoleAttribute) as? String ?? "") {
                guard AXUIElementPerformAction(hit,kAXPressAction as CFString) == .success else { throw VoiceError("The visual control refused the action.") }
            } else {
                let point = CGPoint(x:p.x,y:p.y)
                let right = action.operation == .rightClick
                let button: CGMouseButton = right ? .right : .left
                func post(_ type: CGEventType, _ at: CGPoint, count: Int64 = 1) throws {
                    guard let event = CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:at,mouseButton:button) else { throw VoiceError("Could not create mouse input.") }
                    event.setIntegerValueField(.mouseEventClickState,value:count); event.post(tap:.cghidEventTap)
                }
                if action.operation == .movePointer { try post(.mouseMoved,point) }
                else {
                    let destination = action.endPoint.map { CGPoint(x:$0.x,y:$0.y) } ?? point
                    if action.operation == .drag { guard let end = action.endPoint, o.geometry.desktopCrop.contains(end) else { throw VoiceError("Invalid drag destination.") } }
                    for count in 1...(action.operation == .doubleClick ? 2 : 1) {
                        try post(right ? .rightMouseDown : .leftMouseDown,point,count:Int64(count))
                        // Always release posted buttons, including during cancellation.
                        defer { try? post(right ? .rightMouseUp : .leftMouseUp,destination,count:Int64(count)) }
                        if action.operation == .drag {
                            for step in 1...20 {
                                try Task.checkCancellation()
                                let f = Double(step)/20
                                try post(.leftMouseDragged,CGPoint(x:point.x+(destination.x-point.x)*f,y:point.y+(destination.y-point.y)*f))
                                try await Task.sleep(nanoseconds:10_000_000)
                            }
                        }
                    }
                }
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
        case .keyCombo:
            let keycodes: [String:CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"enter":36,"l":37,"j":38,"k":40,"n":45,"m":46,"tab":48,"space":49,"delete":51,"escape":53,"left":123,"right":124,"down":125,"up":126]
            let modifiers: [String:CGEventFlags] = ["command":.maskCommand,"shift":.maskShift,"option":.maskAlternate,"control":.maskControl]
            guard let keys = action.keys, keys.count <= 5 else { throw VoiceError("Invalid keys.") }
            var flags = CGEventFlags(); var code: CGKeyCode?
            for key in keys.map({$0.lowercased()}) {
                if let flag = modifiers[key] { flags.formUnion(flag) }
                else if let value = keycodes[key], code == nil { code = value }
                else { throw VoiceError("Unsupported key: " + key) }
            }
            guard let code, let down = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true), let up = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:false) else { throw VoiceError("Select one key and optional modifiers.") }
            try Task.checkCancellation(); down.flags = flags; up.flags = []
            down.post(tap:.cghidEventTap); up.post(tap:.cghidEventTap)
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
        case .done,.clarify,.requestLanguage: throw VoiceError("Non-executable decision.")
        }
        completed = true
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
