import Foundation
import Combine
import LocalScribeCore

// Platform/audio fixtures let this executable exercise the actual controller's
// suspension points and state transitions without opening a physical microphone.
struct UIBackgroundTaskIdentifier: Equatable {
    let value: Int
    static let invalid = Self(value: -1)
}
@MainActor final class UIApplication {
    static let shared = UIApplication()
    static let didReceiveMemoryWarningNotification = Notification.Name("ControllerFixtureMemoryWarning")
    func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier { .init(value: 1) }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {}
}
struct EnginePerformanceReport: Sendable {}
protocol PerformanceReportingEngine: LocalTranscriptionEngine {
    func performanceReports() async -> [EnginePerformanceReport]
}
enum RecordingError: LocalizedError {
    case noAudio, conversionFailed
    var errorDescription: String? { "Audio capture failed." }
}
struct FixtureCaptureSnapshot {
    var receivedSamples: Int64 = 0
    var overflowSamples: Int64 = 0
    var processingFailureCount = 0
}
@MainActor final class AudioRecorder {
    static var latest: AudioRecorder?
    var preferBuiltInMicrophone = false
    var hapticFeedbackEnabled = false
    var onLevel: ((Float) -> Void)?
    var onOverflow: ((Int) -> Void)?
    var onCaptureFailure: ((RecordingError) -> Void)?
    var onInterruption: (() -> Void)?
    var armContinuation: CheckedContinuation<Void, Never>?
    static var holdNextArm = false
    static var samplesOnBeginCapture = 0
    var captureSnapshot = FixtureCaptureSnapshot()
    var pending: [Float] = []
    var recording = false
    var armed = false
    init() { Self.latest = self }
    func arm() async throws {
        if Self.holdNextArm {
            Self.holdNextArm = false
            await withCheckedContinuation { armContinuation = $0 }
        }
        armed = true
    }
    func beginCapture() {
        captureSnapshot = .init(); pending = []; recording = true
        feed(Self.samplesOnBeginCapture)
    }
    func drainCapture(minimumSamples: Int, maximumSamples: Int) -> [Float] {
        guard pending.count >= minimumSamples else { return [] }
        let count = min(pending.count, maximumSamples)
        let result = Array(pending.prefix(count))
        pending.removeFirst(count)
        return result
    }
    func endCapture(keepEngineRunning: Bool) -> [Float] {
        let result = pending; pending = []; recording = false
        if !keepEngineRunning { shutdown() }
        return result
    }
    func shutdown() { armed = false; recording = false; pending = [] }
    func feed(_ count: Int) {
        pending.append(contentsOf: repeatElement(0.1, count: count))
        captureSnapshot.receivedSamples += Int64(count)
    }
}

actor LifecycleEngine: StreamingLocalTranscriptionEngine, BackgroundInferenceReportingEngine {
    var cpuBackgroundEnabled = true
    func supportsBackgroundInference(for model: SpeechModel) async -> Bool { cpuBackgroundEnabled && model == .parakeetRealtimeEOU }
    func disableCPUBackground() { cpuBackgroundEnabled = false }
    var installed: Set<SpeechModel> = [.parakeetPhonon, .parakeetPhononG4, .parakeetRealtimeEOU]
    var holdPreparation = true
    var loadContinuation: CheckedContinuation<Void, Never>?
    var prepareCalls = 0
    var beginCalls = 0
    var unloadCalls = 0
    var admittedSamples = 0
    var largestAppend = 0
    var failAppend = false
    var callback: (@Sendable (SpeechTranscriptUpdate) -> Void)?
    var oldCallback: (@Sendable (SpeechTranscriptUpdate) -> Void)?
    func isInstalled(_ model: SpeechModel) async -> Bool { installed.contains(model) }
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func prepare(_ model: SpeechModel) async throws {
        prepareCalls += 1
        if holdPreparation { await withCheckedContinuation { loadContinuation = $0 } }
        try Task.checkCancellation()
    }
    func releasePreparation() { holdPreparation = false; loadContinuation?.resume(); loadContinuation = nil }
    func beginStreaming(onUpdate: @escaping @Sendable (SpeechTranscriptUpdate) -> Void) async throws {
        beginCalls += 1; admittedSamples = 0; oldCallback = callback; callback = onUpdate
    }
    func appendStreaming(samples: [Float]) async throws {
        if failAppend { throw Failure.expected }
        admittedSamples += samples.count; largestAppend = max(largestAppend, samples.count)
        callback?(.init(confirmedText: "Captured", volatileText: "words"))
    }
    func finishStreaming() async throws -> String { "Captured words." }
    func cancelStreaming() async { oldCallback = callback; callback = nil }
    func transcribe(samples: [Float]) async throws -> String { "Unused offline API" }
    func unload() async { unloadCalls += 1 }
    func emitStale() { oldCallback?(.init(confirmedText: "Stale", volatileText: "utterance")) }
    func failNextAppend() { failAppend = true }
    func counts() -> (Int, Int, Int, Int, Int) { (prepareCalls, beginCalls, unloadCalls, admittedSamples, largestAppend) }
    enum Failure: Error { case expected }
}

#if os(macOS)
extension SharedKeyboardStore {
    static func appGroupStore() throws -> SharedKeyboardStore { throw StoreError.unavailable }
}
#endif

@main struct AppControllerLifecycleCheck {
    enum CheckFailure: Error { case failed(String) }
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure.failed(message) }
        checks += 1
    }
    @MainActor static func eventually(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure.failed("Timed out waiting for controller transition")
    }
    @MainActor static func fixture(_ engine: LifecycleEngine, model: SpeechModel = .parakeetPhonon) async -> AppController {
        let defaults = UserDefaults(suiteName: "LocalScribeControllerCheck-\(UUID())")!
        defaults.set(false, forKey: "saveHistory")
        defaults.set(model.rawValue, forKey: "selectedModel")
        let history = FileManager.default.temporaryDirectory.appendingPathComponent("LocalScribeControllerCheck-\(UUID())/history.json")
        let controller = AppController(engine: engine, defaults: defaults, historyURL: history)
        await controller.refreshInstalledModels()
        return controller
    }
    @MainActor static func main() async throws {
        let engine = LifecycleEngine()
        let controller = await fixture(engine)
        let recorder = AudioRecorder.latest!
        try await eventually { await engine.counts().0 == 1 }
        try check(controller.phase == .idle, "Foreground prewarm leaves Record available")
        try check(controller.modelStatus != nil, "Only actual pending load has model status")
        await controller.startRecording()
        try check(controller.phase == .recording && recorder.recording, "Microphone starts before blocked model loading")
        recorder.feed(48_000)
        let stopping = Task { await controller.stopRecording() }
        try await eventually { controller.phase == .transcribing }
        try check(!recorder.recording, "Stop immediately ends capture during loading")
        await engine.releasePreparation()
        await stopping.value
        try check(controller.phase == .idle, "Stop during preparation completes cleanly")
        try check(controller.transcript == "Captured words.", "Cold-start queued speech is retained")
        let initial = await engine.counts()
        try check(initial.0 == 1 && initial.3 == 48_000, "Same-model prewarm coalesces and final tail is admitted exactly once")
        try check(initial.4 <= 32_000, "Finalization awaits bounded audio chunks")
        await controller.startRecording()
        recorder.feed(16_000 * 181)
        try await eventually { await engine.counts().3 >= 16_000 * 180 }
        try check(controller.phase == .recording, "Three-minute recording continues beyond old two-minute bound")
        try check(controller.partialText == "Captured words", "Live updates are current snapshots without duplicate concatenation")
        await controller.stopRecording()
        let warm = await engine.counts()
        try check(warm.0 == 1 && warm.2 == 0, "Repeated foreground recording retains the prepared model")
        try check(warm.3 == 16_000 * 181, "Long recording audio is neither truncated nor duplicated")
        await controller.startRecording()
        await engine.emitStale()
        try await Task.sleep(for: .milliseconds(30))
        try check(controller.partialText.isEmpty, "Old utterance callback cannot overwrite a new recording")
        recorder.feed(16_000)
        try await eventually { !controller.partialText.isEmpty }
        await engine.failNextAppend()
        recorder.feed(16_000)
        try await eventually { controller.phase == .idle }
        try check(controller.transcript == "Captured words", "Recognition failure preserves already delivered text")
        try check(controller.errorMessage != nil, "Recognition failure is visible")
        controller.setForeground(false)
        try await eventually { await engine.counts().2 > 0 }
        try check(controller.modelStatus == nil, "Background unload clears readiness/status")

        let blocked = LifecycleEngine()
        let cancelController = await fixture(blocked)
        let cancelRecorder = AudioRecorder.latest!
        AudioRecorder.holdNextArm = true
        let starting = Task { await cancelController.startRecording() }
        try await eventually { cancelController.phase == .preparing }
        await cancelController.cancelPreparation()
        cancelRecorder.armContinuation?.resume()
        await starting.value
        try check(cancelController.phase == .idle && !cancelRecorder.recording, "Cancelled permission continuation cannot begin stale capture")
        await blocked.releasePreparation()
        await cancelController.startRecording()
        cancelRecorder.feed(8_000)
        cancelRecorder.onInterruption?()
        try await eventually { cancelController.phase == .idle }
        try check(cancelController.transcript == "Captured words.", "Microphone interruption finishes queued speech")
        try check(cancelController.errorMessage?.contains("interrupted") == true, "Interruption remains explicit")
        cancelController.selectedModel = .parakeetUltra
        await cancelController.startRecording()
        try check(cancelController.phase == .idle && cancelController.errorMessage?.contains("Download") == true, "Missing model never starts microphone")

        cancelController.selectedModel = .parakeetPhonon
        await cancelController.startRecording()
        cancelRecorder.feed(8_000)
        cancelRecorder.captureSnapshot.overflowSamples = 1_600
        cancelRecorder.captureSnapshot.receivedSamples += 1_600
        await cancelController.stopRecording()
        try check(cancelController.errorMessage?.contains("0.10 seconds") == true, "Stop observes overflow counters even before callback delivery")
        try check(cancelController.transcript == "Captured words.", "Overflow retains buffered speech and finished text")
        await cancelController.startRecording()
        cancelRecorder.feed(8_000)
        cancelRecorder.captureSnapshot.processingFailureCount = 1
        await cancelController.stopRecording()
        try check(cancelController.errorMessage?.contains("conversion failed") == true, "Stop observes conversion failures even before callback delivery")

        let keyboardEngine = LifecycleEngine()
        await keyboardEngine.releasePreparation()
        let keyboardController = await fixture(keyboardEngine)
        let keyboardRecorder = AudioRecorder.latest!
        let shared = try SharedKeyboardStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("LocalScribeControllerKeyboardCheck-\(UUID())"))
        let bridge = KeyboardSessionCoordinator(controller: keyboardController, store: shared)
        await keyboardController.enableKeyboardSession()
        guard let firstStatus = try shared.readStatus(), let session = firstStatus.sessionID else { throw CheckFailure.failed("No keyboard lease") }
        let utterance = UUID()
        try shared.writeCommand(KeyboardCommand(sessionID: session, utteranceID: utterance, action: .start))
        try await eventually { keyboardController.phase == .recording }
        guard let active = try shared.readStatus() else { throw CheckFailure.failed("No active status") }
        try check(active.sessionID == session && active.utteranceID == utterance, "Start renews keyboard lease without replacing session/utterance")
        keyboardRecorder.feed(24_000)
        try shared.writeCommand(KeyboardCommand(sessionID: session, utteranceID: utterance, action: .stop))
        try await eventually { keyboardController.phase == .idle }
        guard let result = try shared.readStatus() else { throw CheckFailure.failed("No keyboard result") }
        try check(result.sessionID == session && result.utteranceID == utterance, "Stop renewal preserves command ownership")
        try check(result.transcript == "Captured words." && result.hasDeliverableResult(), "Renewed keyboard lease delivers completed text")
        try check((keyboardController.keyboardSessionExpiresAt?.timeIntervalSinceNow ?? 0) > 290, "Keyboard expiry is an idle timeout after completion")
        await keyboardController.finishKeyboardSession()
        try check(keyboardController.keyboardSessionExpiresAt == nil && !keyboardRecorder.armed, "Explicit End still stops microphone immediately")
        withExtendedLifetime(bridge) {}

        let actionEngine = LifecycleEngine()
        await actionEngine.releasePreparation()
        let actionController = await fixture(actionEngine)
        let actionRecorder = AudioRecorder.latest!
        await actionController.startActionButtonRecording()
        try check(actionController.actionButtonRecording && actionController.phase == .recording, "Shortcut explicitly owns microphone recording")
        actionRecorder.feed(16_000)
        try await eventually { await actionEngine.counts().3 == 16_000 }
        actionController.setForeground(false)
        try await Task.sleep(for: .milliseconds(200))
        let backgroundSamples = await actionEngine.counts().3
        actionRecorder.feed(32_000)
        try await Task.sleep(for: .milliseconds(250))
        try check(actionController.phase == .recording && actionRecorder.recording, "Action recording continues background capture")
        let pausedSamples = await actionEngine.counts().3
        try check(pausedSamples == backgroundSamples, "Action recording submits no new background inference")
        let actionStopping = Task { await actionController.stopActionButtonRecording() }
        try await eventually { actionController.phase == .transcribing }
        try check(!actionRecorder.recording, "Action Stop ends the microphone before foreground recognition resumes")
        try await Task.sleep(for: .milliseconds(150))
        let finishingPausedSamples = await actionEngine.counts().3
        try check(finishingPausedSamples == backgroundSamples, "Action finalization waits for foreground before submitting queued speech")
        actionController.setForeground(true)
        await actionStopping.value
        let finishedActionSamples = await actionEngine.counts().3
        try check(finishedActionSamples == 48_000, "Foreground Action Stop drains all buffered speech in order")
        try check(actionController.transcript == "Captured words." && !actionController.actionButtonRecording, "Action completion preserves text and releases ownership")

        let automationEngine = LifecycleEngine()
        let automation = AppController(engine: automationEngine, verificationMode: true)
        await automation.refreshInstalledModels()
        await automation.startRecording()
        automation.setForeground(false)
        try await Task.sleep(for: .milliseconds(50))
        let automationCounts = await automationEngine.counts()
        try check(automationCounts.0 == 0 && automationCounts.2 == 0 && automation.phase == .idle, "Verification runner exclusively owns engine and microphone")

        let cpuEngine = LifecycleEngine()
        await cpuEngine.releasePreparation()
        let cpuController = await fixture(cpuEngine, model: .parakeetRealtimeEOU)
        let cpuRecorder = AudioRecorder.latest!
        await cpuController.startActionButtonRecording()
        cpuRecorder.feed(16_000)
        try await eventually { await cpuEngine.counts().3 == 16_000 }
        cpuController.setForeground(false)
        cpuController.selectedModel = .parakeetPhonon
        cpuRecorder.feed(32_000)
        try await eventually { await cpuEngine.counts().3 == 48_000 }
        try check(cpuController.phase == .recording, "CPU Realtime keeps draining during background recording")
        try check(cpuRecorder.pending.isEmpty, "Background CPU recording retains bounded backpressure only")
        let cpuStopping = Task { await cpuController.stopActionButtonRecording() }
        await cpuStopping.value
        try check(cpuController.phase == .idle && cpuController.transcript == "Captured words.", "CPU finalization finishes in background using the captured model despite selection changes")
        cpuController.setForeground(true)

        let restrictedEngine = LifecycleEngine()
        await restrictedEngine.releasePreparation()
        await restrictedEngine.disableCPUBackground()
        let restrictedController = await fixture(restrictedEngine, model: .parakeetRealtimeEOU)
        let restrictedRecorder = AudioRecorder.latest!
        await restrictedController.startActionButtonRecording()
        restrictedRecorder.feed(16_000)
        try await eventually { await restrictedEngine.counts().3 == 16_000 }
        restrictedController.setForeground(false)
        restrictedRecorder.feed(16_000)
        try await Task.sleep(for: .milliseconds(250))
        let restrictedCount = await restrictedEngine.counts().3
        try check(restrictedCount == 16_000, "Realtime name alone grants no background inference when its engine reports false")
        restrictedController.setForeground(true)
        await restrictedController.stopActionButtonRecording()

        let pendingEngine = LifecycleEngine()
        await pendingEngine.releasePreparation()
        let pendingController = await fixture(pendingEngine, model: .parakeetRealtimeEOU)
        let pendingRecorder = AudioRecorder.latest!
        AudioRecorder.holdNextArm = true
        let pendingStart = Task { await pendingController.startActionButtonRecording() }
        try await eventually { pendingController.phase == .preparing && pendingRecorder.armContinuation != nil }
        pendingController.setForeground(false)
        pendingRecorder.armContinuation?.resume()
        await pendingStart.value
        try check(pendingController.phase == .idle && !pendingController.actionButtonRecording && !pendingRecorder.recording, "Shortcut never activates a pending permission microphone after leaving foreground")
        print("PASS: \(checks) actual AppController lifecycle checks")
    }
}
