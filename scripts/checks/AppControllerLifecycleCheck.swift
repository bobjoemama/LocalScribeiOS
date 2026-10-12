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
    var backgroundTaskStarts = 0
    var backgroundTaskEnds = 0
    var backgroundTaskExpirations: [Int: () -> Void] = [:]
    func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        backgroundTaskStarts += 1
        backgroundTaskExpirations[backgroundTaskStarts] = expirationHandler
        return .init(value: backgroundTaskStarts)
    }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) { backgroundTaskEnds += 1 }
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
    private var armHeldWaiter: CheckedContinuation<Void, Never>?
    func waitUntilArmHeld() async {
        if armContinuation != nil { return }
        await withCheckedContinuation { armHeldWaiter = $0 }
    }
    func releaseArm() { armContinuation?.resume(); armContinuation = nil }
    static var holdNextArm = false
    static var samplesOnBeginCapture = 0
    var captureSnapshot = FixtureCaptureSnapshot()
    var pending: [Float] = []
    var recording = false
    var armed = false
    var armCalls = 0
    var activations = 0
    var rejectNewBackgroundActivation = false
    init() { Self.latest = self }
    private(set) var lastMixWithOtherAudio = false
    private(set) var lastRequireExistingPermission = false
    func arm(requireExistingPermission: Bool = false, mixWithOtherAudio: Bool = false) async throws {
        armCalls += 1
        lastMixWithOtherAudio = mixWithOtherAudio
        lastRequireExistingPermission = requireExistingPermission
        if Self.holdNextArm {
            Self.holdNextArm = false
            await withCheckedContinuation { armContinuation = $0; armHeldWaiter?.resume(); armHeldWaiter = nil }
        }
        if !microphonePermissionGranted { throw NSError(domain: "FixtureMicrophone", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission is denied."]) }
        if !armed {
            if rejectNewBackgroundActivation { throw NSError(domain: NSOSStatusErrorDomain, code: 561015905) }
            activations += 1
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
    private var capabilityWaiter: CheckedContinuation<Void, Never>?
    func holdNextBackgroundCapability(skip: Int = 0) { heldCapabilityCall = capabilityCalls + 1 + skip }
    func backgroundCapabilityIsHeld() -> Bool { capabilityContinuation != nil }
    func waitUntilBackgroundCapabilityHeld() async {
        if capabilityContinuation != nil { return }
        await withCheckedContinuation { capabilityWaiter = $0 }
    }
    func releaseBackgroundCapability() {
        heldCapabilityCall = nil
        capabilityContinuation?.resume()
        capabilityContinuation = nil
    }
    func supportsBackgroundInference(for model: SpeechModel) async -> Bool {
        capabilityCalls += 1
        if heldCapabilityCall == capabilityCalls {
            await withCheckedContinuation {
                capabilityContinuation = $0
                capabilityWaiter?.resume(); capabilityWaiter = nil
            }
        }
        return cpuBackgroundEnabled && model == .parakeetRealtimeEOU
    }
    func disableCPUBackground() { cpuBackgroundEnabled = false }
    var installed: Set<SpeechModel> = [.parakeetPhonon, .parakeetPhononG4, .parakeetRealtimeEOU]
    var holdPreparation = true
    var loadContinuation: CheckedContinuation<Void, Never>?
    private var preparationHeldWaiter: CheckedContinuation<Void, Never>?
    func waitUntilPreparationHeld() async {
        if loadContinuation != nil { return }
        await withCheckedContinuation { preparationHeldWaiter = $0 }
    }
    var prepareCalls = 0
    var beginCalls = 0
    var unloadCalls = 0
    var admittedSamples = 0
    var largestAppend = 0
    var failAppend = false
    var callback: (@Sendable (SpeechTranscriptUpdate) -> Void)?
    var oldCallback: (@Sendable (SpeechTranscriptUpdate) -> Void)?
    func isInstalled(_ model: SpeechModel) async -> Bool { installed.contains(model) }
    func setInstalled(_ models: Set<SpeechModel>) { installed = models }
    var downloaded: [SpeechModel] = []
    var prepared: [SpeechModel] = []
    var downloadFailure: SpeechModel?
    var slowDownload = false
    var slowDownloadModel: SpeechModel?
    private var holdDownload = false
    private var downloadContinuation: CheckedContinuation<Void, Never>?
    private var downloadHeldWaiter: CheckedContinuation<Void, Never>?
    private var unloadWaiter: CheckedContinuation<Void, Never>?
    func holdNextDownload() { holdDownload = true }
    func waitUntilDownloadHeld() async {
        if downloadContinuation != nil { return }
        await withCheckedContinuation { downloadHeldWaiter = $0 }
    }
    func releaseHeldDownload() { downloadContinuation?.resume(); downloadContinuation = nil }
    func waitUntilUnloaded() async {
        if unloadCalls > 0 { return }
        await withCheckedContinuation { unloadWaiter = $0 }
    }
    func configureDownloads(failure: SpeechModel? = nil, slow: Bool = false, slowModel: SpeechModel? = nil) { downloadFailure = failure; slowDownload = slow; slowDownloadModel = slowModel }
    func downloads() -> [SpeechModel] { downloaded }
    func preparations() -> [SpeechModel] { prepared }
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        downloaded.append(model)
        progress(0.25)
        if holdDownload {
            holdDownload = false
            await withCheckedContinuation {
                downloadContinuation = $0
                downloadHeldWaiter?.resume(); downloadHeldWaiter = nil
            }
        }
        if slowDownload || slowDownloadModel == model { try await Task.sleep(for: .seconds(10)) }
        try Task.checkCancellation()
        if downloadFailure == model { throw Failure.expected }
        installed.insert(model)
        progress(1)
    }
    func prepare(_ model: SpeechModel) async throws {
        prepareCalls += 1; prepared.append(model)
        if holdPreparation { await withCheckedContinuation { loadContinuation = $0; preparationHeldWaiter?.resume(); preparationHeldWaiter = nil } }
        try Task.checkCancellation()
    }
    func releasePreparation() { holdPreparation = false; loadContinuation?.resume(); loadContinuation = nil }
    func holdNextPreparation() { holdPreparation = true }
    func beginStreaming(onUpdate: @escaping @Sendable (SpeechTranscriptUpdate) -> Void) async throws {
        beginCalls += 1; admittedSamples = 0; oldCallback = callback; callback = onUpdate
    }
    func appendStreaming(samples: [Float]) async throws {
        if failAppend { throw Failure.expected }
        admittedSamples += samples.count; largestAppend = max(largestAppend, samples.count)
        callback?(.init(confirmedText: "Captured", volatileText: "words"))
    }
    var holdFinish = false
    private var finalText = "Captured words."
    func setFinalText(_ text: String) { finalText = text }
    var finishContinuation: CheckedContinuation<Void, Never>?
    private var finalizationWaiter: CheckedContinuation<Void, Never>?
    func waitUntilFinalizationStarts() async {
        if finishContinuation != nil { return }
        await withCheckedContinuation { finalizationWaiter = $0 }
    }
    func holdFinalization() { holdFinish = true }
    func finalizationIsHeld() -> Bool { finishContinuation != nil }
    func releaseFinalization() { holdFinish = false; finishContinuation?.resume(); finishContinuation = nil }
    func finishStreaming() async throws -> String {
        if holdFinish {
            await withCheckedContinuation {
                finishContinuation = $0
                finalizationWaiter?.resume(); finalizationWaiter = nil
            }
        }
        return finalText
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
    func unload() async { unloadCalls += 1; unloadWaiter?.resume(); unloadWaiter = nil }
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
    @MainActor static func fixture(_ engine: any LocalTranscriptionEngine, model: SpeechModel = .parakeetPhonon, preferences: UserDefaults? = nil, automatic: Bool = false) async -> AppController {
        let defaults = preferences ?? UserDefaults(suiteName: "LocalScribeControllerCheck-\(UUID())")!
        if !automatic {
            defaults.set(false, forKey: "backgroundDictationEnabled")
            if defaults.object(forKey: "keyboardIdleMinutes") == nil { defaults.set(5, forKey: "keyboardIdleMinutes") }
        }
        defaults.set(false, forKey: "saveHistory")
        defaults.set(model.rawValue, forKey: "selectedModel")
        let history = FileManager.default.temporaryDirectory.appendingPathComponent("LocalScribeControllerCheck-\(UUID())/history.json")
        let controller = AppController(engine: engine, defaults: defaults, historyURL: history)
        await controller.refreshInstalledModels()
        return controller
    }
    @MainActor static func checkExplicitMicrophoneActionCycles() async throws {
        let engine = LifecycleEngine()
        await engine.releasePreparation()
        let controller = await fixture(engine, model: .parakeetRealtimeEOU)
        let recorder = AudioRecorder.latest!
        defer {
            recorder.rejectNewBackgroundActivation = false
            controller.disableKeyboardSession()
        }
        await controller.enableKeyboardSession()
        try check(controller.keyboardSessionActive && recorder.armed && !recorder.recording
                  && controller.actionButtonModelReady && recorder.activations == 1,
                  "Foreground Enable owns one microphone lease and prepares the selected Action runtime")
        try check(recorder.lastMixWithOtherAudio && !recorder.lastRequireExistingPermission,
                  "Foreground Enable requests a mixable session and keeps the normal microphone permission request")
        controller.setForeground(false)
        recorder.rejectNewBackgroundActivation = true
        let preparingRequest = UUID()
        await engine.holdNextBackgroundCapability(skip: 1)
        let preparingStart = Task { await controller.startActionButtonRecording(requestID: preparingRequest) }
        await engine.waitUntilBackgroundCapabilityHeld()
        let preparationDeadline = controller.keyboardSessionExpiresAt!
        await controller.handleKeyboardIdleDeadline(expected: preparationDeadline)
        try check(controller.phase == .preparing && recorder.armed && controller.keyboardSessionActive
                  && controller.keyboardSessionExpiresAt != preparationDeadline,
                  "Idle deadline during Action preparation renews the lease without cancelling startup")
        await engine.releaseBackgroundCapability()
        await preparingStart.value
        await controller.cancelActionButtonRecording(requestID: preparingRequest)
        var previousRecordingID: UUID?
        for (cycle, text, sampleCount) in [(1, "First action words.", 8_000), (2, "Second action words.", 16_000)] {
            await engine.setFinalText(text)
            let requestID = UUID()
            await controller.startActionButtonRecording(requestID: requestID)
            let recordingID = controller.currentRecordingID
            try check(controller.phase == .recording && controller.actionButtonRecording
                      && recorder.recording && recordingID != nil && recordingID != previousRecordingID,
                      "Action cycle \(cycle) reuses the explicit foreground microphone lease in background")
            try check(controller.transcript.isEmpty && controller.partialText.isEmpty,
                      "Action cycle \(cycle) starts a separate empty utterance")
            let recordingDeadline = controller.keyboardSessionExpiresAt!
            await controller.handleKeyboardIdleDeadline(expected: recordingDeadline)
            let renewedDeadline = controller.keyboardSessionExpiresAt
            await controller.handleKeyboardIdleDeadline(expected: recordingDeadline)
            try check(controller.phase == .recording && recorder.recording && recorder.armed
                      && renewedDeadline != recordingDeadline && controller.keyboardSessionExpiresAt == renewedDeadline,
                      "Active recording renews its deadline and ignores an old queued expiry")
            recorder.feed(sampleCount)
            let backgroundAssertionsBeforeStop = UIApplication.shared.backgroundTaskStarts
            let deadlineBeforeStop = controller.keyboardSessionExpiresAt!
            if cycle == 2 {
                await engine.holdFinalization()
                let stop = Task { await controller.stopActionButtonRecording(completionIsPlatformManaged: true) }
                await engine.waitUntilFinalizationStarts()
                try check(controller.keyboardSessionExpiresAt.map { $0 > deadlineBeforeStop } == true,
                          "Managed Action Stop renews the lease before its finalization deadline event")
                let finalizationDeadline = controller.keyboardSessionExpiresAt!
                await controller.handleKeyboardIdleDeadline(expected: finalizationDeadline)
                try check(controller.phase == .transcribing && recorder.armed && !recorder.recording
                          && controller.keyboardSessionExpiresAt != finalizationDeadline,
                          "Deadline during managed finalization renews the explicit lease without cancelling recognition")
                await engine.releaseFinalization()
                await stop.value
            } else {
                await controller.stopActionButtonRecording()
                try check(controller.keyboardSessionExpiresAt.map { $0 > deadlineBeforeStop } == true,
                          "Successful Action Stop advances the actual deadline from its pre-Stop value")
            }
            let counts = await engine.counts()
            try check(controller.phase == .idle && !controller.actionButtonRecording && !recorder.recording
                      && controller.currentRecordingID == nil && controller.completedRecordingID == recordingID
                      && controller.transcript == text && counts.3 == sampleCount && recorder.pending.isEmpty,
                      "Action cycle \(cycle) finishes only its utterance and drains exactly its own audio")
            try check(controller.keyboardSessionActive && recorder.armed && recorder.activations == 1,
                      "Successful Action finish preserves the enabled microphone instead of requiring new background activation")
            if cycle == 2 {
                try check(UIApplication.shared.backgroundTaskStarts == backgroundAssertionsBeforeStop,
                          "Managed Action completion preserves the lease without acquiring finite completion time")
            }
            previousRecordingID = recordingID
        }
        let preparations = await engine.preparations()
        try check(preparations == [.parakeetRealtimeEOU] && controller.selectedModel == .parakeetRealtimeEOU,
                  "Both Action utterances reuse one prepared selected model")
        let cancelledRequest = UUID()
        await controller.startActionButtonRecording(requestID: cancelledRequest)
        recorder.feed(8_000)
        await controller.cancelActionButtonRecording(requestID: cancelledRequest)
        try check(controller.phase == .idle && controller.transcript.isEmpty && !recorder.recording
                  && controller.keyboardSessionActive && recorder.armed && recorder.activations == 1,
                  "Action cancellation still discards its utterance and preserves the explicit microphone lease")
        let endRequest = UUID()
        await controller.startActionButtonRecording(requestID: endRequest)
        let endedDeadline = controller.keyboardSessionExpiresAt!
        recorder.feed(8_000)
        await controller.finishKeyboardSession()
        await controller.handleKeyboardIdleDeadline(expected: endedDeadline)
        try check(controller.phase == .idle && controller.keyboardSessionExpiresAt == nil
                  && !recorder.armed && !recorder.recording,
                  "Explicit End finishes active capture and a stale deadline cannot recreate the microphone lease")
        recorder.rejectNewBackgroundActivation = false
        controller.setForeground(true)
        await controller.enableKeyboardSession()
        let idleDeadline = controller.keyboardSessionExpiresAt!
        controller.setForeground(false)
        await controller.handleKeyboardIdleDeadline(expected: idleDeadline)
        try check(controller.keyboardSessionExpiresAt == nil && !recorder.armed && !recorder.recording,
                  "Current idle deadline retires the explicit session and microphone")

        // A ready model alone never grants a persistent microphone lease.
        recorder.rejectNewBackgroundActivation = false
        await engine.setFinalText("Standalone action words.")
        let activationsBeforeStandalone = recorder.activations
        await controller.startActionButtonRecording()
        try check(controller.phase == .recording && !controller.keyboardSessionActive
                  && recorder.activations == activationsBeforeStandalone + 1,
                  "Action without an explicit session activates only its own capture")
        recorder.feed(8_000)
        await controller.stopActionButtonRecording()
        try check(controller.phase == .idle && controller.transcript == "Standalone action words."
                  && !controller.keyboardSessionActive && !recorder.armed && !recorder.recording,
                  "Action without an explicit session shuts down all microphone resources after Stop")
        recorder.rejectNewBackgroundActivation = true
        await controller.startActionButtonRecording()
        try check(controller.phase == .idle && !controller.actionButtonRecording
                  && !recorder.armed && !controller.keyboardSessionActive && controller.errorMessage != nil,
                  "Ready model retention cannot bypass rejection of a new background microphone activation")
    }

    @MainActor static func checkActionReservationRetention() async throws {
        for turnsRetentionOff in [false, true] {
            let engine = ContextualLifecycleEngine()
            await engine.engine.releasePreparation()
            let defaults = UserDefaults(suiteName: "ActionReservationRetention-\(UUID())")!
            defaults.set(turnsRetentionOff, forKey: "keepModelLoaded")
            let controller = await fixture(engine, preferences: defaults)
            let recorder = AudioRecorder.latest!
            let owner = UUID()
            do {
                try check(controller.reserveActionButtonRecording(requestID: owner, model: .parakeetPhonon), "Action owns the foreground CPU preparation")
                let ready = await controller.prepareReservedActionButtonRecording(requestID: owner)
                try check(ready && controller.phase == .idle && controller.actionButtonModelReady, "Reserved CPU preparation finishes Ready before the Activity boundary")
                if turnsRetentionOff { controller.keepModelLoaded = false }
                controller.setForeground(false)
                try check(controller.actionButtonModelReady && controller.preparedExecutionContext == .backgroundCapable,
                          "An Action reservation retains Ready through ordinary Keep-Off release and scene exit")
                await controller.startReservedActionButtonRecording(requestID: owner)
                try check(controller.phase == .recording && recorder.recording && recorder.armCalls == 1,
                          "The reserved Phonon runtime starts once after the background Activity boundary")
                recorder.feed(8_000)
                await controller.stopActionButtonRecording()
                try check(controller.phase == .idle && controller.transcript == "Captured words." && controller.preparedModel == nil,
                          "Completed Action releases its runtime under the Off policy")
                await engine.engine.waitUntilUnloaded()
            } catch {
                await controller.cancelActionButtonRecording(requestID: owner)
                await controller.cancelRecording()
                throw error
            }
        }
    }

    @MainActor static func checkActionReservationCleanup() async throws {
        for failPermission in [false, true] {
            let engine = ContextualLifecycleEngine()
            await engine.engine.releasePreparation()
            let defaults = UserDefaults(suiteName: "ActionReservationCleanup-\(UUID())")!
            defaults.set(false, forKey: "keepModelLoaded")
            let controller = await fixture(engine, preferences: defaults)
            let recorder = AudioRecorder.latest!
            let owner = UUID()
            do {
                try check(controller.reserveActionButtonRecording(requestID: owner, model: .parakeetPhonon), "Cleanup fixture owns an Action reservation")
                let ready = await controller.prepareReservedActionButtonRecording(requestID: owner)
                try check(ready, "Cleanup fixture has a prepared CPU runtime")
                if failPermission {
                    recorder.microphonePermissionGranted = false
                    await controller.startReservedActionButtonRecording(requestID: owner)
                    try check(controller.errorMessage?.contains("allow microphone access") == true && recorder.armCalls == 0,
                              "Failed activation reports missing microphone permission without capture")
                } else {
                    await controller.cancelActionButtonRecording(requestID: UUID())
                    try check(controller.actionButtonModelReady, "Unrelated cancellation preserves the reserved runtime")
                    await controller.cancelActionButtonRecording(requestID: owner)
                }
                try check(controller.phase == .idle && controller.preparedModel == nil && !controller.actionButtonRecording,
                          "Matching cancellation or failed startup releases the Off-policy reservation")
                await engine.engine.waitUntilUnloaded()
            } catch {
                await controller.cancelActionButtonRecording(requestID: owner)
                await controller.cancelRecording()
                throw error
            }
        }
    }

    @MainActor static func checkActionStartupErrors() async throws {
        let engine = ContextualLifecycleEngine()
        await engine.engine.releasePreparation()
        let controller = await fixture(engine)
        let recorder = AudioRecorder.latest!
        let owner = UUID()
        let stale = "Open LocalScribe and wait until Phonon-2 is Ready before using the Action Button."
        var download: Task<Void, Never>?
        do {
            controller.errorMessage = stale
            try check(controller.reserveActionButtonRecording(requestID: owner, model: .parakeetPhonon), "Startup accepts a fresh Action reservation")
            try check(controller.errorMessage == nil, "An accepted Action reservation clears the prior startup error")
            controller.errorMessage = "Preserve the current owner's error."
            try check(!controller.reserveActionButtonRecording(requestID: UUID(), model: .parakeetPhonon)
                      && controller.errorMessage == "Preserve the current owner's error.",
                      "Rejected reservations do not clear another owner's error")
            let ready = await controller.prepareReservedActionButtonRecording(requestID: owner)
            try check(ready, "The download conflict starts with an actually Ready CPU runtime")
            await controller.cancelActionButtonRecording(requestID: owner)
            await engine.engine.holdNextDownload()
            let runningDownload = Task { await controller.download(.parakeetPhononG4) }
            download = runningDownload
            await engine.engine.waitUntilDownloadHeld()
            try check(controller.reserveActionButtonRecording(requestID: owner, model: .parakeetPhonon),
                      "A download already in progress admits a reservation that can report its startup conflict")
            controller.errorMessage = stale
            await controller.startReservedActionButtonRecording(requestID: owner)
            let error = controller.errorMessage
            await engine.engine.releaseHeldDownload()
            await runningDownload.value
            try check(controller.phase == .idle && recorder.armCalls == 0 && !controller.actionButtonRecording,
                      "An in-progress download rejects Action startup before microphone activation")
            try check(error?.localizedCaseInsensitiveContains("download") == true && error != stale,
                      "Download rejection replaces the stale Ready instruction with its actual conflict")
            controller.keepModelLoaded = false
            await engine.engine.waitUntilUnloaded()
        } catch {
            await engine.engine.releaseHeldDownload()
            await download?.value
            await controller.cancelActionButtonRecording(requestID: owner)
            await controller.cancelRecording()
            controller.keepModelLoaded = false
            throw error
        }
    }

    @MainActor static func waitForBackgroundStartup(_ controller: AppController) async {
        guard controller.backgroundDictationStarting else { return }
        var subscription: AnyCancellable?
        await withCheckedContinuation { continuation in
            subscription = controller.$backgroundDictationStarting.filter { !$0 }.first().sink { _ in continuation.resume() }
        }
        subscription?.cancel()
    }

    @MainActor static func waitForMicrophoneEnd(_ controller: AppController) async {
        var subscription: AnyCancellable?
        await withCheckedContinuation { continuation in
            subscription = controller.$keyboardSessionExpiresAt.filter { $0 == nil }.first().sink { _ in continuation.resume() }
        }
        subscription?.cancel()
    }

    @MainActor static func checkDefaultBackgroundDictation() async throws {
        let engine = ContextualLifecycleEngine()
        await engine.engine.releasePreparation()
        let defaults = UserDefaults(suiteName: "DefaultBackgroundDictation-\(UUID())")!
        let controller = await fixture(engine, preferences: defaults, automatic: true)
        let recorder = AudioRecorder.latest!
        defer { controller.backgroundDictationEnabled = false }
        await waitForBackgroundStartup(controller)
        try check(controller.backgroundDictationEnabled && controller.keepModelLoaded && controller.keyboardIdleMinutes == 0,
                  "Fresh settings default to background dictation, retained selected model and Never")
        try check(controller.keyboardSessionActive && recorder.armed && !recorder.recording && recorder.lastMixWithOtherAudio
                  && controller.actionButtonModelReady && controller.backgroundDictationError == nil,
                  "Foreground catalog discovery arms a genuine mixable idle session and prepares the selected CPU runtime")
        let requests = await engine.preparationRequests()
        try check(requests.count == 1 && requests[0].0 == .parakeetPhonon && requests[0].1 == .backgroundCapable,
                  "Automatic startup prepares only the selected background runtime once")
        try check(controller.keyboardSessionExpiresAt == .distantFuture,
                  "Never uses the existing indefinite shared-protocol lease")
        controller.keyboardIdleMinutes = 5
        try check(controller.keyboardSessionExpiresAt != .distantFuture && controller.keyboardSessionActive,
                  "Changing the idle policy reconfigures an already armed lease immediately")
        controller.keyboardIdleMinutes = 0
        try check(controller.keyboardSessionExpiresAt == .distantFuture, "Returning to Never removes the timed lease")
        await controller.handleKeyboardIdleDeadline(expected: .distantFuture)
        controller.setForeground(false)
        controller.setForeground(true)
        await controller.refreshInstalledModels()
        try check(controller.keyboardSessionActive && recorder.activations == 1,
                  "Never ignores idle expiry and reopening reuses the already armed session")
        controller.backgroundDictationEnabled = false
        try check(!controller.keyboardSessionActive && !recorder.armed && defaults.object(forKey: "backgroundDictationEnabled") as? Bool == false,
                  "Pause immediately closes idle microphone access and persists Off")
        controller.setForeground(false); controller.setForeground(true)
        await controller.refreshInstalledModels()
        try check(recorder.activations == 1 && !controller.backgroundDictationStarting,
                  "Paused background dictation cannot silently reactivate on reopening or discovery")
        let reopened = await fixture(engine, preferences: defaults, automatic: true)
        defer { reopened.backgroundDictationEnabled = false }
        let reopenedRecorder = AudioRecorder.latest!
        try check(!reopened.backgroundDictationEnabled && !reopened.keyboardSessionActive && reopenedRecorder.armCalls == 0,
                  "A new controller preserves the saved paused preference")
        defaults.set(15, forKey: "keyboardIdleMinutes")
        let timed = await fixture(engine, preferences: defaults, automatic: true)
        defer { timed.backgroundDictationEnabled = false }
        try check(timed.keyboardIdleMinutes == 15, "An explicitly saved timed idle choice survives the new Never default")
        await timed.retryBackgroundDictation()
        let timedDeadline = timed.keyboardSessionExpiresAt!
        await timed.handleKeyboardIdleDeadline(expected: timedDeadline)
        try check(!timed.keyboardSessionActive && timed.backgroundDictationEnabled,
                  "An optional timed deadline ends the session without changing the enabled preference")
        await timed.refreshInstalledModels()
        try check(!timed.keyboardSessionActive, "A timed expiry does not start a discovery retry loop")
        timed.backgroundDictationEnabled = false
        let coldEngine = ContextualLifecycleEngine()
        await coldEngine.engine.releasePreparation()
        let coldDefaults = UserDefaults(suiteName: "ColdBackgroundDictation-\(UUID())")!
        coldDefaults.set(false, forKey: "backgroundDictationEnabled")
        coldDefaults.set(false, forKey: "keepModelLoaded")
        let cold = await fixture(coldEngine, preferences: coldDefaults, automatic: true)
        defer { cold.backgroundDictationEnabled = false }
        let coldRecorder = AudioRecorder.latest!
        cold.setForeground(false); cold.backgroundDictationEnabled = true
        await cold.refreshInstalledModels()
        await cold.retryBackgroundDictation()
        try check(coldRecorder.armCalls == 0 && !cold.keyboardSessionActive,
                  "Enabled discovery or retry in a cold background cannot request permission or activate audio")
        cold.setForeground(true)
        await waitForBackgroundStartup(cold)
        try check(cold.keyboardSessionActive && coldRecorder.activations == 1, "A later real foreground opening activates the enabled session once")
        cold.backgroundDictationEnabled = false
        coldRecorder.microphonePermissionGranted = false
        cold.errorMessage = "Unrelated saved-data error."
        await cold.retryBackgroundDictation()
        try check(!cold.keyboardSessionActive && !coldRecorder.armed && cold.backgroundDictationError?.contains("permission") == true
                  && cold.errorMessage == "Unrelated saved-data error.",
                  "Denied automatic permission reports an inline microphone error without replacing an unrelated global error")
        await cold.refreshInstalledModels()
        try check(coldRecorder.armCalls == 2, "Denied permission cannot cause an automatic discovery retry loop")
        cold.backgroundDictationEnabled = false
    }

    @MainActor static func checkPendingBackgroundDictation() async throws {
        for pauseDuringPermission in [true, false] {
            let engine = ContextualLifecycleEngine()
            let defaults = UserDefaults(suiteName: "PendingBackgroundDictation-\(UUID())")!
            defaults.set(false, forKey: "backgroundDictationEnabled")
            defaults.set(false, forKey: "keepModelLoaded")
            let controller = await fixture(engine, preferences: defaults, automatic: true)
            let recorder = AudioRecorder.latest!
            AudioRecorder.holdNextArm = pauseDuringPermission
            let startup = Task { await controller.retryBackgroundDictation() }
            if pauseDuringPermission { await recorder.waitUntilArmHeld() }
            else { await engine.engine.waitUntilPreparationHeld() }
            do {
                if !pauseDuringPermission {
                    try check(controller.keyboardSessionActive && recorder.armed && !controller.actionButtonModelReady,
                              "The actual foreground microphone owns a lease while CPU preparation is pending")
                }
                controller.backgroundDictationEnabled = false
                recorder.releaseArm()
                await engine.engine.releasePreparation()
                await startup.value
                try check(!controller.keyboardSessionActive && !recorder.armed && !controller.backgroundDictationStarting && controller.phase == .idle,
                          "Pause fences late permission and CPU preparation completions without reopening microphone access")
                try check(controller.preparedModel == nil && !controller.actionButtonModelReady,
                          "Paused pending startup cannot publish a stale Ready runtime under Keep-Off")
            } catch {
                controller.backgroundDictationEnabled = false
                recorder.releaseArm(); await engine.engine.releasePreparation(); await startup.value
                throw error
            }
        }
        let engine = ContextualLifecycleEngine()
        let defaults = UserDefaults(suiteName: "BackgroundCPUPreparation-\(UUID())")!
        defaults.set(false, forKey: "backgroundDictationEnabled")
        defaults.set(false, forKey: "keepModelLoaded")
        let controller = await fixture(engine, preferences: defaults, automatic: true)
        let recorder = AudioRecorder.latest!
        let startup = Task { await controller.retryBackgroundDictation() }
        await engine.engine.waitUntilPreparationHeld()
        do {
            controller.setForeground(false)
            try check(controller.keyboardSessionActive && controller.phase == .preparing && !controller.actionButtonModelReady,
                      "An already activated foreground session protects pending CPU preparation on background entry")
            await engine.engine.releasePreparation(); await startup.value
            try check(controller.keyboardSessionActive && controller.actionButtonModelReady && recorder.activations == 1
                      && controller.preparedExecutionContext == .backgroundCapable,
                      "Background CPU preparation finishes Ready under the real shared lease even with Keep-Off")
        } catch {
            controller.backgroundDictationEnabled = false; await engine.engine.releasePreparation(); await startup.value; throw error
        }
        controller.backgroundDictationEnabled = false
        let cancelEngine = ContextualLifecycleEngine()
        let cancelDefaults = UserDefaults(suiteName: "CancelAutomaticPreparation-\(UUID())")!
        cancelDefaults.set(false, forKey: "backgroundDictationEnabled")
        cancelDefaults.set(false, forKey: "keepModelLoaded")
        let cancellation = await fixture(cancelEngine, preferences: cancelDefaults, automatic: true)
        defer { cancellation.backgroundDictationEnabled = false }
        let cancelRecorder = AudioRecorder.latest!
        let pending = Task { await cancellation.retryBackgroundDictation() }
        await cancelEngine.engine.waitUntilPreparationHeld()
        await cancellation.cancelPreparation()
        await cancelEngine.engine.releasePreparation(); await pending.value
        try check(cancellation.phase == .idle && !cancelRecorder.armed && !cancellation.keyboardSessionActive
                  && cancellation.keyboardSessionExpiresAt == nil && !cancellation.backgroundDictationStarting && cancellation.preparedModel == nil,
                  "Cancel preparation retires automatic startup, microphone and shared lease before any late Ready completion")
        await cancellation.refreshInstalledModels()
        try check(!cancellation.keyboardSessionActive, "Cancel preparation remains paused until an explicit retry or later app opening")
        cancellation.backgroundDictationEnabled = false
        let pressureEngine = ContextualLifecycleEngine()
        let pressureDefaults = UserDefaults(suiteName: "PressureDuringAutomaticPreparation-\(UUID())")!
        pressureDefaults.set(false, forKey: "backgroundDictationEnabled")
        pressureDefaults.set(false, forKey: "keepModelLoaded")
        let pressure = await fixture(pressureEngine, preferences: pressureDefaults, automatic: true)
        defer { pressure.backgroundDictationEnabled = false }
        let pressureRecorder = AudioRecorder.latest!
        let pressureStartup = Task { await pressure.retryBackgroundDictation() }
        await pressureEngine.engine.waitUntilPreparationHeld()
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        await waitForMicrophoneEnd(pressure)
        await pressureEngine.engine.releasePreparation(); await pressureStartup.value
        try check(pressure.phase == .idle && !pressure.keyboardSessionActive && !pressureRecorder.armed && pressure.preparedModel == nil,
                  "A forced memory warning retires even the early automatic CPU-preparation lease")
        pressure.backgroundDictationEnabled = false
    }

    @MainActor static func checkBackgroundReconfiguration() async throws {
        let engine = ContextualLifecycleEngine()
        await engine.engine.releasePreparation()
        let controller = await fixture(engine, automatic: true)
        let recorder = AudioRecorder.latest!
        defer { controller.backgroundDictationEnabled = false }
        await waitForBackgroundStartup(controller)
        controller.selectedModel = .parakeetPhononG4
        await waitForBackgroundStartup(controller)
        let selectedRequests = await engine.preparationRequests()
        try check(controller.selectedModel == .parakeetPhononG4 && controller.actionButtonModelReady && controller.keyboardSessionActive
                  && selectedRequests.last?.0 == .parakeetPhononG4 && recorder.activations == 2,
                  "Explicit idle selection reconfigures the microphone lease and prepares the new selected runtime")
        await engine.engine.holdNextPreparation()
        controller.selectedModel = .parakeetPhonon
        await engine.engine.waitUntilPreparationHeld()
        controller.selectedModel = .parakeetRealtimeEOU
        await engine.engine.releasePreparation()
        await waitForBackgroundStartup(controller)
        try check(controller.selectedModel == .parakeetRealtimeEOU && controller.preparedModel == .parakeetRealtimeEOU
                  && controller.keyboardSessionActive && !controller.backgroundDictationStarting,
                  "A selection change cancels pending idle preparation and only the replacement runtime becomes Ready")
        controller.selectedModel = .parakeetPhononG4
        await waitForBackgroundStartup(controller)
        let owner = UUID()
        try check(controller.reserveActionButtonRecording(requestID: owner, model: controller.selectedModel), "Model selection fixture reserves its ready runtime")
        controller.selectedModel = .parakeetPhonon
        try check(controller.selectedModel == .parakeetPhonon && controller.recordingModel == .parakeetPhononG4
                  && controller.recordingExecutionContext == .backgroundCapable && controller.preparedModel == .parakeetPhononG4
                  && controller.keyboardSessionActive,
                  "A new selection persists while the existing Action keeps its exact reserved runtime and microphone")
        await controller.cancelActionButtonRecording(requestID: owner)
        controller.selectedModel = .parakeetPhononG4
        await waitForBackgroundStartup(controller)
        for cancel in [false, true] {
            await engine.engine.holdNextDownload()
            let download = Task { await controller.download(.parakeetRealtimeEOU) }
            await engine.engine.waitUntilDownloadHeld()
            do {
                try check(!controller.keyboardSessionActive && !recorder.armed, "An explicit download pauses only the idle microphone lease")
                if cancel { controller.cancelDownload() }
                await engine.engine.releaseHeldDownload(); await download.value
                await waitForBackgroundStartup(controller)
                try check(controller.keyboardSessionActive && controller.actionButtonModelReady && controller.selectedModel == .parakeetPhononG4,
                          "Download completion or cancellation resumes only the selected automatic session")
            } catch {
                controller.cancelDownload(); await engine.engine.releaseHeldDownload(); await download.value; throw error
            }
        }
        recorder.onInterruption?()
        try check(!controller.keyboardSessionActive && !recorder.armed && controller.backgroundDictationError?.contains("interrupted") == true,
                  "A real interruption revokes the microphone lease and exposes a session-specific retry error")
        await controller.refreshInstalledModels()
        try check(!controller.keyboardSessionActive, "Interruption does not trigger a catalog retry loop")
        controller.setForeground(false); controller.setForeground(true)
        await waitForBackgroundStartup(controller)
        try check(controller.keyboardSessionActive && controller.backgroundDictationError == nil, "A later foreground opening recovers once after interruption")
        recorder.microphonePermissionGranted = false
        controller.setForeground(false); controller.setForeground(true)
        await waitForBackgroundStartup(controller)
        try check(!controller.keyboardSessionActive && !recorder.armed && controller.backgroundDictationError != nil,
                  "Foreground reopening observes lost permission and revokes the existing idle lease")
        recorder.microphonePermissionGranted = true
        await controller.retryBackgroundDictation()
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        await waitForMicrophoneEnd(controller)
        try check(!recorder.armed && controller.backgroundDictationEnabled && controller.backgroundDictationError?.contains("memory") == true,
                  "Forced memory pressure overrides Never without silently changing the enabled preference")
        await controller.refreshInstalledModels()
        try check(!controller.keyboardSessionActive, "Forced memory release cannot cause an automatic microphone retry loop")
        let missingEngine = ContextualLifecycleEngine()
        await missingEngine.engine.setInstalled([])
        await missingEngine.engine.releasePreparation()
        let missing = await fixture(missingEngine, automatic: true)
        defer { missing.backgroundDictationEnabled = false }
        let missingRecorder = AudioRecorder.latest!
        try check(!missing.keyboardSessionActive && missingRecorder.armCalls == 0,
                  "Default background startup waits for its selected model to be installed")
        await missingEngine.engine.holdNextDownload()
        let install = Task { await missing.download(.parakeetPhonon) }
        await missingEngine.engine.waitUntilDownloadHeld()
        await missingEngine.engine.releaseHeldDownload(); await install.value
        await waitForBackgroundStartup(missing)
        try check(missing.keyboardSessionActive && missing.actionButtonModelReady && missingRecorder.activations == 1,
                  "Completing the selected model download automatically opens the foreground session without settings navigation")
        missing.backgroundDictationEnabled = false
    }
    @MainActor static func main() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--background-dictation") {
            try await checkDefaultBackgroundDictation()
            try await checkPendingBackgroundDictation()
            try await checkBackgroundReconfiguration()
            print("PASS: \(checks) automatic background dictation lifecycle checks")
            return
        } else if arguments.contains("--action-startup-retention") {
            try await checkActionReservationRetention()
        } else if arguments.contains("--action-startup-cleanup") {
            try await checkActionReservationCleanup()
        } else if arguments.contains("--action-startup-errors") {
            try await checkActionStartupErrors()
        } else {
            try await checkActionReservationRetention()
            try await checkActionReservationCleanup()
            try await checkActionStartupErrors()
        }
        if arguments.contains(where: { $0.hasPrefix("--action-startup-") }) {
            print("PASS: \(checks) focused Action startup lifecycle checks")
            return
        }
        try await checkDefaultBackgroundDictation()
        try await checkPendingBackgroundDictation()
        try await checkBackgroundReconfiguration()
        try await checkExplicitMicrophoneActionCycles()
        let engine = LifecycleEngine()
        let controller = await fixture(engine)
        let recorder = AudioRecorder.latest!
        try await eventually { await engine.counts().0 == 1 }
        try check(controller.phase == .idle, "Foreground prewarm leaves Record available")
        try check(controller.modelStatus != nil, "Only actual pending load has model status")
        await controller.startRecording()
        try check(controller.phase == .recording && recorder.recording, "Microphone starts before blocked model loading")
        try check(!recorder.lastMixWithOtherAudio && !recorder.lastRequireExistingPermission,
                  "Normal Dictate keeps its nonmixable foreground activation and permission request")
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
        let deadlineBeforeKeyboardStop = keyboardController.keyboardSessionExpiresAt!
        try shared.writeCommand(KeyboardCommand(sessionID: session, utteranceID: utterance, action: .stop))
        try await eventually { keyboardController.phase == .idle }
        guard let result = try shared.readStatus() else { throw CheckFailure.failed("No keyboard result") }
        try check(result.sessionID == session && result.utteranceID == utterance, "Stop renewal preserves command ownership")
        try check(result.transcript == "Captured words." && result.hasDeliverableResult(), "Renewed keyboard lease delivers completed text")
        try check(keyboardController.keyboardSessionExpiresAt.map { $0 > deadlineBeforeKeyboardStop } == true,
                  "Keyboard Stop advances its actual idle deadline from the pre-Stop value")
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
        try await eventually { ownershipController.preparedModel == .parakeetPhononG4 }
        let retainedActionPreparations = await ownershipEngine.preparations()
        try check(retainedActionPreparations == [.parakeetRealtimeEOU, .parakeetPhononG4],
                  "Returning after selection changed during capture prepares that selected model for the next Action")
        ownershipController.selectedModel = .parakeetPhonon
        try await eventually { ownershipController.preparedModel == .parakeetPhonon }
        let explicitPreparations = await ownershipEngine.preparations()
        try check(explicitPreparations == [.parakeetRealtimeEOU, .parakeetPhononG4, .parakeetPhonon],
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
                  && unifiedController.errorMessage?.contains("wait until") == true,
                  "Cold background Action directs opening the app and waiting for Ready before arming microphone")
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
        try check(contextualController.preparedExecutionContext == .backgroundCapable && contextualController.actionButtonModelReady,
                  "Keep-loaded foreground prewarm prepares the selected model's actual Action CPU configuration")
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
        try check(contextualPreparations.count == 1
                  && contextualPreparations[0].0 == .parakeetPhonon && contextualPreparations[0].1 == .backgroundCapable,
                  "Foreground prewarm, Action, return, refresh, Dictate and keyboard share one selected CPU runtime")
        contextualController.selectedModel = .parakeetPhononG4
        try await eventually { contextualController.preparedModel == .parakeetPhononG4 }
        try check(contextualController.preparedExecutionContext == .backgroundCapable && contextualController.actionButtonModelReady,
                  "Explicit selected model change with retention ON prepares its Action CPU configuration")

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
        let cancelledContextStart = Task { await cancelledContextController.startActionButtonRecording() }
        try await eventually { await cancelledContextEngine.engine.counts().0 == 1 }
        let cancellingContext = Task { await cancelledContextController.cancelRecording() }
        try await eventually { cancelledContextController.phase == .idle }
        await cancelledContextEngine.engine.releasePreparation()
        await cancellingContext.value
        await cancelledContextStart.value
        try check(cancelledContextController.preparedModel == nil && cancelledContextController.preparedExecutionContext == nil
                  && cancelledContextController.recordingExecutionContext == nil && !cancelledContextRecorder.recording,
                  "Cancelled CPU preparation cannot publish late ready context or retain microphone capture")
        await cancelledContextController.startRecording()
        try await eventually { cancelledContextController.preparedExecutionContext == .foreground }
        try check(cancelledContextController.recordingModel == .parakeetPhonon
                  && cancelledContextController.recordingExecutionContext == .foreground,
                  "Replacement Dictate starts the selected model in its own foreground execution context")
        await cancelledContextController.cancelRecording()

        // Ready is the selected Action CPU configuration, and cold background
        // startup must never activate audio or start a new model load.
        let coldReadyEngine = ContextualLifecycleEngine()
        await coldReadyEngine.engine.releasePreparation()
        let coldReadyDefaults = UserDefaults(suiteName: "LocalScribeColdReadyCheck-\(UUID())")!
        coldReadyDefaults.set(false, forKey: "keepModelLoaded")
        let coldReadyController = await fixture(coldReadyEngine, preferences: coldReadyDefaults)
        let coldReadyRecorder = AudioRecorder.latest!
        coldReadyController.setForeground(false)
        await coldReadyController.startActionButtonRecording()
        let coldReadyRequests = await coldReadyEngine.preparationRequests()
        try check(coldReadyRequests.isEmpty && coldReadyRecorder.armCalls == 0 && !coldReadyRecorder.recording,
                  "Cold background Action refuses before model preparation and microphone activation")
        try check(coldReadyController.phase == .idle && coldReadyController.currentRecordingID == nil
                  && coldReadyController.elapsed == 0 && coldReadyController.recordingModel == nil
                  && coldReadyController.errorMessage?.contains("wait until") == true,
                  "Cold background refusal has no recording owner or timer and gives the Ready instruction")

        let readyGateEngine = ContextualLifecycleEngine()
        let readyGateDefaults = UserDefaults(suiteName: "LocalScribeReadyGateCheck-\(UUID())")!
        readyGateDefaults.set(false, forKey: "keepModelLoaded")
        let readyGateController = await fixture(readyGateEngine, preferences: readyGateDefaults)
        let readyGateRecorder = AudioRecorder.latest!
        let readyGateOwner = UUID()
        let readyGateStart = Task { await readyGateController.startActionButtonRecording(requestID: readyGateOwner) }
        try await eventually { await readyGateEngine.engine.counts().0 == 1 }
        try check(readyGateController.phase == .preparing && readyGateController.actionButtonModelLoading
                  && !readyGateController.actionButtonModelReady && readyGateRecorder.armCalls == 0
                  && !readyGateRecorder.recording && readyGateController.currentRecordingID == nil && readyGateController.elapsed == 0,
                  "Foreground Action preparation remains cancellable and admits no microphone audio before Ready")
        await readyGateEngine.engine.releasePreparation()
        await readyGateStart.value
        try check(readyGateController.actionButtonModelReady && readyGateController.phase == .recording
                  && readyGateRecorder.armCalls == 1 && readyGateController.recordingExecutionContext == .backgroundCapable,
                  "Action arms once only after the exact selected CPU runtime is ready")
        await readyGateController.cancelRecording()

        let flightEngine = ContextualLifecycleEngine()
        let flightController = await fixture(flightEngine)
        let flightRecorder = AudioRecorder.latest!
        try await eventually { await flightEngine.engine.counts().0 == 1 }
        try check(flightController.actionButtonModelLoading && !flightController.actionButtonModelReady,
                  "Idle CPU prewarm is Loading rather than Ready until preparation completes")
        flightController.setForeground(false)
        await flightController.startActionButtonRecording()
        let pendingFlightCounts = await flightEngine.engine.counts()
        try check(pendingFlightCounts.0 == 1 && pendingFlightCounts.2 == 0 && flightRecorder.armCalls == 0
                  && flightController.actionButtonModelLoading,
                  "Backgrounding retains the CPU preparation flight but cold Action still refuses activation")
        await flightEngine.engine.releasePreparation()
        try await eventually { flightController.actionButtonModelReady }
        let readyFlightCounts = await flightEngine.engine.counts()
        try check(readyFlightCounts.2 == 0 && !flightRecorder.armed,
                  "Ready selected CPU references remain resident in background without an audio keepalive")
        await flightController.startActionButtonRecording()
        flightRecorder.feed(8_000)
        await flightController.stopActionButtonRecording()
        flightController.setForeground(true)
        await flightController.refreshInstalledModels()
        await flightController.startRecording()
        flightRecorder.feed(8_000)
        await flightController.stopRecording()
        let reusedFlightRequests = await flightEngine.preparationRequests()
        try check(reusedFlightRequests.count == 1 && flightController.actionButtonModelReady,
                  "Ready background Action and the following in-app recording reuse the one retained CPU runtime")

        let revalidationOwner = UUID()
        try check(flightController.reserveActionButtonRecording(requestID: revalidationOwner, model: .parakeetPhonon),
                  "Readiness can be reserved before the bridge's Activity await")
        let preActivityReady = await flightController.prepareReservedActionButtonRecording(requestID: revalidationOwner)
        try check(preActivityReady, "Bridge preparation gate confirms Ready before creating its Activity")
        let armsBeforePressure = flightRecorder.armCalls
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await eventually { !flightController.actionButtonModelReady }
        await flightController.startReservedActionButtonRecording(requestID: revalidationOwner)
        let postPressureRequests = await flightEngine.preparationRequests()
        try check(flightRecorder.armCalls == armsBeforePressure && flightController.phase == .idle
                  && flightController.currentRecordingID == nil && postPressureRequests.count == 1,
                  "Memory pressure after the Activity await invalidates Ready and cannot trigger activation or a late reload")
        try check(flightController.errorMessage?.contains("wait until") == true,
                  "Readiness invalidation gives the same open-app/wait-Ready instruction")

        // A platform intent lease owns its completion; the retired finite UIKit
        // callback cannot set an expiry error on that completion or a replacement.
        let leaseEngine = LifecycleEngine()
        await leaseEngine.releasePreparation()
        let leaseController = await fixture(leaseEngine, model: .parakeetRealtimeEOU)
        let leaseRecorder = AudioRecorder.latest!
        try await eventually { leaseController.actionButtonModelReady }
        let leaseOwner = UUID()
        await leaseController.startActionButtonRecording(requestID: leaseOwner)
        leaseRecorder.feed(8_000)
        await leaseEngine.holdFinalization()
        let fallbackLeaseStartCount = UIApplication.shared.backgroundTaskStarts
        let fallbackCompletion = Task { await leaseController.stopActionButtonRecording() }
        try await eventually { await leaseEngine.finalizationIsHeld() }
        try check(UIApplication.shared.backgroundTaskStarts == fallbackLeaseStartCount + 1,
                  "Ordinary Action completion still receives the finite UIKit fallback assertion")
        let fallbackLeaseID = UIApplication.shared.backgroundTaskStarts
        let retiredExpiry = UIApplication.shared.backgroundTaskExpirations[fallbackLeaseID]!
        let endsBeforeAdoption = UIApplication.shared.backgroundTaskEnds
        retiredExpiry()
        try check(!leaseController.adoptPlatformManagedActionCompletion(requestID: UUID()),
                  "A mismatched request cannot adopt another Action completion")
        try check(leaseController.adoptPlatformManagedActionCompletion(requestID: leaseOwner),
                  "The matching long-running intent adopts an already-transcribing Action completion")
        for _ in 0..<10 { await Task.yield() }
        try check(UIApplication.shared.backgroundTaskEnds == endsBeforeAdoption + 1 && leaseController.errorMessage == nil,
                  "Adoption retires the finite assertion and fences its already-queued expiry callback")
        await leaseEngine.releaseFinalization()
        await fallbackCompletion.value

        let newLeaseOwner = UUID()
        await leaseController.startActionButtonRecording(requestID: newLeaseOwner)
        leaseRecorder.feed(8_000)
        await leaseEngine.holdFinalization()
        let replacementCompletion = Task { await leaseController.stopActionButtonRecording() }
        try await eventually { await leaseEngine.finalizationIsHeld() }
        retiredExpiry()
        for _ in 0..<10 { await Task.yield() }
        try check(leaseController.phase == .transcribing && leaseController.errorMessage == nil,
                  "An older finite expiry callback cannot report a false error on the next recording's completion")
        let actualExpiry = UIApplication.shared.backgroundTaskExpirations[UIApplication.shared.backgroundTaskStarts]!
        actualExpiry()
        try await eventually { leaseController.errorMessage?.contains("iOS ended background processing") == true }
        try check(leaseController.phase == .transcribing,
                  "A genuine current finite assertion expiry remains visible while completion is pending")
        await leaseEngine.releaseFinalization()
        await replacementCompletion.value

        let managedLeaseOwner = UUID()
        await leaseController.startActionButtonRecording(requestID: managedLeaseOwner)
        leaseRecorder.feed(8_000)
        await leaseEngine.holdFinalization()
        let startsBeforeManaged = UIApplication.shared.backgroundTaskStarts
        let managedCompletion = Task {
            await leaseController.stopActionButtonRecording(completionIsPlatformManaged: true)
        }
        try await eventually { await leaseEngine.finalizationIsHeld() }
        try check(UIApplication.shared.backgroundTaskStarts == startsBeforeManaged && leaseController.errorMessage == nil,
                  "Platform-managed Action completion does not start a redundant finite UIKit assertion")
        await leaseEngine.releaseFinalization()
        await managedCompletion.value

        let preserveEngine = ContextualLifecycleEngine()
        await preserveEngine.engine.releasePreparation()
        let preserveDefaults = UserDefaults(suiteName: "LocalScribePreparePreservesTextCheck-\(UUID())")!
        preserveDefaults.set(false, forKey: "keepModelLoaded")
        let preserveController = await fixture(preserveEngine, preferences: preserveDefaults)
        let preserveRecorder = AudioRecorder.latest!
        preserveController.saveHistory = true
        await preserveController.startRecording()
        preserveRecorder.feed(8_000)
        await preserveController.stopRecording()
        let savedText = preserveController.transcript
        let savedHistory = preserveController.history
        let originalArmCalls = preserveRecorder.armCalls
        try check(savedText == "Captured words." && savedHistory.count == 1,
                  "Prior completed text and its saved history exist before cold Action preparation")
        preserveController.transcript = "An unsaved edit to the previous result."
        await preserveEngine.engine.holdNextPreparation()
        let preserveOwner = UUID()
        let preservingStart = Task { await preserveController.startActionButtonRecording(requestID: preserveOwner) }
        try await eventually { preserveController.phase == .preparing && preserveController.actionButtonModelLoading }
        await preserveController.cancelActionButtonRecording(requestID: UUID())
        try check(preserveController.phase == .preparing && preserveController.recordingModel == .parakeetPhonon,
                  "A stale Action cancellation cannot retire the owned cold preparation")
        await preserveController.cancelActionButtonRecording(requestID: preserveOwner)
        await preserveEngine.engine.releasePreparation()
        await preservingStart.value
        try check(preserveController.phase == .idle && preserveController.transcript == "An unsaved edit to the previous result."
                  && preserveController.rawTranscript == savedText && preserveController.history == savedHistory
                  && preserveRecorder.armCalls == originalArmCalls && !preserveRecorder.recording,
                  "Cancelling cold Action preparation preserves prior saved and unsaved text without admitting audio")
        await preserveEngine.failNextBackgroundPreparation()
        await preserveController.startActionButtonRecording()
        try check(preserveController.phase == .idle && preserveController.errorMessage != nil
                  && preserveController.transcript == "An unsaved edit to the previous result."
                  && preserveController.rawTranscript == savedText && preserveController.history == savedHistory
                  && preserveRecorder.armCalls == originalArmCalls,
                  "Failed CPU warming preserves the prior result and history without starting a microphone session")

        // Record can beat the queued idle warm-up. Retention ON must choose
        // the same Action CPU key directly rather than leave a ready ANE model.
        let immediateEngine = ContextualLifecycleEngine()
        await immediateEngine.engine.releasePreparation()
        let immediateDefaults = UserDefaults(suiteName: "LocalScribeImmediateCPUCheck-\(UUID())")!
        immediateDefaults.set(false, forKey: "keepModelLoaded")
        let immediateController = await fixture(immediateEngine, preferences: immediateDefaults)
        let immediateRecorder = AudioRecorder.latest!
        FixturePrewarmGate.held = true
        immediateController.keepModelLoaded = true
        try await eventually { !FixturePrewarmGate.continuations.isEmpty }
        await immediateController.startRecording()
        try check(immediateController.recordingExecutionContext == .backgroundCapable,
                  "Immediate Record with retention ON freezes the Action CPU context before queued prewarm runs")
        immediateRecorder.feed(8_000)
        await immediateController.stopRecording()
        FixturePrewarmGate.release()
        for _ in 0..<10 { await Task.yield() }
        let immediateRequests = await immediateEngine.preparationRequests()
        try check(immediateController.actionButtonModelReady && immediateRequests.count == 1
                  && immediateRequests[0].0 == .parakeetPhonon && immediateRequests[0].1 == .backgroundCapable,
                  "Immediate Record finishes Ready for Action with one CPU preparation and no acceleration swap")

        let immediateOffEngine = ContextualLifecycleEngine()
        await immediateOffEngine.engine.releasePreparation()
        let immediateOffDefaults = UserDefaults(suiteName: "LocalScribeImmediateOFFCheck-\(UUID())")!
        immediateOffDefaults.set(false, forKey: "keepModelLoaded")
        let immediateOffController = await fixture(immediateOffEngine, preferences: immediateOffDefaults)
        let immediateOffRecorder = AudioRecorder.latest!
        await immediateOffController.startRecording()
        try check(immediateOffController.recordingExecutionContext == .foreground,
                  "Cold Record with retention OFF preserves foreground acceleration")
        immediateOffRecorder.feed(8_000)
        await immediateOffController.stopRecording()
        let immediateOffRequests = await immediateOffEngine.preparationRequests()
        try check(immediateOffRequests.count == 1 && immediateOffRequests[0].1 == .foreground
                  && immediateOffController.preparedModel == nil,
                  "Retention OFF loads the foreground context on demand and releases it after completion")

        let immediateKeyboardEngine = ContextualLifecycleEngine()
        await immediateKeyboardEngine.engine.releasePreparation()
        let immediateKeyboardDefaults = UserDefaults(suiteName: "LocalScribeImmediateKeyboardCPUCheck-\(UUID())")!
        immediateKeyboardDefaults.set(false, forKey: "keepModelLoaded")
        let immediateKeyboardController = await fixture(immediateKeyboardEngine, preferences: immediateKeyboardDefaults)
        FixturePrewarmGate.held = true
        immediateKeyboardController.keepModelLoaded = true
        try await eventually { !FixturePrewarmGate.continuations.isEmpty }
        await immediateKeyboardController.enableKeyboardSession()
        try check(immediateKeyboardController.keyboardSessionActive && immediateKeyboardController.actionButtonModelReady,
                  "Keyboard setup that beats queued prewarm also prepares the retained Action CPU context")
        immediateKeyboardController.disableKeyboardSession()
        FixturePrewarmGate.release()
        for _ in 0..<10 { await Task.yield() }
        let immediateKeyboardRequests = await immediateKeyboardEngine.preparationRequests()
        try check(immediateKeyboardRequests.count == 1 && immediateKeyboardRequests[0].1 == .backgroundCapable,
                  "Immediate keyboard setup retains one CPU runtime without a later context switch")

        // Retention can be enabled while an OFF recording still owns its ANE
        // runtime. That retained context must not beat ON's CPU policy.
        for useKeyboard in [false, true] {
            let retainedForegroundEngine = ContextualLifecycleEngine()
            await retainedForegroundEngine.engine.releasePreparation()
            let retainedForegroundDefaults = UserDefaults(suiteName: "LocalScribeRetainedForegroundCPUCheck-\(UUID())")!
            retainedForegroundDefaults.set(false, forKey: "keepModelLoaded")
            let retainedForegroundController = await fixture(retainedForegroundEngine, preferences: retainedForegroundDefaults)
            let retainedForegroundRecorder = AudioRecorder.latest!
            await retainedForegroundController.startRecording()
            try await eventually { retainedForegroundController.preparedExecutionContext == .foreground }
            retainedForegroundController.keepModelLoaded = true
            retainedForegroundRecorder.feed(8_000)
            await retainedForegroundController.stopRecording()
            try check(retainedForegroundController.preparedExecutionContext == .foreground
                      && !retainedForegroundController.actionButtonModelReady,
                      "Changing retention during an OFF capture leaves its original foreground runtime frozen until completion")
            FixturePrewarmGate.held = true
            await retainedForegroundController.refreshInstalledModels()
            try await eventually { !FixturePrewarmGate.continuations.isEmpty }
            if useKeyboard {
                await retainedForegroundController.enableKeyboardSession()
                retainedForegroundController.disableKeyboardSession()
            } else {
                await retainedForegroundController.startRecording()
                try check(retainedForegroundController.recordingExecutionContext == .backgroundCapable,
                          "Retention ON overrides an already-retained accelerated context for the next Record")
                retainedForegroundRecorder.feed(8_000)
                await retainedForegroundController.stopRecording()
            }
            FixturePrewarmGate.release()
            for _ in 0..<10 { await Task.yield() }
            let retainedForegroundRequests = await retainedForegroundEngine.preparationRequests()
            try check(retainedForegroundController.actionButtonModelReady && retainedForegroundRequests.count == 2
                      && retainedForegroundRequests[0].1 == .foreground && retainedForegroundRequests[1].1 == .backgroundCapable,
                      "Record and keyboard setup obey retention ON before queued warming, replacing accelerated state exactly once")
        }

        print("PASS: \(checks) actual AppController lifecycle checks")
    }
}
