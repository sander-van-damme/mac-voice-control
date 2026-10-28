import XCTest
import Combine
import AppKit
import VoiceCore
@testable import MacVoice

@MainActor private final class FakeSpeech: SpeechProviding {
    var ready = false
    var onTranscript: (SpeechTranscript) -> Void = { _ in }
    var onStop: () -> Void = {}
    var onError: (String) -> Void = { _ in }
    var onTranscribing: () -> Void = {}
    var prepareBody: () async throws -> Void = {}
    var starts = 0, stops = 0, preparations = 0
    func prepare(progress: @escaping @Sendable (Double,String) -> Void) async throws {
        preparations += 1; progress(0.5,"Preparing fixture")
        try await prepareBody(); ready = true
    }
    func start() throws { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor final class AppModelTests: XCTestCase {
    func testOverlayAnchorSurvivesRepeatedContentAndConfirmationChanges() async throws {
        _ = NSApplication.shared
        let model = AppModel(speech:FakeSpeech(),hasKey:{ false })
        let overlay = StatusOverlay(model:model)
        defer { overlay.hide() }
        overlay.show(); let initial = overlay.frame.minY
        for index in 0..<30 {
            model.transcript = String(repeating:"Changing transcript ",count:index % 8)
            model.pending = index % 2 == 0 ? "Confirm fixture action" : nil
            model.pendingImage = index % 3 == 0 ? Data([1]) : nil
            overlay.show()
            try await Task.sleep(nanoseconds:5_000_000)
            XCTAssertEqual(overlay.frame.minY,initial,accuracy:1)
        }
    }

    func testSleepStopsSessionAndRequiresExplicitRestart() async {
        let speech = FakeSpeech()
        let tested = AppModel(speech:speech,hasKey:{ false })
        tested.listening = true
        let stopped = expectation(description:"Sleep stopped listening")
        let subscription = tested.$listening.dropFirst().filter { !$0 }.sink { _ in stopped.fulfill() }
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.willSleepNotification,object:nil)
        await fulfillment(of:[stopped],timeout:3)
        XCTAssertFalse(tested.listening); XCTAssertEqual(tested.phase,.stopped); XCTAssertEqual(speech.stops,1)
        withExtendedLifetime(subscription) {}
    }
    func testDownloadSuccessUpdatesActualSetupModelWithoutNetwork() async throws {
        let speech = FakeSpeech()
        let tested = AppModel(speech:speech,hasKey:{ false })
        let ready = expectation(description:"Model ready")
        let subscription = tested.$modelReady.filter { $0 }.sink { _ in ready.fulfill() }
        tested.downloadModel()
        await fulfillment(of:[ready],timeout:3)
        XCTAssertEqual(speech.preparations,1); XCTAssertTrue(tested.modelReady)
        XCTAssertEqual(tested.modelProgress,1); XCTAssertFalse(tested.downloading)
        withExtendedLifetime(subscription) {}
    }
    func testCancelledDownloadNeverMarksReadyAndCanRetry() async throws {
        let speech = FakeSpeech()
        let tested = AppModel(speech:speech,hasKey:{ false })
        let began = expectation(description:"Preparation began")
        speech.prepareBody = { began.fulfill(); try await Task.sleep(nanoseconds:30_000_000_000) }
        let finished = expectation(description:"Cancellation processed")
        let subscription = tested.$downloading.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        tested.downloadModel()
        await fulfillment(of:[began],timeout:3)
        tested.cancelDownload()
        await fulfillment(of:[finished],timeout:3)
        subscription.cancel()
        XCTAssertFalse(tested.modelReady); XCTAssertFalse(tested.downloading)
        XCTAssertTrue(tested.downloadMessage.contains("cancelled"))
        speech.prepareBody = {}
        let retried = expectation(description:"Retry prepared")
        let retry = tested.$modelReady.filter { $0 }.sink { _ in retried.fulfill() }
        tested.downloadModel()
        await fulfillment(of:[retried],timeout:3)
        XCTAssertTrue(tested.modelReady); XCTAssertEqual(speech.preparations,2)
        withExtendedLifetime(retry) {}
    }
    func testStopDiscardsLateSpeechAndClearsPrivatePreviews() {
        let speech = FakeSpeech()
        let tested = AppModel(speech:speech,hasKey:{ false })
        tested.pending = "Old action"; tested.pendingImage = Data([1]); tested.pendingMarker = Point(0.5,0.5)
        tested.stop()
        speech.onTranscript(SpeechTranscript(text:"Hey Jev, open Chrome",inferenceMilliseconds:10,endToTranscriptMilliseconds:20))
        XCTAssertFalse(tested.listening); XCTAssertEqual(tested.phase,.stopped)
        XCTAssertNil(tested.pending); XCTAssertNil(tested.pendingImage); XCTAssertNil(tested.pendingMarker)
        XCTAssertTrue(tested.transcript.isEmpty); XCTAssertEqual(speech.starts,0); XCTAssertEqual(speech.stops,1)
        XCTAssertTrue(tested.timings.isEmpty)
    }
    func testLocalSpeechFailureStopsMicrophoneAndShowsFeedback() {
        let speech = FakeSpeech()
        let model = AppModel(speech:speech,hasKey:{ false })
        speech.onError("Microphone disconnected")
        XCTAssertEqual(model.phase,.failed); XCTAssertFalse(model.listening)
        XCTAssertEqual(model.message,"Microphone disconnected"); XCTAssertEqual(speech.stops,1)
    }
}
