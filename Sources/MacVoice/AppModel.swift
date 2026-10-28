import AppKit
import Combine
import AVFoundation
import Speech
import VoiceCore

@MainActor final class AppModel: ObservableObject {
    @Published var phase: SessionPhase = .stopped
    @Published var message = "Set up your key, permissions, and local speech model to begin."
    @Published var transcript = ""
    @Published var listening = false
    @Published var keySaved = false
    @Published var modelReady = false
    @Published var modelProgress: Double = 0
    @Published var downloading = false
    @Published var downloadMessage = "Parakeet Ultra · Dutch + English · local processing"
    @Published var accessibility = false
    @Published var screenRecording = false
    @Published var microphone = false
    @Published var quickStop = false
    @Published var pending: String?
    @Published var pendingImage: Data?
    @Published var pendingMarker: Point?
    @Published var timings: [String:Double] = [:]
    @Published var tokens = 0
    @Published var estimatedCost: Double = 0
    @Published var setupVisible = false
    let chatGPT = ChatGPTAccount()
    @Published var debugLogging = UserDefaults.standard.bool(forKey:"debugLogging") {
        didSet {
            UserDefaults.standard.set(debugLogging,forKey:"debugLogging")
            DebugLog.shared.setEnabled(debugLogging)
        }
    }
    func revealDebugLogs() {
        DebugLog.shared.prepareForSharing()
        if let error = DebugLog.shared.lastError { message = error }
        if !NSWorkspace.shared.open(DebugLog.shared.directory) { message = "Could not open the debug log folder." }
    }
    @Published var languageEnabled = UserDefaults.standard.bool(forKey:"languageEnabled") {
        didSet { UserDefaults.standard.set(languageEnabled,forKey:"languageEnabled"); stop() }
    }
    @Published var languageScreenContext = UserDefaults.standard.bool(forKey:"languageScreenContext") {
        didSet { UserDefaults.standard.set(languageScreenContext,forKey:"languageScreenContext"); stop() }
    }
    @Published var consent = UserDefaults.standard.bool(forKey:"screenConsent") {
        didSet { UserDefaults.standard.set(consent,forKey:"screenConsent"); if !consent { stop() } }
    }
    private let speech: SpeechProviding
    private var desktop: MacDesktop?
    private var loop: GoalLoop?
    private var runTask: Task<Void,Never>?, downloadTask: Task<Void,Never>?
    private var foreground: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var conversation = ConversationMemory()
    private var pendingConfirmationID: UUID?
    private var commandReceivedAt: TimeInterval?
    private var commandSpeechLatency: Double?
    private var epoch = UUID()
    private var overlay: StatusOverlay?
    init(speech provider: SpeechProviding? = nil, hasKey: () throws -> Bool = { try KeyStore.read() != nil }) {
        DebugLog.shared.setEnabled(UserDefaults.standard.bool(forKey:"debugLogging"))
        self.speech = provider ?? LocalSpeech()
        let speech = self.speech
        do { keySaved = try hasKey() } catch { message = error.localizedDescription }
        foreground = NSWorkspace.shared.frontmostApplication
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] note in
            Task { @MainActor in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.foreground = app
            }
        }
        refreshPermissions()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in if self?.listening == true { self?.stop() } }
        }
        speech.onTranscript = { [weak self] result in
            guard let self, self.listening else { return }
            self.timings["speech_end_to_transcript_ms"] = result.endToTranscriptMilliseconds
            self.receive(result.text,ms:result.inferenceMilliseconds)
        }
        speech.onStop = { [weak self] in self?.stop() }
        speech.onError = { [weak self] text in
            DebugLog.shared.event("speech.pipeline_error",["error":text])
            self?.stop(); self?.phase = .failed; self?.message = text; self?.showFeedback()
        }
        speech.onTranscribing = { [weak self] in
            guard let self, self.listening, self.runTask == nil else { return }; self.phase = .transcribing
        }
        if provider == nil, UserDefaults.standard.bool(forKey:"speechModelPreviouslyLoaded") { downloadModel() }
    }
    var ready: Bool { keySaved && consent && modelReady && accessibility && screenRecording && microphone }
    func refreshPermissions() {
        accessibility = AXIsProcessTrusted(); screenRecording = CGPreflightScreenCaptureAccess()
        microphone = AVCaptureDevice.authorizationStatus(for:.audio) == .authorized
        quickStop = SFSpeechRecognizer.authorizationStatus() == .authorized &&
            SFSpeechRecognizer(locale:Locale(identifier:"en-US"))?.supportsOnDeviceRecognition == true
    }
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        openPrivacy("Privacy_Accessibility")
    }
    func requestScreen() { _ = CGRequestScreenCaptureAccess(); openPrivacy("Privacy_ScreenCapture") }
    func requestMicrophone() {
        Task { _ = await AVCaptureDevice.requestAccess(for:.audio); refreshPermissions() }
    }
    func requestQuickStop() {
        SFSpeechRecognizer.requestAuthorization { _ in Task { @MainActor in self.refreshPermissions() } }
    }
    func openPrivacy(_ pane: String) {
        if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    func saveKey(_ value: String) {
        do { try KeyStore.save(value); keySaved = true; message = "API key saved in Keychain." }
        catch { message = error.localizedDescription }
    }
    func forgetKey() {
        stop()
        do { try KeyStore.delete(); keySaved = false; message = "API key removed." } catch { message = error.localizedDescription }
    }
    func downloadModel() {
        guard !downloading else { return }
        downloading = true; downloadMessage = "Preparing download…"; modelProgress = 0
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await speech.prepare { [weak self] fraction,message in
                    Task { @MainActor in guard let self, self.downloading else { return }; self.modelProgress = fraction; self.downloadMessage = message }
                }
                try Task.checkCancellation()
                modelReady = true; downloadMessage = "Local speech model ready."; modelProgress = 1
                UserDefaults.standard.set(true,forKey:"speechModelPreviouslyLoaded")
            } catch is CancellationError { downloadMessage = "Download cancelled. You can retry; completed files are cached." }
            catch { downloadMessage = "Could not prepare the model. Check your connection and retry. Cached files will be checked." }
            downloading = false; downloadTask = nil
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    func start() {
        DebugLog.shared.event("listening.start_requested")
        guard !listening else { return }
        refreshPermissions()
        guard ready else { setupVisible = true; message = "Complete Setup to start listening."; showSetup(); return }
        do {
            guard let key = try KeyStore.read(), !key.isEmpty else { throw VoiceError("Save your TypeSafe key first.") }
            let desktop = MacDesktop(); self.desktop = desktop
            let helper: (any LanguageHelping)? = languageEnabled && chatGPT.connected
                ? OpenAILanguageHelper(auth:chatGPT.auth,model:chatGPT.model) : nil
            if languageEnabled && helper == nil { throw VoiceError("Connect ChatGPT in Setup or turn off language assistance.") }
            let loop = GoalLoop(desktop:desktop,decider:JevClient(key:key),language:helper,
                languageScreenContext:languageScreenContext); self.loop = loop
            loop.onEvent = { [weak self] event in self?.event(event) }
            try speech.start(); listening = true; phase = .listening
            setupVisible = false
            message = "Say ‘Hey Jev’ followed by a command. Say ‘stop’ to stop."
            hideAndRestoreTarget()
            showStatus()
        } catch { phase = .failed; message = error.localizedDescription; DebugLog.shared.event("session.error",["error":message]); showStatus() }
    }
    func stop() {
        DebugLog.shared.event("listening.stopped")
        epoch = UUID(); loop?.stop(); runTask?.cancel(); runTask = nil
        speech.stop(); listening = false; pending = nil; pendingImage = nil; pendingMarker = nil
        pendingConfirmationID = nil; conversation.clear()
        transcript = ""; loop = nil; desktop = nil; commandReceivedAt = nil
        phase = .stopped; message = "Stopped. No further actions will start."
        overlay?.hide()
    }
    func confirm(_ allowed: Bool) {
        guard let id = pendingConfirmationID, let loop else { return }
        if allowed { hideAndRestoreTarget() }
        let run = epoch
        Task {
            if allowed { try? await Task.sleep(nanoseconds:200_000_000) }
            guard epoch == run else { return }
            loop.resolveConfirmation(allowed,id:id)
            if pendingConfirmationID == id { clearPending() }
        }
    }
    private func hideAndRestoreTarget() {
        guard let app = NSApp else { return }
        // Only close setup/control windows. Hiding the application would hide the overlay too.
        app.windows.filter { !($0 is NSPanel) }.forEach { $0.orderOut(nil) }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            foreground?.activate(options:[])
        }
    }
    func submitTyped(_ goal: String) {
        guard listening else { return }
        timings["speech_end_to_transcript_ms"] = nil
        receive("Hey Jev " + goal,ms:0)
    }
    private func receive(_ text: String, ms: Double) {
        guard listening else { return }
        DebugLog.shared.event("input.received",["text":text,"transcription_ms":String(ms)])
        timings["transcription_ms"] = ms; transcript = text
        let now = MonotonicTime.now
        switch InputRouter.route(text,final:true,confirmationPending:pending != nil,
                                 correctionAllowed:conversation.acceptsCorrection(at:now,active:runTask != nil)) {
        case .stop: stop()
        case .confirm: confirm(true)
        case .cancel: confirm(false)
        case .ignore:
            if runTask == nil { phase = .listening }
        case let .command(goal): conversation.begin(goal,at:now); begin(goal)
        case let .correction(correction):
            guard let goal = conversation.correct(correction,at:now,active:runTask != nil) else { message = "Say ‘Hey Jev’ and the full command."; return }
            begin(goal,context:Array(loop?.history.suffix(3) ?? []))
        case let .dictation(text): conversation.clear(); beginDictation(text)
        }
    }
    private func begin(_ goal: String, context: [HistoryEntry] = []) {
        loop?.stop(); runTask?.cancel(); clearPending(); epoch = UUID(); let run = epoch
        hideAndRestoreTarget()
        commandReceivedAt = MonotonicTime.now
        commandSpeechLatency = timings["speech_end_to_transcript_ms"]
        runTask = Task { [weak self] in
            guard let self, let loop else { return }
            do {
                try await Task.sleep(nanoseconds:180_000_000)
                try await loop.run(goal:goal,context:context)
                guard epoch == run else { return }
                phase = .listening; message = "Goal finished. Listening for ‘Hey Jev’…"
            } catch is CancellationError { }
            catch { guard epoch == run else { return }; phase = .paused; message = error.localizedDescription; DebugLog.shared.event("session.error",["error":message]); showFeedback() }
            guard epoch == run else { return }
            conversation.finished(at:MonotonicTime.now); runTask = nil; clearPending()
        }
    }
    private func beginDictation(_ text: String) {
        loop?.stop(); runTask?.cancel(); clearPending(); epoch = UUID(); let run = epoch
        hideAndRestoreTarget()
        runTask = Task { [weak self] in
            guard let self, let desktop else { return }
            do {
                try await Task.sleep(nanoseconds:180_000_000)
                let observation = try await desktop.observe()
                guard let id = observation.focusedID, let control = observation.controls.first(where:{$0.id == id}), control.canFocus,
                      !observation.secureFocus else { throw VoiceError("Focus a non-secure text field before dictating.") }
                var action = Action(.typeText,label:"Insert dictated text"); action.target = id; action.text = text
                guard try await desktop.isFresh(observation,for:action) else { throw VoiceError("The text field changed. Please try again.") }
                try Task.checkCancellation(); guard epoch == run else { return }
                phase = .executing; try await desktop.execute(action,observed:observation)
                guard epoch == run else { return }; phase = .listening; message = "Dictation inserted. Listening…"
            } catch is CancellationError { }
            catch { guard epoch == run else { return }; phase = .paused; message = error.localizedDescription; DebugLog.shared.event("session.error",["error":message]); showFeedback() }
            guard epoch == run else { return }; runTask = nil
        }
    }
    private func event(_ event: SessionEvent) {
        DebugLog.shared.value("session.event",event)
        guard listening else { return }
        phase = event.phase; message = event.message; pending = loop?.pendingAction?.label
        pendingConfirmationID = loop?.pendingConfirmationID
        if let observation = loop?.pendingObservation, let point = loop?.pendingAction?.point {
            pendingImage = observation.jpeg
            let g = observation.geometry
            pendingMarker = Point((g.content.x + (point.x-g.desktopCrop.x)/g.desktopCrop.width*g.content.width)/Double(g.pixelWidth),
                                  (g.content.y + (point.y-g.desktopCrop.y)/g.desktopCrop.height*g.content.height)/Double(g.pixelHeight))
        } else { pendingImage = nil; pendingMarker = nil }
        timings.merge(event.timings) { _,new in new }; tokens += event.tokens; estimatedCost += event.cost
        if event.timings["command_to_first_action_ms"] != nil, let commandReceivedAt, let commandSpeechLatency {
            timings["speech_end_to_first_action_ms"] = commandSpeechLatency + (MonotonicTime.now-commandReceivedAt)*1000
        }
        showStatus()
    }
    private func showFeedback() {
        showStatus()
    }
    private func showSetup() {
        guard let app = NSApp else { return }
        app.unhide(nil)
        app.windows.first(where:{$0.title == "Mac Voice Control"})?.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps:true)
    }
    private func showStatus() {
        guard NSApp != nil else { return }
        if overlay == nil { overlay = StatusOverlay(model:self) }
        overlay?.show()
    }
    func shutdown() {
        stop(); cancelDownload(); chatGPT.cancelSignIn(); DebugLog.shared.flush()
    }
    private func clearPending() {
        pending = nil; pendingImage = nil; pendingMarker = nil; pendingConfirmationID = nil
    }
}
