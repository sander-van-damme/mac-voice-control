import AVFoundation
import Speech
import FluidAudio
import VoiceCore

@MainActor protocol SpeechProviding: AnyObject {
    var ready: Bool { get }
    var onTranscript: (String,Double) -> Void { get set }
    var onStop: () -> Void { get set }
    var onError: (String) -> Void { get set }
    var onTranscribing: () -> Void { get set }
    func prepare(progress: @escaping @Sendable (Double,String) -> Void) async throws
    func start() throws
    func stop()
}

@MainActor final class LocalSpeech: SpeechProviding {
    private let manager: AsrManager
    private let engine = AVAudioEngine()
    private var processing: Task<Void,Never>?, segmentation: Task<Void,Never>?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var generation = UUID()
    private var tapInstalled = false
    private var monitor: SFSpeechRecognitionTask?, monitorRequest: SFSpeechAudioBufferRecognitionRequest?
    private var monitorRenewal: Task<Void,Never>?
    private let monitorFeed = RecognitionFeed()
    private(set) var ready = false
    var onTranscript: (String,Double) -> Void = { _,_ in }
    var onStop: () -> Void = {}
    var onError: (String) -> Void = { _ in }
    var onTranscribing: () -> Void = {}
    init() {
        AppLogger.minimumLevel = .error; AppLogger.mirrorsToConsole = false
        manager = AsrManager(config:.default)
    }
    func prepare(progress: @escaping @Sendable (Double,String) -> Void) async throws {
        guard !ready else { return }
        let models = try await AsrModels.downloadAndLoad(version:.ultra,progressHandler: { update in
            let message: String
            switch update.phase {
            case .listing: message = "Checking speech model files…"
            case let .downloading(completedFiles,totalFiles): message = "Downloading speech model: \(completedFiles) / \(totalFiles) files"
            case let .compiling(modelName): message = "Preparing \(modelName)…"
            }
            progress(update.fractionCompleted,message)
        })
        try Task.checkCancellation()
        try await manager.loadModels(models)
        try Task.checkCancellation(); ready = true
    }
    func start() throws {
        stop()
        guard ready else { throw VoiceError("Download the local speech model in Setup first.") }
        guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else { throw VoiceError("Allow Microphone access in Setup.") }
        let run = generation
        let stream = AsyncStream<AudioChunk>(bufferingPolicy:.bufferingNewest(64)) { continuation = $0 }
        let utterances = AsyncStream<[Float]>.makeStream(bufferingPolicy:.bufferingNewest(1))
        let audioContinuation = continuation!
        let input = engine.inputNode, format = input.outputFormat(forBus:0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError("No microphone is available.") }
        startStopMonitor()
        let feed = monitorFeed
        input.installTap(onBus:0,bufferSize:1024,format:format) { buffer,_ in
            feed.append(buffer)
            guard let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
            var mono = [Float](repeating:0,count:count)
            for channel in 0..<channelCount { for i in 0..<count { mono[i] += channels[channel][i]/Float(channelCount) } }
            audioContinuation.yield(AudioChunk(samples:mono,rate:buffer.format.sampleRate))
        }
        tapInstalled = true
        do { engine.prepare(); try engine.start() }
        catch { stop(); throw VoiceError("The microphone could not start. Check the selected input device.") }
        segmentation = Task.detached(priority:.userInitiated) {
            var segmenter = UtteranceSegmenter()
            let converter = AudioConverter()
            for await chunk in stream {
                if Task.isCancelled { break }
                do {
                    let samples = try converter.resample(chunk.samples,from:chunk.rate)
                    if let complete = segmenter.append(samples) { utterances.continuation.yield(complete) }
                } catch { utterances.continuation.finish(); return }
            }
            utterances.continuation.finish()
        }
        processing = Task { [weak self] in
            guard let self else { return }
            for await samples in utterances.stream {
                guard !Task.isCancelled, generation == run else { return }
                onTranscribing()
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    var decoder = try TdtDecoderState()
                    let result = try await manager.transcribe(samples,decoderState:&decoder)
                    guard !Task.isCancelled, generation == run else { return }
                    let ms = (ProcessInfo.processInfo.systemUptime-start)*1000
                    startStopMonitor()
                    onTranscript(result.text,ms)
                } catch {
                    guard !Task.isCancelled, generation == run else { return }
                    onError("Local transcription failed. Stop and start listening to try again.")
                }
            }
        }
    }
    func stop() {
        generation = UUID()
        monitorFeed.set(nil); monitor?.cancel(); monitor = nil; monitorRequest = nil
        monitorRenewal?.cancel(); monitorRenewal = nil
        engine.stop(); if tapInstalled { engine.inputNode.removeTap(onBus:0); tapInstalled = false }
        continuation?.finish(); continuation = nil
        segmentation?.cancel(); processing?.cancel(); segmentation = nil; processing = nil
    }
    private func startStopMonitor() {
        monitorFeed.set(nil); monitor?.cancel(); monitorRenewal?.cancel()
        monitor = nil; monitorRequest = nil
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale:Locale(identifier:"en-US")),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        request.contextualStrings = ["stop","cancel"]
        let run = generation
        monitorRequest = request; monitorFeed.set(request)
        monitor = recognizer.recognitionTask(with:request) { [weak self] result,_ in
            guard let result, InputRouter.isStop(result.bestTranscription.formattedString) else { return }
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                self.onStop()
            }
        }
        monitorRenewal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:40_000_000_000) } catch { return }
            guard let self, generation == run else { return }; startStopMonitor()
        }
    }
}
private struct AudioChunk: Sendable { let samples: [Float]; let rate: Double }
/// Recognition request append is documented for audio callbacks; protect replacement against Stop.
private final class RecognitionFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func set(_ next: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request?.endAudio(); request = next; lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); request?.append(buffer); lock.unlock() }
}
