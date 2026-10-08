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
    var microphonePermissionGranted = true
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
    var armCalls = 0
    init() { Self.latest = self }
    private(set) var lastMixWithOtherAudio = false
    func arm(requireExistingPermission: Bool = false, mixWithOtherAudio: Bool = false) async throws {
        armCalls += 1
        lastMixWithOtherAudio = mixWithOtherAudio
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

// The controller script inserts wait() at the scheduling boundary of the actual
// production event Task; its recording-ID validation and stop path remain intact.
@MainActor enum FixtureAudioEventGate {
    static var held = false
    static var continuations: [CheckedContinuation<Void, Never>] = []
    static func wait() async {
        if held { await withCheckedContinuation { continuations.append($0) } }
    }
    static func release() {
        held = false
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }
}

@MainActor enum FixturePrewarmGate {
    static var held = false
    static var continuations: [CheckedContinuation<Void, Never>] = []
    static func wait() async {
        if held { await withCheckedContinuation { continuations.append($0) } }
    }
    static func release() {
        held = false
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }
}

actor LifecycleEngine: StreamingLocalTranscriptionEngine, BackgroundInferenceReportingEngine {
    var cpuBackgroundEnabled = true
    private var capabilityCalls = 0
    private var heldCapabilityCall: Int?
    private var capabilityContinuation: CheckedContinuation<Void, Never>?
    func holdNextBackgroundCapability(skip: Int = 0) { heldCapabilityCall = capabilityCalls + 1 + skip }
    func backgroundCapabilityIsHeld() -> Bool { capabilityContinuation != nil }
    func releaseBackgroundCapability() {
        heldCapabilityCall = nil
        capabilityContinuation?.resume()
        capabilityContinuation = nil
    }
    func supportsBackgroundInference(for model: SpeechModel) async -> Bool {
        capabilityCalls += 1
        if heldCapabilityCall == capabilityCalls {
            await withCheckedContinuation { capabilityContinuation = $0 }
        }
        return cpuBackgroundEnabled && model == .parakeetRealtimeEOU
    }
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
    var downloaded: [SpeechModel] = []
    var prepared: [SpeechModel] = []
    var downloadFailure: SpeechModel?
    var slowDownload = false
    var slowDownloadModel: SpeechModel?
    func configureDownloads(failure: SpeechModel? = nil, slow: Bool = false, slowModel: SpeechModel? = nil) { downloadFailure = failure; slowDownload = slow; slowDownloadModel = slowModel }
    func downloads() -> [SpeechModel] { downloaded }
    func preparations() -> [SpeechModel] { prepared }
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        downloaded.append(model)
        progress(0.25)
        if slowDownload || slowDownloadModel == model { try await Task.sleep(for: .seconds(10)) }
        try Task.checkCancellation()
        if downloadFailure == model { throw Failure.expected }
        installed.insert(model)
        progress(1)
    }
    func prepare(_ model: SpeechModel) async throws {
        prepareCalls += 1; prepared.append(model)
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
    var holdFinish = false
    var finishContinuation: CheckedContinuation<Void, Never>?
    func holdFinalization() { holdFinish = true }
    func finalizationIsHeld() -> Bool { finishContinuation != nil }
    func releaseFinalization() { holdFinish = false; finishContinuation?.resume(); finishContinuation = nil }
    func finishStreaming() async throws -> String {
        if holdFinish { await withCheckedContinuation { finishContinuation = $0 } }
        return "Captured words."
    }
    private var holdCancellation = false
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    func holdNextStreamCancellation() { holdCancellation = true }
    func streamCancellationIsHeld() -> Bool { cancellationContinuation != nil }
    func releaseStreamCancellation() { cancellationContinuation?.resume(); cancellationContinuation = nil }
    func cancelStreaming() async {
        if holdCancellation {
            holdCancellation = false
            await withCheckedContinuation { cancellationContinuation = $0 }
        }
        oldCallback = callback; callback = nil
    }
    func transcribe(samples: [Float]) async throws -> String { "Unused offline API" }
    func unload() async { unloadCalls += 1 }
    func emitStale() { oldCallback?(.init(confirmedText: "Stale", volatileText: "utterance")) }
    func failNextAppend() { failAppend = true }
    func counts() -> (Int, Int, Int, Int, Int) { (prepareCalls, beginCalls, unloadCalls, admittedSamples, largestAppend) }
    enum Failure: Error { case expected }
}

actor ContextualLifecycleEngine: StreamingLocalTranscriptionEngine, ContextualLocalTranscriptionEngine {
    let engine = LifecycleEngine()
    private var requestedPreparations: [(SpeechModel, ModelExecutionContext)] = []
    private var failBackgroundPreparation = false
    func failNextBackgroundPreparation() { failBackgroundPreparation = true }
    func preparationRequests() -> [(SpeechModel, ModelExecutionContext)] { requestedPreparations }
    func isInstalled(_ model: SpeechModel) async -> Bool { await engine.isInstalled(model) }
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws { try await engine.download(model, progress: progress) }
    func prepare(_ model: SpeechModel) async throws { try await prepare(model, context: .foreground) }
    func prepare(_ model: SpeechModel, context: ModelExecutionContext) async throws {
        requestedPreparations.append((model, context.normalized(for: model)))
        if failBackgroundPreparation, context == .backgroundCapable {
            failBackgroundPreparation = false
            throw LifecycleEngine.Failure.expected
        }
        try await engine.prepare(model)
    }
    func supportsBackgroundInference(for model: SpeechModel, context: ModelExecutionContext) async -> Bool {
        let defaultCapability = await engine.supportsBackgroundInference(for: model)
        return context == .backgroundCapable || defaultCapability
    }
    func beginStreaming(onUpdate: @escaping @Sendable (SpeechTranscriptUpdate) -> Void) async throws { try await engine.beginStreaming(onUpdate: onUpdate) }
    func appendStreaming(samples: [Float]) async throws { try await engine.appendStreaming(samples: samples) }
    func finishStreaming() async throws -> String { try await engine.finishStreaming() }
    func cancelStreaming() async { await engine.cancelStreaming() }
    func transcribe(samples: [Float]) async throws -> String { "Unused offline API" }
    func unload() async { await engine.unload() }
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
    @MainActor static func eventually(file: StaticString = #filePath, line: UInt = #line, _ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure.failed("Timed out waiting for controller transition at \(file):\(line)")
    }
    @MainActor static func fixture(_ engine: any LocalTranscriptionEngine, model: SpeechModel = .parakeetPhonon, preferences: UserDefaults? = nil) async -> AppController {
        let defaults = preferences ?? UserDefaults(suiteName: "LocalScribeControllerCheck-\(UUID())")!
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
        let retained = await engine.counts()
        try check(controller.keepModelLoaded && retained.2 == 0 && controller.preparedModel == .parakeetPhonon, "Default retention keeps idle background model ready")
        try check(!recorder.armed && !recorder.recording, "Idle background retention never keeps the microphone active")
        controller.keepModelLoaded = false
        try await eventually { await engine.counts().2 > 0 }
        try check(controller.preparedModel == nil && controller.modelStatus == nil, "Turning retention off clears readiness and releases background runtime")

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

        let startupEngine = LifecycleEngine()
        await startupEngine.releasePreparation()
        let startupController = await fixture(startupEngine, model: .parakeetRealtimeEOU)
        let startupRecorder = AudioRecorder.latest!
        for skip in [0, 1] {
            let requestID = UUID()
            let initialArmCalls = startupRecorder.armCalls
            await startupEngine.holdNextBackgroundCapability(skip: skip)
            let pendingStart = Task { await startupController.startActionButtonRecording(requestID: requestID) }
            try await eventually { await startupEngine.backgroundCapabilityIsHeld() }
            try check(!startupRecorder.recording && startupController.currentRecordingID == nil,
                      "Held Action capability discovery has no capture owner")
            await startupController.cancelActionButtonRecording(requestID: requestID)
            await startupEngine.releaseBackgroundCapability()
            await pendingStart.value
            try check(startupController.phase == .idle && !startupController.actionButtonRecording && !startupRecorder.recording && !startupRecorder.armed,
                      "Cancellation before capability await \(skip + 1) resumes leaves no orphan Action capture")
            try check(startupRecorder.armCalls == initialArmCalls && startupController.completedRecordingID == nil && startupController.history.isEmpty,
                      "Cancelled startup opens no microphone and saves no result")
        }

        await startupController.startRecording()
        await startupEngine.holdNextStreamCancellation()
        let previousCleanup = Task { await startupController.cancelRecording() }
        try await eventually { await startupEngine.streamCancellationIsHeld() }
        let cleanupWaitRequestID = UUID()
        let initialCleanupArmCalls = startupRecorder.armCalls
        let cleanupWaitStart = Task { await startupController.startActionButtonRecording(requestID: cleanupWaitRequestID) }
        try await eventually { startupController.phase == .idle && startupController.actionButtonRecording }
        await startupController.cancelActionButtonRecording(requestID: cleanupWaitRequestID)
        await startupEngine.releaseStreamCancellation()
        await previousCleanup.value
        await cleanupWaitStart.value
        try check(startupController.phase == .idle && !startupController.actionButtonRecording && !startupRecorder.recording && !startupRecorder.armed
                  && startupRecorder.armCalls == initialCleanupArmCalls,
                  "Action startup canceled while awaiting previous cleanup cannot activate capture afterward")

        let retiredActionID = UUID()
        await startupEngine.holdNextBackgroundCapability()
        let retiredAction = Task { await startupController.startActionButtonRecording(requestID: retiredActionID) }
        try await eventually { await startupEngine.backgroundCapabilityIsHeld() }
        await startupController.cancelActionButtonRecording(requestID: retiredActionID)
        let replacementActionID = UUID()
        await startupController.startActionButtonRecording(requestID: replacementActionID)
        let replacementRecordingID = startupController.currentRecordingID
        await startupEngine.releaseBackgroundCapability()
        await retiredAction.value
        await startupController.cancelActionButtonRecording(requestID: retiredActionID)
        try check(startupController.phase == .recording && startupController.actionButtonRecording && startupRecorder.recording
                  && startupController.currentRecordingID == replacementRecordingID,
                  "Cancelled pending Action A and late A cleanup cannot retire Action B")
        await startupController.cancelActionButtonRecording(requestID: replacementActionID)

        let pendingActionID = UUID()
        await startupEngine.holdNextBackgroundCapability()
        let pendingAction = Task { await startupController.startActionButtonRecording(requestID: pendingActionID) }
        try await eventually { await startupEngine.backgroundCapabilityIsHeld() }
        await startupController.startRecording()
        let manualRecordingID = startupController.currentRecordingID
        await startupController.cancelActionButtonRecording(requestID: pendingActionID)
        await startupEngine.releaseBackgroundCapability()
        await pendingAction.value
        try check(startupController.phase == .recording && !startupController.actionButtonRecording && startupRecorder.recording
                  && startupController.currentRecordingID == manualRecordingID,
                  "Pending Action A cancellation and continuation cannot stop unrelated manual B")
        await startupController.cancelRecording()

        let lifecycleStops: [(String, () -> Void)] = [
            ("keyboard shutdown", { startupController.disableKeyboardSession() }),
            ("foreground exit", { startupController.setForeground(false) })
        ]
        for (name, emit) in lifecycleStops {
            startupController.setForeground(true)
            if name == "keyboard shutdown" { await startupController.enableKeyboardSession() }
            await startupController.startRecording()
            startupRecorder.feed(8_000)
            FixtureAudioEventGate.held = true
            emit()
            try await eventually { FixtureAudioEventGate.continuations.count == 1 }
            await startupController.stopRecording()
            let newActionRequest = UUID()
            await startupController.startActionButtonRecording(requestID: newActionRequest)
            let newActionRecording = startupController.currentRecordingID
            FixtureAudioEventGate.release()
            for _ in 0..<10 { await Task.yield() }
            try check(startupController.phase == .recording && startupController.actionButtonRecording && startupRecorder.recording
                      && startupController.currentRecordingID == newActionRecording,
                      "A's queued \(name) cannot stop newer Action B")
            await startupController.cancelActionButtonRecording(requestID: newActionRequest)

            startupController.setForeground(true)
            if name == "keyboard shutdown" { await startupController.enableKeyboardSession() }
            await startupController.startRecording()
            startupRecorder.feed(8_000)
            emit()
            try await eventually { startupController.phase == .idle }
            try check(!startupRecorder.recording && !startupRecorder.armed,
                      "Current \(name) still stops its manual capture")
        }
        startupController.setForeground(true)
        await startupEngine.holdNextBackgroundCapability()
        let preparingManual = Task { await startupController.startRecording() }
        try await eventually { await startupEngine.backgroundCapabilityIsHeld() }
        FixtureAudioEventGate.held = true
        startupController.setForeground(false)
        try await eventually { FixtureAudioEventGate.continuations.count == 1 }
        await startupController.cancelPreparation()
        await startupEngine.releaseBackgroundCapability()
        await preparingManual.value
        startupController.setForeground(true)
        await startupEngine.holdNextBackgroundCapability(skip: 1)
        let preparingActionID = UUID()
        let preparingAction = Task { await startupController.startActionButtonRecording(requestID: preparingActionID) }
        try await eventually { await startupEngine.backgroundCapabilityIsHeld() }
        FixtureAudioEventGate.release()
        for _ in 0..<10 { await Task.yield() }
        try check(startupController.phase == .preparing && startupController.actionButtonRecording,
                  "A's queued background preparation cancellation cannot cancel preparing Action B")
        await startupEngine.releaseBackgroundCapability()
        await preparingAction.value
        try check(startupController.phase == .recording && startupController.actionButtonRecording && startupRecorder.recording,
                  "Replacement Action B still activates after its capability discovery")
        await startupController.cancelActionButtonRecording(requestID: preparingActionID)

        startupController.setForeground(true)
        await startupEngine.holdNextBackgroundCapability()
        let currentManualPreparation = Task { await startupController.startRecording() }
        try await eventually { await startupEngine.backgroundCapabilityIsHeld() }
        startupController.setForeground(false)
        try await eventually { startupController.phase == .idle }
        await startupEngine.releaseBackgroundCapability()
        await currentManualPreparation.value
        try check(startupController.phase == .idle && !startupRecorder.recording && !startupRecorder.armed,
                  "Current foreground exit still cancels its manual microphone preparation")

        let eventEngine = LifecycleEngine()
        await eventEngine.releasePreparation()
        let eventController = await fixture(eventEngine)
        let eventRecorder = AudioRecorder.latest!
        let events: [(String, () -> Void)] = [
            ("interruption", { eventRecorder.onInterruption?() }),
            ("overflow", { eventRecorder.onOverflow?(1_600) }),
            ("conversion failure", { eventRecorder.onCaptureFailure?(.conversionFailed) })
        ]
        for (name, emit) in events {
            await eventController.startRecording()
            eventRecorder.feed(8_000)
            let firstID = eventController.currentRecordingID
            FixtureAudioEventGate.held = true
            emit()
            try await eventually { FixtureAudioEventGate.continuations.count == 1 }
            await eventController.stopRecording()
            try check(eventController.phase == .idle && eventController.completedRecordingID == firstID,
                      "A finalizes while its queued \(name) stop is withheld")
            await eventController.startRecording()
            let replacementID = eventController.currentRecordingID
            try check(replacementID != nil && replacementID != firstID, "B starts with a fresh recording owner after \(name) in A")
            FixtureAudioEventGate.release()
            for _ in 0..<10 { await Task.yield() }
            try check(eventController.phase == .recording && eventController.currentRecordingID == replacementID && eventRecorder.recording,
                      "A's late queued \(name) stop cannot end B")
            try check(eventController.errorMessage == nil, "A's \(name) warning does not contaminate B")
            eventRecorder.feed(8_000)
            emit()
            try await eventually { eventController.phase == .idle }
            try check(eventController.completedRecordingID == replacementID && !eventRecorder.recording && eventController.errorMessage != nil,
                      "Genuine B \(name) still stops capture and reports its warning")
        }
        await eventController.startRecording()
        FixtureAudioEventGate.held = true
        eventRecorder.onInterruption?()
        try await eventually { FixtureAudioEventGate.continuations.count == 1 }
        await eventController.cancelRecording()
        await eventController.startRecording()
        let postCancellationID = eventController.currentRecordingID
        FixtureAudioEventGate.release()
        for _ in 0..<10 { await Task.yield() }
        try check(eventController.phase == .recording && eventController.currentRecordingID == postCancellationID && eventRecorder.recording,
                  "Canceled A's queued interruption cannot stop its replacement")
        await eventController.cancelRecording()
        await eventController.enableKeyboardSession()
        eventRecorder.onInterruption?()
        try check(!eventController.keyboardSessionActive && !eventRecorder.armed,
                  "A current idle-keyboard interruption still shuts down its microphone lease")

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
        actionController.setForeground(false)
        await actionController.startActionButtonRecording()
        try check(actionController.phase == .idle && !actionController.actionButtonRecording, "Background Action rejects accelerated model before capture")
        let rejectedBeginCount = await actionEngine.counts().1
        try check(rejectedBeginCount == 0, "Rejected Action model never starts recognition")

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
        restrictedController.setForeground(false)
        await restrictedController.startActionButtonRecording()
        try check(restrictedController.phase == .idle && !restrictedRecorder.recording, "CPU model name grants no background permission when runtime denies it")

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
        try check(pendingController.phase == .recording && pendingController.actionButtonRecording && pendingRecorder.recording, "Preauthorized Action start remains valid when caller stays foreground")
        await pendingController.cancelRecording()
        let downloadEngine = LifecycleEngine()
        await downloadEngine.releasePreparation()
        let downloads = await fixture(downloadEngine)
        try await eventually { downloads.preparedModel == .parakeetPhonon }
        await downloads.downloadAllMissingModels()
        try check(downloads.selectedModel == .parakeetPhonon, "Bulk installation preserves selected model")
        try check(downloads.installedModels.count == SpeechModel.allCases.count, "Bulk downloads install every missing catalog model")
        let installedSequence = await downloadEngine.downloads()
        try check(Set(installedSequence).count == installedSequence.count && !installedSequence.contains(.parakeetPhonon), "Bulk queue skips installed models and downloads each missing model once")
        let preparedSequence = await downloadEngine.preparations()
        try check(preparedSequence == [.parakeetPhonon], "Installing models never prepares unselected runtimes")

        let partialEngine = LifecycleEngine()
        await partialEngine.releasePreparation()
        let partialDownloads = await fixture(partialEngine)
        let missing = SpeechModel.allCases.filter { !partialDownloads.installedModels.contains($0) }
        await partialEngine.configureDownloads(slowModel: missing[1])
        let partialQueue = Task { await partialDownloads.downloadAllMissingModels() }
        try await eventually { partialDownloads.downloadingModel == missing[1] }
        partialDownloads.cancelDownload()
        await partialQueue.value
        try check(partialDownloads.installedModels.contains(missing[0]) && !partialDownloads.installedModels.contains(missing[1]), "Bulk cancellation retains completed installation and excludes partial model")
        let cancelledQueue = await partialEngine.downloads()
        try check(cancelledQueue == Array(missing.prefix(2)), "Bulk cancellation prevents later queued downloads")
        try check(partialDownloads.selectedModel == .parakeetPhonon, "Bulk cancellation preserves selection")

        let failureEngine = LifecycleEngine()
        await failureEngine.releasePreparation()
        await failureEngine.configureDownloads(failure: .parakeetUltra)
        let failingDownloads = await fixture(failureEngine)
        await failingDownloads.download(.parakeetUltra)
        try check(failingDownloads.failedDownloadModel == .parakeetUltra && failingDownloads.errorMessage != nil, "Download failure identifies retry model")
        try check(!failingDownloads.installedModels.contains(.parakeetUltra) && failingDownloads.selectedModel == .parakeetPhonon, "Failed download neither installs nor selects model")
        await failureEngine.configureDownloads(slow: true)
        let cancellingDownload = Task { await failingDownloads.download(.parakeetUltra) }
        try await eventually { failingDownloads.downloadingModel == .parakeetUltra }
        failingDownloads.cancelDownload()
        await cancellingDownload.value
        try check(failingDownloads.downloadCancelled && failingDownloads.downloadingModel == nil, "Cancellation waits for download operation to exit before clearing busy state")
        try check(!failingDownloads.installedModels.contains(.parakeetUltra), "Cancelled partial download is never marked installed")
        await failureEngine.configureDownloads()
        await failingDownloads.download(.parakeetUltra)
        try check(failingDownloads.installedModels.contains(.parakeetUltra) && failingDownloads.selectedModel == .parakeetPhonon, "Retry installs without changing selection")

        // Exercise the preference through actual recording, background transitions,
        // cancellation and the production memory-warning observer.
        let retentionDefaults = UserDefaults(suiteName: "LocalScribeRetentionCheck-\(UUID())")!
        retentionDefaults.set(false, forKey: "keepModelLoaded")
        let retainedEngine = LifecycleEngine()
        await retainedEngine.releasePreparation()
        let retainedController = await fixture(retainedEngine, preferences: retentionDefaults)
        let retainedRecorder = AudioRecorder.latest!
        try check(!retainedController.keepModelLoaded, "Saved OFF preference survives controller recreation")
        let coldCounts = await retainedEngine.counts()
        try check(coldCounts.0 == 0 && retainedController.preparedModel == nil, "OFF does not prewarm during installation refresh")
        retainedController.keepModelLoaded = true
        try await eventually { retainedController.preparedModel == .parakeetPhonon }
        try check(retentionDefaults.bool(forKey: "keepModelLoaded"), "ON preference is persisted")
        retainedController.setForeground(false)
        retainedController.setForeground(true)
        await retainedController.refreshInstalledModels()
        await retainedController.startRecording()
        retainedRecorder.feed(8_000)
        await retainedController.stopRecording()
        let reused = await retainedEngine.counts()
        try check(reused.0 == 1 && reused.2 == 0, "Background return and next dictation reuse the same warm model")
        await retainedController.startRecording()
        retainedRecorder.feed(8_000)
        retainedController.keepModelLoaded = false
        try check(retainedController.phase == .recording && retainedRecorder.recording && retainedController.preparedModel != nil, "OFF during capture defers release until finalization")
        await retainedController.stopRecording()
        try await eventually { await retainedEngine.counts().2 > 0 }
        try check(retainedController.transcript == "Captured words." && retainedController.preparedModel == nil, "OFF finalizes speech then unloads")
        await retainedController.startRecording()
        retainedRecorder.feed(8_000)
        await retainedController.stopRecording()
        let onDemand = await retainedEngine.counts()
        try check(onDemand.0 == 2, "OFF loads on demand for the next recording")
        retainedController.keepModelLoaded = true
        try await eventually { retainedController.preparedModel == .parakeetPhonon }
        retainedController.selectedModel = .parakeetPhononG4
        try await eventually { retainedController.preparedModel == .parakeetPhononG4 }
        let switched = await retainedEngine.counts()
        try check(switched.2 >= 3, "Changing model releases previous runtime despite retention")
        let pressureReleases = await retainedEngine.counts().2
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await eventually { retainedController.preparedModel == nil }
        try await eventually { await retainedEngine.counts().2 > pressureReleases }
        try check(retainedController.keepModelLoaded && !retainedRecorder.armed, "Real memory warning overrides residency without arming microphone")
        retainedController.setForeground(true)
        try await eventually { retainedController.preparedModel == .parakeetPhononG4 }
        try check(retainedController.modelStatus == nil, "Foreground re-entry recovers after real pressure release")

        let pendingWarm = LifecycleEngine()
        let pendingWarmController = await fixture(pendingWarm)
        try await eventually { await pendingWarm.counts().0 == 1 }
        pendingWarmController.keepModelLoaded = false
        await pendingWarm.releasePreparation()
        try await eventually { await pendingWarm.counts().2 > 0 }
        try check(pendingWarmController.preparedModel == nil && pendingWarmController.modelStatus == nil, "OFF during blocked warm-up prevents late ready state")

        let staleWarm = LifecycleEngine()
        await staleWarm.releasePreparation()
        let staleDefaults = UserDefaults(suiteName: "LocalScribeQueuedWarmCheck-\(UUID())")!
        staleDefaults.set(false, forKey: "keepModelLoaded")
        let staleController = await fixture(staleWarm, preferences: staleDefaults)
        staleController.keepModelLoaded = true
        staleController.keepModelLoaded = false
        await staleController.refreshInstalledModels()
        let staleCounts = await staleWarm.counts()
        try check(staleCounts.0 == 0 && staleController.preparedModel == nil, "Queued warm-up cannot load after immediate OFF")

        let interruptedWarm = LifecycleEngine()
        let interruptedWarmController = await fixture(interruptedWarm)
        try await eventually { await interruptedWarm.counts().0 == 1 }
        interruptedWarmController.setForeground(false)
        await interruptedWarm.releasePreparation()
        try await eventually { await interruptedWarm.counts().2 > 0 }
        try check(interruptedWarmController.preparedModel == nil, "Unfinished foreground warm-up is cancelled on background, not used for background GPU work")
        interruptedWarmController.setForeground(true)
        try await eventually { interruptedWarmController.preparedModel == .parakeetPhonon }
        try check(interruptedWarmController.keepModelLoaded, "Interrupted first load resumes with retention still enabled")

        // Model attribution is frozen before either capability discovery or
        // microphone arming can suspend, and remains frozen through finalization.
        let frozenEngine = LifecycleEngine()
        await frozenEngine.releasePreparation()
        let frozenDefaults = UserDefaults(suiteName: "LocalScribeFrozenModelCheck-\(UUID())")!
        frozenDefaults.set(false, forKey: "keepModelLoaded")
        let frozenController = await fixture(frozenEngine, preferences: frozenDefaults)
        let frozenRecorder = AudioRecorder.latest!
        await frozenEngine.holdNextBackgroundCapability()
        let frozenStart = Task { await frozenController.startRecording() }
        try await eventually { await frozenEngine.backgroundCapabilityIsHeld() }
        try check(frozenController.recordingModel == .parakeetPhonon && frozenController.phase == .preparing,
                  "Dictate publishes its frozen model before capability discovery returns")
        frozenController.selectedModel = .parakeetPhononG4
        await frozenEngine.releaseBackgroundCapability()
        await frozenStart.value
        try await eventually { frozenController.preparedModel == .parakeetPhonon }
        try check(frozenController.recordingModel == .parakeetPhonon,
                  "Changing Dictate selection during capability discovery cannot relabel capture")
        frozenRecorder.feed(8_000)
        await frozenEngine.holdFinalization()
        let frozenStop = Task { await frozenController.stopRecording() }
        try await eventually { await frozenEngine.finalizationIsHeld() }
        frozenController.selectedModel = .parakeetRealtimeEOU
        try check(frozenController.recordingModel == .parakeetPhonon,
                  "Finalization keeps the actual recording model despite a new selection")
        await frozenEngine.releaseFinalization()
        await frozenStop.value
        try check(frozenController.recordingModel == nil,
                  "Completed Dictate recording clears its active model attribution")
        let frozenPreparations = await frozenEngine.preparations()
        try check(frozenPreparations == [.parakeetPhonon],
                  "Preview and finalization prepare only the one frozen Dictate model")

        AudioRecorder.holdNextArm = true
        frozenController.selectedModel = .parakeetPhonon
        let keyboardStart = Task { await frozenController.enableKeyboardSession() }
        try await eventually { frozenRecorder.armContinuation != nil }
        frozenController.selectedModel = .parakeetPhononG4
        try check(frozenController.recordingModel == .parakeetPhonon,
                  "Keyboard preparation freezes its model before microphone arming")
        frozenRecorder.armContinuation?.resume()
        frozenRecorder.armContinuation = nil
        await keyboardStart.value
        try check(frozenController.keyboardSessionActive && frozenController.preparedModel == .parakeetPhonon,
                  "Keyboard session prepares the originally requested model after arm await")
        try check(frozenController.recordingModel == nil,
                  "Armed idle keyboard session has no active recording attribution")
        frozenController.disableKeyboardSession()

        // Hold production queued prewarm work, then reserve a different explicit
        // Action model. Late foreground/discovery/selection work must not replace it.
        let ownershipEngine = LifecycleEngine()
        await ownershipEngine.releasePreparation()
        let ownershipDefaults = UserDefaults(suiteName: "LocalScribePreparationOwnerCheck-\(UUID())")!
        ownershipDefaults.set(false, forKey: "keepModelLoaded")
        let ownershipController = await fixture(ownershipEngine, preferences: ownershipDefaults)
        let ownershipRecorder = AudioRecorder.latest!
        await ownershipController.refreshInstalledModels(prewarm: false)
        let discoveryOnly = await ownershipEngine.preparations()
        try check(discoveryOnly.isEmpty, "Discovery-only refresh does not load a runtime")
        FixturePrewarmGate.held = true
        ownershipController.keepModelLoaded = true
        try await eventually { !FixturePrewarmGate.continuations.isEmpty }
        ownershipController.selectedModel = .parakeetRealtimeEOU
        await ownershipEngine.holdNextBackgroundCapability()
        let actionOwner = UUID()
        let ownedStart = Task { await ownershipController.startActionButtonRecording(requestID: actionOwner) }
        try await eventually { await ownershipEngine.backgroundCapabilityIsHeld() }
        try check(ownershipController.recordingModel == .parakeetRealtimeEOU,
                  "Action publishes its frozen model during idle capability discovery")
        ownershipController.selectedModel = .parakeetPhononG4
        ownershipDefaults.set(SpeechModel.moonshineSmall.rawValue, forKey: "selectedBackgroundModel")
        ownershipController.setForeground(true)
        await ownershipController.refreshInstalledModels()
        FixturePrewarmGate.release()
        for _ in 0..<10 { await Task.yield() }
        let reservedPreparations = await ownershipEngine.preparations()
        try check(reservedPreparations.isEmpty,
                  "Stale queued prewarm, foreground, refresh and selection cannot load over an Action reservation")
        await ownershipEngine.releaseBackgroundCapability()
        await ownedStart.value
        try await eventually { ownershipController.preparedModel == .parakeetRealtimeEOU }
        try check(ownershipController.recordingModel == .parakeetRealtimeEOU && ownershipController.actionButtonRecording,
                  "Action capture keeps the unified selected model frozen before both capability awaits")
        ownershipRecorder.feed(8_000)
        await ownershipController.stopActionButtonRecording()
        ownershipController.setForeground(false)
        ownershipController.setForeground(true)
        await ownershipController.refreshInstalledModels()
        for _ in 0..<10 { await Task.yield() }
        let retainedActionPreparations = await ownershipEngine.preparations()
        try check(retainedActionPreparations == [.parakeetRealtimeEOU] && ownershipController.preparedModel == .parakeetRealtimeEOU,
                  "Returning from Action dictation and discovery retain its ready runtime after a selection change during capture")
        ownershipController.selectedModel = .parakeetPhonon
        try await eventually { ownershipController.preparedModel == .parakeetPhonon }
        let explicitPreparations = await ownershipEngine.preparations()
        try check(explicitPreparations == [.parakeetRealtimeEOU, .parakeetPhonon],
                  "Explicit idle model selection still warms the selected Dictate model with retention enabled")

        // A queued warm-up retired by a cancelled explicit startup stays retired
        // even though cancellation has returned the controller to idle.
        let cancelledOwnerEngine = LifecycleEngine()
        await cancelledOwnerEngine.releasePreparation()
        let cancelledOwnerDefaults = UserDefaults(suiteName: "LocalScribeCancelledWarmOwnerCheck-\(UUID())")!
        cancelledOwnerDefaults.set(false, forKey: "keepModelLoaded")
        let cancelledOwnerController = await fixture(cancelledOwnerEngine, preferences: cancelledOwnerDefaults)
        FixturePrewarmGate.held = true
        cancelledOwnerController.keepModelLoaded = true
        try await eventually { !FixturePrewarmGate.continuations.isEmpty }
        await cancelledOwnerEngine.holdNextBackgroundCapability()
        let cancelledOwner = UUID()
        let cancelledOwnerStart = Task { await cancelledOwnerController.startActionButtonRecording(requestID: cancelledOwner) }
        try await eventually { await cancelledOwnerEngine.backgroundCapabilityIsHeld() }
        await cancelledOwnerController.cancelActionButtonRecording(requestID: cancelledOwner)
        await cancelledOwnerEngine.releaseBackgroundCapability()
        await cancelledOwnerStart.value
        FixturePrewarmGate.release()
        for _ in 0..<10 { await Task.yield() }
        let cancelledPreparations = await cancelledOwnerEngine.preparations()
        try check(cancelledOwnerController.recordingModel == nil && cancelledOwnerController.phase == .idle,
                  "Cancelled Action reservation clears frozen attribution")
        try check(cancelledPreparations.isEmpty,
                  "A prewarm queued before cancelled Action startup cannot resurrect a retired model intent")

        let unifiedEngine = LifecycleEngine()
        await unifiedEngine.releasePreparation()
        let unifiedDefaults = UserDefaults(suiteName: "LocalScribeUnifiedModelCheck-\(UUID())")!
        unifiedDefaults.set(false, forKey: "keepModelLoaded")
        unifiedDefaults.set(SpeechModel.parakeetRealtimeEOU.rawValue, forKey: "selectedBackgroundModel")
        let unifiedController = await fixture(unifiedEngine, model: .parakeetPhonon, preferences: unifiedDefaults)
        let unifiedRecorder = AudioRecorder.latest!
        try check(unifiedController.actionButtonModel == .parakeetPhonon,
                  "Action Button resolves the main model even when an older separate preference exists")
        await unifiedController.startActionButtonRecording()
        try await eventually { unifiedController.preparedModel == .parakeetPhonon }
        try check(unifiedController.phase == .recording && unifiedController.recordingModel == .parakeetPhonon,
                  "Foreground Action uses selected Phonon without a hidden CPU fallback")
        unifiedRecorder.feed(8_000)
        await unifiedController.stopActionButtonRecording()
        unifiedController.setForeground(false)
        let unifiedArmCalls = unifiedRecorder.armCalls
        await unifiedController.startActionButtonRecording()
        try check(unifiedController.phase == .idle && unifiedRecorder.armCalls == unifiedArmCalls
                  && unifiedController.errorMessage?.contains("requires LocalScribe to stay open") == true,
                  "Background Action reports the selected runtime's restriction before arming microphone")
        let unifiedPreparations = await unifiedEngine.preparations()
        try check(unifiedPreparations == [.parakeetPhonon],
                  "Unsupported background request never loads Realtime or another fallback runtime")
        try check(unifiedDefaults.string(forKey: "selectedBackgroundModel") == SpeechModel.parakeetRealtimeEOU.rawValue,
                  "Unified selection leaves the retired preference value untouched")

        unifiedController.setForeground(true)
        let reservedID = UUID()
        try check(unifiedController.reserveActionButtonRecording(requestID: reservedID, model: .parakeetPhonon),
                  "Bridge can reserve its frozen model synchronously before discovery and Activity awaits")
        try check(unifiedController.recordingModel == .parakeetPhonon && !unifiedRecorder.recording,
                  "Reserved Action model is visible before capture begins")
        await unifiedController.cancelActionButtonRecording(requestID: reservedID)
        await unifiedController.startReservedActionButtonRecording(requestID: reservedID)
        try check(unifiedController.phase == .idle && unifiedController.recordingModel == nil
                  && unifiedRecorder.armCalls == unifiedArmCalls,
                  "Late reserved-start continuation cannot resurrect a cancelled Action request")
        await unifiedController.startActionButtonRecording()
        unifiedRecorder.feed(8_000)
        unifiedController.setForeground(false)
        try await eventually { unifiedController.phase == .transcribing }
        try check(!unifiedRecorder.recording,
                  "Foreground-only selected Action model stops capture immediately on background transition")
        unifiedController.setForeground(true)
        try await eventually { unifiedController.phase == .idle }
        try check(unifiedController.transcript == "Captured words.",
                  "Returning to foreground finishes the captured selected-model utterance")

        // A selected accelerated model may request CPU execution for Action
        // capture without selecting or preparing a second speech model.
        let contextualEngine = ContextualLifecycleEngine()
        await contextualEngine.engine.releasePreparation()
        let contextualController = await fixture(contextualEngine)
        let contextualRecorder = AudioRecorder.latest!
        try await eventually { contextualController.preparedModel == .parakeetPhonon }
        try check(contextualController.preparedExecutionContext == .foreground,
                  "Cold foreground prewarm retains the existing accelerated execution preference")
        contextualController.setForeground(false)
        await contextualController.startActionButtonRecording()
        try await eventually { contextualController.preparedExecutionContext == .backgroundCapable }
        try check(contextualController.phase == .recording && contextualController.recordingModel == .parakeetPhonon
                  && contextualController.recordingExecutionContext == .backgroundCapable,
                  "Background Action freezes selected Phonon with CPU-capable execution rather than another model")
        contextualRecorder.feed(16_000)
        try await eventually { await contextualEngine.engine.counts().3 == 16_000 }
        await contextualController.stopActionButtonRecording()
        contextualController.setForeground(true)
        await contextualController.refreshInstalledModels()
        await contextualController.startRecording()
        try check(contextualController.recordingExecutionContext == .backgroundCapable,
                  "Next Dictate recording freezes and reuses the ready selected CPU runtime")
        contextualRecorder.feed(8_000)
        await contextualController.stopRecording()
        await contextualController.enableKeyboardSession()
        try check(contextualController.keyboardSessionActive
                  && contextualController.preparedExecutionContext == .backgroundCapable,
                  "Keyboard microphone lease also reuses the retained selected CPU runtime")
        contextualController.disableKeyboardSession()
        let contextualPreparations = await contextualEngine.preparationRequests()
        try check(contextualPreparations.count == 2
                  && contextualPreparations[0].0 == .parakeetPhonon && contextualPreparations[0].1 == .foreground
                  && contextualPreparations[1].0 == .parakeetPhonon && contextualPreparations[1].1 == .backgroundCapable,
                  "Only one context switch occurs; foreground return, refresh and Dictate never bounce back to acceleration")
        contextualController.selectedModel = .parakeetPhononG4
        try await eventually { contextualController.preparedModel == .parakeetPhononG4 }
        try check(contextualController.preparedExecutionContext == .foreground,
                  "Explicit new model selection retains foreground acceleration preference")

        let normalizedEngine = ContextualLifecycleEngine()
        await normalizedEngine.engine.releasePreparation()
        let normalizedController = await fixture(normalizedEngine, model: .parakeetRealtimeEOU)
        let normalizedRecorder = AudioRecorder.latest!
        try await eventually { normalizedController.preparedModel == .parakeetRealtimeEOU }
        normalizedController.setForeground(false)
        await normalizedController.startActionButtonRecording()
        normalizedRecorder.feed(8_000)
        await normalizedController.stopActionButtonRecording()
        normalizedController.setForeground(true)
        await normalizedController.startRecording()
        normalizedRecorder.feed(8_000)
        await normalizedController.stopRecording()
        let normalizedPreparations = await normalizedEngine.preparationRequests()
        try check(normalizedPreparations.count == 1 && normalizedPreparations[0].1 == .foreground,
                  "CPU-only model contexts normalize and reuse one runtime across Dictate and Action")

        let failedContextEngine = ContextualLifecycleEngine()
        await failedContextEngine.engine.releasePreparation()
        let failedContextDefaults = UserDefaults(suiteName: "LocalScribeContextFailureCheck-\(UUID())")!
        failedContextDefaults.set(false, forKey: "keepModelLoaded")
        let failedContextController = await fixture(failedContextEngine, preferences: failedContextDefaults)
        await failedContextEngine.failNextBackgroundPreparation()
        failedContextController.setForeground(false)
        await failedContextController.startActionButtonRecording()
        try await eventually { failedContextController.phase == .idle }
        let failedContextPreparations = await failedContextEngine.preparationRequests()
        try check(failedContextController.errorMessage != nil && failedContextController.preparedModel == nil
                  && failedContextPreparations.count == 1 && failedContextPreparations[0].0 == .parakeetPhonon
                  && failedContextPreparations[0].1 == .backgroundCapable,
                  "CPU-context loading failure is reported without retrying another model or accelerated runtime")
        try check(failedContextController.recordingModel == nil && failedContextController.recordingExecutionContext == nil,
                  "Failed context preparation retires its active model and execution attribution")

        let cancelledContextEngine = ContextualLifecycleEngine()
        let cancelledContextDefaults = UserDefaults(suiteName: "LocalScribeContextCancellationCheck-\(UUID())")!
        cancelledContextDefaults.set(false, forKey: "keepModelLoaded")
        let cancelledContextController = await fixture(cancelledContextEngine, preferences: cancelledContextDefaults)
        let cancelledContextRecorder = AudioRecorder.latest!
        await cancelledContextController.startActionButtonRecording()
        try await eventually { await cancelledContextEngine.engine.counts().0 == 1 }
        let cancellingContext = Task { await cancelledContextController.cancelRecording() }
        try await eventually { cancelledContextController.phase == .idle }
        await cancelledContextEngine.engine.releasePreparation()
        await cancellingContext.value
        try check(cancelledContextController.preparedModel == nil && cancelledContextController.preparedExecutionContext == nil
                  && cancelledContextController.recordingExecutionContext == nil && !cancelledContextRecorder.recording,
                  "Cancelled CPU preparation cannot publish late ready context or retain microphone capture")
        await cancelledContextController.startRecording()
        try await eventually { cancelledContextController.preparedExecutionContext == .foreground }
        try check(cancelledContextController.recordingModel == .parakeetPhonon
                  && cancelledContextController.recordingExecutionContext == .foreground,
                  "Replacement Dictate starts the selected model in its own foreground execution context")
        await cancelledContextController.cancelRecording()

        print("PASS: \(checks) actual AppController lifecycle checks")
    }
}
