import AppKit
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
    @Published var timings: [String:Double] = [:]
    @Published var tokens = 0
    @Published var estimatedCost: Double = 0
    @Published var setupVisible = false
    @Published var consent = UserDefaults.standard.bool(forKey:"screenConsent") {
        didSet { UserDefaults.standard.set(consent,forKey:"screenConsent"); if !consent { stop() } }
    }
    private let speech: SpeechProviding
    private var desktop: MacDesktop?
    private var loop: GoalLoop?
    private var runTask: Task<Void,Never>?, downloadTask: Task<Void,Never>?
    private var foreground: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var currentGoal = ""
    private var epoch = UUID()
    init(speech provider: SpeechProviding? = nil) {
        self.speech = provider ?? LocalSpeech()
        let speech = self.speech
        do { keySaved = try KeyStore.read() != nil } catch { message = error.localizedDescription }
        foreground = NSWorkspace.shared.frontmostApplication
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] note in
            Task { @MainActor in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.foreground = app
            }
        }
        refreshPermissions()
        speech.onTranscript = { [weak self] text,ms in self?.receive(text,ms:ms) }
        speech.onStop = { [weak self] in self?.stop() }
        speech.onError = { [weak self] text in self?.stop(); self?.phase = .failed; self?.message = text }
        speech.onTranscribing = { [weak self] in
            guard let self, self.listening, self.runTask == nil else { return }; self.phase = .transcribing
        }
    }
    var ready: Bool { keySaved && consent && modelReady && accessibility && screenRecording && microphone }
    func refreshPermissions() {
        accessibility = AXIsProcessTrusted(); screenRecording = CGPreflightScreenCaptureAccess()
        microphone = AVCaptureDevice.authorizationStatus(for:.audio) == .authorized
        quickStop = SFSpeechRecognizer.authorizationStatus() == .authorized
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
            } catch is CancellationError { downloadMessage = "Download cancelled. You can retry; completed files are cached." }
            catch { downloadMessage = "Could not prepare the model. Check your connection and retry. Cached files will be checked." }
            downloading = false; downloadTask = nil
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    func start() {
        refreshPermissions()
        guard ready else { setupVisible = true; message = "Complete Setup to start listening."; return }
        do {
            guard let key = try KeyStore.read(), !key.isEmpty else { throw VoiceError("Save your TypeSafe key first.") }
            let desktop = MacDesktop(); self.desktop = desktop
            let loop = GoalLoop(desktop:desktop,decider:JevClient(key:key)); self.loop = loop
            loop.onEvent = { [weak self] event in self?.event(event) }
            try speech.start(); listening = true; phase = .listening
            message = "Say ‘Hey Jev’ followed by a command. Say ‘stop’ to stop."
            hideAndRestoreTarget()
        } catch { phase = .failed; message = error.localizedDescription }
    }
    func stop() {
        epoch = UUID(); loop?.stop(); runTask?.cancel(); runTask = nil
        speech.stop(); listening = false; pending = nil; phase = .stopped; message = "Stopped. No further actions will start."
    }
    func confirm(_ allowed: Bool) {
        if allowed { hideAndRestoreTarget() }
        let run = epoch
        Task {
            if allowed { try? await Task.sleep(nanoseconds:200_000_000) }
            guard epoch == run else { return }
            loop?.resolveConfirmation(allowed); pending = nil
        }
    }
    private func hideAndRestoreTarget() {
        NSApp.hide(nil)
        foreground?.activate(options:[])
    }
    func submitTyped(_ goal: String) { guard listening else { return }; receive("Hey Jev " + goal,ms:0) }
    private func receive(_ text: String, ms: Double) {
        guard listening else { return }
        timings["transcription_ms"] = ms; transcript = text
        switch InputRouter.route(text,final:true,confirmationPending:pending != nil) {
        case .stop: stop()
        case .confirm: confirm(true)
        case .cancel: confirm(false)
        case .ignore:
            if runTask == nil { phase = .listening }
        case let .command(goal): begin(goal)
        case let .correction(correction):
            guard !currentGoal.isEmpty else { message = "Say ‘Hey Jev’ and the full command."; return }
            let goal = "Original goal: \(currentGoal). User correction (takes priority): \(correction)"
            begin(goal,context:Array(loop?.history.suffix(3) ?? []))
        case let .dictation(text): beginDictation(text)
        }
    }
    private func begin(_ goal: String, context: [HistoryEntry] = []) {
        loop?.stop(); runTask?.cancel(); pending = nil; epoch = UUID(); let run = epoch
        currentGoal = goal; hideAndRestoreTarget()
        runTask = Task { [weak self] in
            guard let self, let loop else { return }
            do {
                try await Task.sleep(nanoseconds:180_000_000)
                try await loop.run(goal:goal,context:context)
                guard epoch == run else { return }
                phase = .listening; message = "Goal finished. Listening for ‘Hey Jev’…"
            } catch is CancellationError { }
            catch { guard epoch == run else { return }; phase = .paused; message = error.localizedDescription }
            guard epoch == run else { return }; runTask = nil; pending = nil
        }
    }
    private func beginDictation(_ text: String) {
        loop?.stop(); runTask?.cancel(); pending = nil; epoch = UUID(); let run = epoch
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
            catch { guard epoch == run else { return }; phase = .paused; message = error.localizedDescription }
            guard epoch == run else { return }; runTask = nil
        }
    }
    private func event(_ event: SessionEvent) {
        guard listening else { return }
        phase = event.phase; message = event.message; pending = loop?.pendingAction?.label
        timings.merge(event.timings) { _,new in new }; tokens += event.tokens; estimatedCost += event.cost
    }
}
