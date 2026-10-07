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
    @MainActor static func eventually(file: StaticString = #filePath, line: UInt = #line, _ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure.failed("Timed out waiting for controller transition at \(file):\(line)")
    }
    @MainActor static func fixture(_ engine: LifecycleEngine, model: SpeechModel = .parakeetPhonon, preferences: UserDefaults? = nil) async -> AppController {
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
        actionController.selectedBackgroundModel = .parakeetPhonon
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

        print("PASS: \(checks) actual AppController lifecycle checks")
    }
}
