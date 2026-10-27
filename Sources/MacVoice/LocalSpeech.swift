import AVFoundation
import Speech
import FluidAudio
import VoiceCore

@MainActor protocol SpeechProviding: AnyObject {
    var ready: Bool { get }
    var onTranscript: (SpeechTranscript) -> Void { get set }
    var onStop: () -> Void { get set }
    var onError: (String) -> Void { get set }
    var onTranscribing: () -> Void { get set }
    func prepare(progress: @escaping @Sendable (Double,String) -> Void) async throws
    func start() throws
    func stop()
    func configurePushToTalk(_ enabled: Bool)
    func setCapture(_ enabled: Bool)
    func finishPushToTalk()
}
extension SpeechProviding {
    func configurePushToTalk(_ enabled: Bool) {}
    func setCapture(_ enabled: Bool) {}
    func finishPushToTalk() {}
}

@MainActor final class LocalSpeech: SpeechProviding {
    private let manager: AsrManager
    private let engine = AVAudioEngine()
    private var processing: Task<Void,Never>?, segmentation: Task<Void,Never>?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var generation = UUID()
    private var tapInstalled = false
    private let captureGate = CaptureGate()
    private var pushMode = false
    private var sequence = AudioSequence()
    func configurePushToTalk(_ enabled: Bool) { pushMode = enabled; captureGate.set(!enabled) }
    func setCapture(_ enabled: Bool) { captureGate.set(enabled) }
    func finishPushToTalk() {
        captureGate.close {
            continuation?.yield(AudioChunk(samples:[],rate:16000,sequence:sequence.next(),receivedAt:MonotonicTime.now,end:true))
        }
    }
    private var monitor: SFSpeechRecognitionTask?, monitorRequest: SFSpeechAudioBufferRecognitionRequest?
    private var monitorRenewal: Task<Void,Never>?
    private let monitorFeed = RecognitionFeed()
    private(set) var ready = false
    var onTranscript: (SpeechTranscript) -> Void = { _ in }
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
        let utterances = AsyncStream<Utterance>.makeStream(bufferingPolicy:.bufferingNewest(1))
        let audioContinuation = continuation!
        let input = engine.inputNode, format = input.outputFormat(forBus:0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError("No microphone is available.") }
        startStopMonitor()
        let feed = monitorFeed
        sequence = AudioSequence()
        let sequence = self.sequence, gate = captureGate, pushMode = self.pushMode
        input.installTap(onBus:0,bufferSize:1024,format:format) { buffer,_ in
          gate.capture {
            feed.append(buffer)
            guard let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
            var mono = [Float](repeating:0,count:count)
            for channel in 0..<channelCount { for i in 0..<count { mono[i] += channels[channel][i]/Float(channelCount) } }
            audioContinuation.yield(AudioChunk(samples:mono,rate:buffer.format.sampleRate,
                sequence:sequence.next(),receivedAt:MonotonicTime.now))
          }
        }
        tapInstalled = true
        do { engine.prepare(); try engine.start() }
        catch { stop(); throw VoiceError("The microphone could not start. Check the selected input device.") }
        segmentation = Task.detached(priority:.userInitiated) { [weak self] in
            var segmenter = UtteranceSegmenter()
            var held = PushToTalkBuffer()
            var continuity = AudioContinuity()
            let converter = AudioConverter()
            defer { utterances.continuation.finish() }
            func fail(_ message: String) async {
                await self?.segmentationFailed(message,run:run)
            }
            for await chunk in stream {
                if Task.isCancelled { break }
                guard continuity.accept(sequence:chunk.sequence) else {
                    await fail("Microphone audio was interrupted. Start again and repeat the full command."); return
                }
                do {
                    if pushMode {
                        if chunk.end {
                            utterances.continuation.yield(Utterance(samples:held.finish(),endedAt:chunk.receivedAt))
                        } else {
                            try held.append(converter.resample(chunk.samples,from:chunk.rate))
                        }
                        continue
                    }
                    let samples = try converter.resample(chunk.samples,from:chunk.rate)
                    if let complete = segmenter.append(samples) {
                        utterances.continuation.yield(Utterance(samples:complete,endedAt:chunk.receivedAt-segmenter.completedTrailingSilence))
                    }
                    if segmenter.discardedUtterances > 0 {
                        await fail("That utterance was too long. Start again and keep each command under 15 seconds."); return
                    }
                } catch { await fail("Microphone audio could not be converted. Check your input device and start again."); return }
            }
        }
        processing = Task { [weak self] in
            guard let self else { return }
            for await utterance in utterances.stream {
                guard !Task.isCancelled, generation == run else { return }
                if utterance.samples.isEmpty {
                    onTranscript(SpeechTranscript(text:"",inferenceMilliseconds:0,endToTranscriptMilliseconds:0)); continue
                }
                guard SpeechFreshness.accepts(endedAt:utterance.endedAt,now:MonotonicTime.now) else {
                    onError("Speech was delayed. Start again and repeat your command."); return
                }
                onTranscribing()
                let start = MonotonicTime.now
                do {
                    var decoder = try TdtDecoderState()
                    let result = try await manager.transcribe(utterance.samples,decoderState:&decoder)
                    guard !Task.isCancelled, generation == run else { return }
                    let ms = (MonotonicTime.now-start)*1000
                    guard SpeechFreshness.accepts(endedAt:utterance.endedAt,now:MonotonicTime.now) else {
                        onError("Transcription took too long. Start again and repeat your command."); return
                    }
                    startStopMonitor()
                    onTranscript(SpeechTranscript(text:result.text,inferenceMilliseconds:ms,
                        endToTranscriptMilliseconds:(MonotonicTime.now-utterance.endedAt)*1000))
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
    private func segmentationFailed(_ message: String, run: UUID) {
        guard generation == run else { return }; onError(message)
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
private struct AudioChunk: Sendable {
    let samples: [Float]; let rate: Double; let sequence: UInt64; let receivedAt: TimeInterval
    var end = false
}
private final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    func set(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
    func capture(_ body: () -> Void) { lock.lock(); defer { lock.unlock() }; if enabled { body() } }
    func close(_ body: () -> Void) { lock.lock(); defer { lock.unlock() }; enabled = false; body() }
}
private struct Utterance: Sendable { let samples: [Float]; let endedAt: TimeInterval }
private final class AudioSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; let n = value; value &+= 1; return n }
}
/// Recognition request append is documented for audio callbacks; protect replacement against Stop.
private final class RecognitionFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func set(_ next: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request?.endAudio(); request = next; lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); request?.append(buffer); lock.unlock() }
}
