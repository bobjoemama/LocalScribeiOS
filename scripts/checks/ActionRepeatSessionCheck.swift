import Foundation
import LocalScribeCore

private enum ActionStartObservation {
    // Ignore unrelated launch/foreground discovery; count the real invocation's
    // installation calls across its actor hops and child tasks.
    @TaskLocal static var tracked = false
}

// Suspension points and late callbacks exercise the real intent/runtime/bridge/
// controller pipeline without activating a microphone or loading a speech model.
actor RepeatActionEngine: StreamingLocalTranscriptionEngine, BackgroundInferenceReportingEngine {
    let engine = LifecycleEngine()
    var discovery: CheckedContinuation<Void, Never>?
    var holdDiscovery = false
    private var trackedDiscoveryOnly = false
    private var discoveryHeld: (@Sendable () -> Void)?
    private var discoveryWaiter: CheckedContinuation<Void, Never>?
    private var observedDiscoveryModels: [SpeechModel] = []
    var finalText = "Captured words."
    func holdModelDiscovery(trackedOnly: Bool = false, onHold: (@Sendable () -> Void)? = nil) {
        holdDiscovery = true
        trackedDiscoveryOnly = trackedOnly
        discoveryHeld = onHold
    }
    func discovering() -> Bool { discovery != nil }
    func waitUntilDiscoveryIsHeld() async {
        if discovery != nil { return }
        await withCheckedContinuation { discoveryWaiter = $0 }
    }
    func discoveryModelsForObservedStart() -> [SpeechModel] { observedDiscoveryModels }
    func releaseDiscovery() {
        holdDiscovery = false
        trackedDiscoveryOnly = false
        discoveryHeld = nil
        discovery?.resume(); discovery = nil
    }
    func setFinalText(_ text: String) { finalText = text }
    func isInstalled(_ model: SpeechModel) async -> Bool {
        if ActionStartObservation.tracked { observedDiscoveryModels.append(model) }
        if holdDiscovery, !trackedDiscoveryOnly || ActionStartObservation.tracked {
            await withCheckedContinuation {
                discovery = $0
                discoveryWaiter?.resume(); discoveryWaiter = nil
                discoveryHeld?()
            }
        }
        return await engine.isInstalled(model)
    }
    func supportsBackgroundInference(for model: SpeechModel) async -> Bool { await engine.supportsBackgroundInference(for: model) }
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws { try await engine.download(model, progress: progress) }
    func prepare(_ model: SpeechModel) async throws { try await engine.prepare(model) }
    func beginStreaming(onUpdate: @escaping @Sendable (SpeechTranscriptUpdate) -> Void) async throws { try await engine.beginStreaming(onUpdate: onUpdate) }
    func appendStreaming(samples: [Float]) async throws { try await engine.appendStreaming(samples: samples) }
    func finishStreaming() async throws -> String { _ = try await engine.finishStreaming(); return finalText }
    func cancelStreaming() async { await engine.cancelStreaming() }
    func transcribe(samples: [Float]) async throws -> String { finalText }
    func unload() async { await engine.unload() }
}

@main struct ActionRepeatSessionCheck {
    enum Failure: Error { case check(String) }
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure.check(message) }
        checks += 1
    }
    @MainActor static func waitFor(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw Failure.check("Fixture deadline") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func checkWarmStart(
        controller: AppController, bridge: DictationActionBridge,
        recorder: AudioRecorder, engine: RepeatActionEngine
    ) async throws {
        // Race observable boundary events, not a time window: a Ready Start
        // must reach required Activity/capture while its catalog I/O is blocked.
        enum WarmStartBoundary: Sendable { case catalog, capture, returned }
        let (boundaries, boundarySignal) = AsyncStream<WarmStartBoundary>.makeStream()
        await engine.holdModelDiscovery(trackedOnly: true, onHold: { boundarySignal.yield(.catalog) })
        let activityStartsBeforeWarmStart = DictationLiveActivity.requiredStarts
        let captureBoundary = controller.$phase.dropFirst().sink { phase in
            if phase == .recording { boundarySignal.yield(.capture) }
        }
        defer { captureBoundary.cancel(); boundarySignal.finish() }
        let observedStart = Task {
            // Both failure and success signal return. A failed startup must not
            // leave the consumer waiting for a capture event that cannot arrive.
            defer { boundarySignal.yield(.returned) }
            return try await ActionStartObservation.$tracked.withValue(true) {
                try await ToggleDictationShortcut().perform()
            }
        }
        do {
            var boundary = boundaries.makeAsyncIterator()
            let firstBoundary = await boundary.next()
            if firstBoundary == .catalog {
                await engine.releaseDiscovery()
                _ = try await observedStart.value
                let observedModels = await engine.discoveryModelsForObservedStart()
                throw Failure.check("Ready Start blocked on catalog I/O before Activity/capture; \(observedModels.count) profile checks after release")
            }
            let warmStart = try await observedStart.value
            let warmDiscoveryModels = await engine.discoveryModelsForObservedStart()
            try check(firstBoundary == .capture && warmStart.value == ""
                      && DictationLiveActivity.requiredStarts == activityStartsBeforeWarmStart + 1
                      && controller.phase == .recording && recorder.recording,
                      "Ready Start reaches its required Activity and capture without waiting on catalog discovery")
            try check(warmDiscoveryModels.isEmpty,
                      "Ready Start performs zero catalog installation checks on its critical path")
            print("Observed Ready Start catalog checks: \(warmDiscoveryModels.count)")
            await engine.releaseDiscovery()
            await DictationActionRuntime.cancel(sessionID: bridge.sessionIdentifier!)
        } catch {
            await engine.releaseDiscovery()
            observedStart.cancel()
            _ = await observedStart.result
            if let id = bridge.sessionIdentifier { await DictationActionRuntime.cancel(sessionID: id) }
            throw error
        }
    }
    @MainActor static func checkCancelledAutomaticStart(
        controller: AppController, bridge: DictationActionBridge, recorder: AudioRecorder
    ) async throws {
        enum Boundary { case held, returned }
        let (boundaries, signal) = AsyncStream<Boundary>.makeStream()
        let previousStartHeld = DictationLiveActivity.onStartHeld
        DictationLiveActivity.onStartHeld = { signal.yield(.held) }
        DictationLiveActivity.holdNextStart = true
        defer {
            DictationLiveActivity.releaseStart()
            DictationLiveActivity.holdNextStart = false
            DictationLiveActivity.onStartHeld = previousStartHeld
            signal.finish()
        }
        let activations = recorder.activations
        let start = Task {
            defer { signal.yield(.returned) }
            return try await ToggleDictationShortcut().perform()
        }
        do {
            var events = boundaries.makeAsyncIterator()
            guard await events.next() == .held else {
                _ = try await start.value
                throw Failure.check("Automatic cancellation must reach the held required Activity")
            }
            await DictationActionRuntime.cancel(sessionID: bridge.sessionIdentifier!)
            DictationLiveActivity.releaseStart()
            do {
                _ = try await start.value
                throw Failure.check("Cancelled automatic-session Start must fail")
            } catch is CancellationError { checks += 1 }
            try check(!bridge.hasActiveSession && controller.phase == .idle && !recorder.recording
                      && recorder.armed && controller.keyboardSessionActive && controller.actionButtonModelReady
                      && recorder.activations == activations,
                      "Cancelling an unstarted Activity retains the independent automatic microphone without capture")
        } catch {
            DictationLiveActivity.releaseStart()
            start.cancel()
            _ = await start.result
            if let id = bridge.sessionIdentifier { await DictationActionRuntime.cancel(sessionID: id) }
            throw error
        }
    }
    @MainActor static func checkContextualPhononCycles(retainMicrophone: Bool, automatic: Bool = false) async throws {
        let engine = ContextualLifecycleEngine()
        await engine.engine.releasePreparation()
        let suite = "ActionPhononCheck-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "saveHistory")
        if !automatic {
            defaults.set(false, forKey: "backgroundDictationEnabled")
            defaults.set(5, forKey: "keyboardIdleMinutes")
        }
        defaults.set(retainMicrophone, forKey: "keepModelLoaded")
        defaults.set(SpeechModel.parakeetPhonon.rawValue, forKey: "selectedModel")
        let history = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite)/history.json")
        let previousHandler = DictationActionRuntime.handler
        let previousSessionIdentifier = DictationActionRuntime.sessionIdentifier
        let previousRecorder = AudioRecorder.latest
        let previousStartHeld = DictationLiveActivity.onStartHeld
        let previousAuthorized = DictationLiveActivity.authorized
        let previousRequestSucceeds = DictationLiveActivity.requestSucceeds
        let controller = AppController(engine: engine, defaults: defaults, historyURL: history)
        let bridge = DictationActionBridge(controller: controller)
        let recorder = AudioRecorder.latest!
        let (startupCompletions, startupSignal) = AsyncStream<Void>.makeStream()
        let startupCompletion = controller.$backgroundDictationStarting.dropFirst().sink { starting in
            if !starting { startupSignal.yield(()) }
        }
        defer {
            startupCompletion.cancel()
            startupSignal.finish()
            DictationLiveActivity.onStartHeld = previousStartHeld
            DictationLiveActivity.authorized = previousAuthorized
            DictationLiveActivity.requestSucceeds = previousRequestSucceeds
            DictationLiveActivity.holdNextStart = false
            DictationLiveActivity.releaseStart()
            recorder.rejectNewBackgroundActivation = false
            controller.disableKeyboardSession()
            controller.keepModelLoaded = false
            DictationActionRuntime.handler = previousHandler
            DictationActionRuntime.sessionIdentifier = previousSessionIdentifier
            AudioRecorder.latest = previousRecorder
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: history.deletingLastPathComponent())
        }
        await controller.refreshInstalledModels(prewarm: automatic)
        if retainMicrophone {
            if automatic {
                try check(controller.backgroundDictationEnabled && controller.keyboardIdleMinutes == 0,
                          "Fresh settings enable persistent background dictation with Never timeout")
                if controller.backgroundDictationStarting {
                    var completions = startupCompletions.makeAsyncIterator()
                    _ = await completions.next()
                }
            } else {
                await controller.enableKeyboardSession()
            }
            try check(controller.keyboardSessionActive && recorder.armed
                      && controller.phase == .idle
                      && controller.preparedModel == .parakeetPhonon
                      && controller.preparedExecutionContext == .backgroundCapable
                      && controller.actionButtonModelReady,
                      "Foreground Phonon microphone session prepares the actual background-capable configuration (automatic \(automatic))")
            if automatic {
                try check(controller.keyboardSessionExpiresAt == .distantFuture && recorder.activations == 1,
                          "Automatic foreground arming establishes one persistent authorized microphone lease")
            }
            controller.setForeground(false)
            recorder.rejectNewBackgroundActivation = true
            if automatic {
                try await checkCancelledAutomaticStart(controller: controller, bridge: bridge, recorder: recorder)
            }
        }
        let leaseActivations = recorder.activations
        if automatic {
            // Reject both requests before any Activity is accepted. A retained
            // Activity from an earlier successful utterance must not mask loss
            // of this independently foreground-armed microphone lease.
            for rejectedActivity in ["authorization", "request"] {
                DictationLiveActivity.authorized = rejectedActivity != "authorization"
                DictationLiveActivity.requestSucceeds = rejectedActivity != "request"
                do {
                    _ = try await ToggleDictationShortcut().perform()
                    if let id = bridge.sessionIdentifier { await DictationActionRuntime.cancel(sessionID: id) }
                    throw Failure.check("Unavailable required Activity must reject automatic-session capture")
                } catch DictationActionError.failed { checks += 1 }
                try check(!bridge.hasActiveSession && controller.phase == .idle && !recorder.recording
                          && recorder.armed && controller.keyboardSessionActive && controller.actionButtonModelReady
                          && recorder.activations == leaseActivations,
                          "Rejected \(rejectedActivity) preserves the independent automatic idle microphone without capture")
                DictationLiveActivity.authorized = true
                DictationLiveActivity.requestSucceeds = true
            }
        }
        var retiredSession: UUID?
        for cycle in 1...2 {
            if !retainMicrophone { controller.setForeground(true) }
            let expectedText = "Phonon cycle \(cycle)."
            await engine.engine.setFinalText(expectedText)
            enum StartBoundary { case activityHeld, returned }
            let (boundaries, signal) = AsyncStream<StartBoundary>.makeStream()
            DictationLiveActivity.onStartHeld = { signal.yield(.activityHeld) }
            DictationLiveActivity.holdNextStart = true
            let start = Task {
                defer { signal.yield(.returned) }
                return try await ToggleDictationShortcut().perform()
            }
            do {
                var events = boundaries.makeAsyncIterator()
                let first = await events.next()
                if first != .activityHeld {
                    _ = try await start.value
                    throw Failure.check("Contextual Start must reach its held required Activity before returning")
                }
                try check(controller.phase == .idle && !recorder.recording
                          && controller.preparedModel == .parakeetPhonon
                          && controller.preparedExecutionContext == .backgroundCapable
                          && controller.actionButtonModelReady,
                          "Phonon cycle \(cycle) is Ready in its exact background configuration before Activity/capture")
                let id = bridge.sessionIdentifier!
                controller.setForeground(false)
                try check(controller.actionButtonModelReady
                          && controller.preparedExecutionContext == .backgroundCapable
                          && bridge.sessionIdentifier == id && !recorder.recording,
                          "Reserved Phonon cycle \(cycle) remains Ready when backgrounding during held Activity (retention \(retainMicrophone))")
                DictationLiveActivity.releaseStart()
                let result = try await start.value
                signal.finish()
                DictationLiveActivity.onStartHeld = previousStartHeld
                try check(result.value == "" && controller.phase == .recording && recorder.recording
                          && controller.recordingModel == .parakeetPhonon
                          && controller.recordingExecutionContext == .backgroundCapable,
                          "Contextual Phonon Start reaches actual capture after the required Activity returns")
                if let retiredSession {
                    try check(id != retiredSession, "Repeated contextual Phonon capture gets a fresh session")
                }
                recorder.feed(32_000)
                let stop = try await ToggleDictationShortcut().perform()
                try check(stop.value == expectedText && controller.phase == .idle
                          && !recorder.recording && !bridge.hasActiveSession,
                          "Contextual Phonon second hold returns only cycle \(cycle)'s transcript and retires its utterance")
                if retainMicrophone {
                    try check(controller.actionButtonModelReady && recorder.armed
                              && controller.keyboardSessionActive && recorder.activations == leaseActivations
                              && DictationLiveActivity.lastMessage == "Ready · Mic on",
                              "Contextual Phonon Stop preserves its explicit microphone, Ready runtime and Activity coverage")
                } else {
                    try check(!controller.actionButtonModelReady && controller.preparedModel == nil
                              && controller.preparedExecutionContext == nil && !recorder.armed,
                              "Keep-Off Phonon releases its runtime and microphone after the completed Action reservation")
                }
                retiredSession = id
            } catch {
                DictationLiveActivity.releaseStart()
                start.cancel()
                _ = await start.result
                signal.finish()
                DictationLiveActivity.onStartHeld = previousStartHeld
                if let id = bridge.sessionIdentifier { await DictationActionRuntime.cancel(sessionID: id) }
                throw error
            }
        }
        let preparations = await engine.preparationRequests()
        try check(preparations.count == (retainMicrophone ? 1 : 2)
                  && preparations.allSatisfy { $0.0 == .parakeetPhonon && $0.1 == .backgroundCapable },
                  "Two Phonon Action cycles prepare only the selected background-capable runtime under their retention policy")
        controller.disableKeyboardSession()
        try check(!recorder.armed && !controller.keyboardSessionActive
                  && UIPasteboard.general.writes.isEmpty && controller.history.isEmpty,
                  "Contextual cycle cleanup ends microphone ownership without app clipboard or history writes")
    }
    @MainActor static func main() async throws {
        try await checkContextualPhononCycles(retainMicrophone: true, automatic: true)
        try await checkContextualPhononCycles(retainMicrophone: false)
        try await checkContextualPhononCycles(retainMicrophone: true)
        let engine = RepeatActionEngine()
        await engine.engine.releasePreparation()
        let defaults = UserDefaults(suiteName: "ActionRepeatCheck-\(UUID())")!
        defaults.set(false, forKey: "saveHistory")
        defaults.set(false, forKey: "backgroundDictationEnabled")
        defaults.set(5, forKey: "keyboardIdleMinutes")
        defaults.set(SpeechModel.parakeetRealtimeEOU.rawValue, forKey: "selectedModel")
        let history = FileManager.default.temporaryDirectory.appendingPathComponent("ActionRepeatCheck-\(UUID())/history.json")
        let controller = AppController(engine: engine, defaults: defaults, historyURL: history)
        await controller.refreshInstalledModels()
        let preparationID = UUID()
        guard controller.reserveActionButtonRecording(requestID: preparationID, model: controller.selectedModel),
              await controller.prepareReservedActionButtonRecording(requestID: preparationID) else {
            throw Failure.check("Repeat fixture runtime must be ready before background")
        }
        await controller.cancelActionButtonRecording(requestID: preparationID)
        controller.setForeground(false)
        let bridge = DictationActionBridge(controller: controller)
        let recorder = AudioRecorder.latest!
        var retiredSession: UUID?

        try await checkWarmStart(controller: controller, bridge: bridge, recorder: recorder, engine: engine)

        // Replay the shipped Toggle -> If nonempty -> native Copy contract twice.
        for cycle in 1...2 {
            let armsBeforeStart = recorder.armCalls
            let start = try await ToggleDictationShortcut().perform()
            let id = bridge.sessionIdentifier!
            try check(start.value == "" && recorder.armCalls == armsBeforeStart + 1
                      && controller.phase == .recording && recorder.recording,
                      "Cycle \(cycle) starts new capture and returns no Copy output")
            if let retiredSession {
                try check(id != retiredSession, "Repeated capture gets a new session identity")
                await DictationActionRuntime.cancel(sessionID: retiredSession, reason: .timeout)
                await engine.engine.emitStale()
            }
            try await Task.sleep(for: .milliseconds(120))
            try check(controller.phase == .recording && recorder.recording
                      && controller.partialText.isEmpty && controller.transcript.isEmpty,
                      "Cycle \(cycle) remains recording after Start and ignores retired callbacks")
            recorder.feed(32_000)
            await engine.engine.holdFinalization()
            let stop = Task { try await ToggleDictationShortcut().perform() }
            try await waitFor { await engine.engine.finalizationIsHeld() }
            try check(bridge.sessionIdentifier == id && controller.phase == .transcribing,
                      "Cycle \(cycle) owns asynchronous finalization until Stop completes")
            await engine.engine.releaseFinalization()
            let result = try await stop.value
            try check(result.value == "Captured words." && controller.phase == .idle
                      && !recorder.recording && !bridge.hasActiveSession,
                      "Cycle \(cycle) returns its result and releases capture/session exactly once")
            retiredSession = id
        }

        await engine.setFinalText("")
        _ = try await ToggleDictationShortcut().perform()
        let emptySession = bridge.sessionIdentifier!
        recorder.feed(32_000)
        do {
            _ = try await ToggleDictationShortcut().perform()
            throw Failure.check("Empty recognition must fail before native Copy")
        } catch DictationActionError.failed(let message) {
            try check(message.contains("No speech was recognized"), "Empty recognition exposes its actual no-speech error")
        }
        try check(!bridge.hasActiveSession && controller.phase == .idle && !recorder.recording,
                  "No-speech completion retires its session instead of leaving the next hold on Stop")
        try check(bridge.diagnostic?.action == .stop && bridge.diagnostic?.outcome == .failed
                  && bridge.diagnostic?.resultNonempty == false,
                  "No-speech reports the observed Stop/Failed/no returned text diagnostic")
        await engine.setFinalText("Retry words.")
        let retry = try await ToggleDictationShortcut().perform()
        await DictationActionRuntime.cancel(sessionID: emptySession, reason: .userCancelled)
        await engine.engine.emitStale()
        try await Task.sleep(for: .milliseconds(120))
        try check(retry.value == "" && controller.phase == .recording && recorder.recording,
                  "Hold after no-speech starts new capture and ignores late old cancellation")
        try check(bridge.diagnostic?.action == .start && bridge.diagnostic?.outcome == .completed,
                  "Hold after the failed Stop is classified as Start")
        recorder.feed(32_000)
        let retryResult = try await ToggleDictationShortcut().perform()
        try check(retryResult.value == "Retry words." && !bridge.hasActiveSession,
                  "Retry completion returns only the new session's transcript")

        // Run the same cancellation scope the iOS 27 background wrapper uses.
        // Late completion cleanup must not consume an Island-retained result.
        _ = try await ToggleDictationShortcut().perform()
        let widgetSession = bridge.sessionIdentifier!
        recorder.feed(32_000)
        let widgetScope = DictationActionRuntime.CancellationScope(sessionID: widgetSession)
        let widgetResult = try await widgetScope.perform(.finish(sessionID: widgetSession))
        widgetScope.cancel(reason: .timeout)
        await Task.yield()
        try check(widgetResult == "Retry words." && bridge.sessionIdentifier == widgetSession,
                  "Late platform cancellation cannot discard a successfully retained Widget result")
        let armsBeforeWidgetConsume = recorder.armCalls
        let widgetConsume = try await ToggleDictationShortcut().perform()
        try check(widgetConsume.value == "Retry words." && !bridge.hasActiveSession
                  && recorder.armCalls == armsBeforeWidgetConsume,
                  "Next hold consumes the pending Widget result without a new microphone")
        _ = try await ToggleDictationShortcut().perform()
        let explicitWidgetSession = bridge.sessionIdentifier!
        recorder.feed(32_000)
        _ = try await StopLiveDictationIntent(sessionID: explicitWidgetSession).perform()
        await DictationActionRuntime.cancel(sessionID: explicitWidgetSession)
        try check(!bridge.hasActiveSession,
                  "Explicit session cancellation can still discard a retained Widget result")

        _ = try await ToggleDictationShortcut().perform()
        let cancelledWidgetSession = bridge.sessionIdentifier!
        let cancelledWidgetScope = DictationActionRuntime.CancellationScope(sessionID: cancelledWidgetSession)
        recorder.feed(32_000)
        await engine.engine.holdFinalization()
        let cancelledWidget = Task { try await cancelledWidgetScope.perform(.finish(sessionID: cancelledWidgetSession)) }
        try await waitFor { await engine.engine.finalizationIsHeld() }
        cancelledWidgetScope.cancel(reason: .userCancelled)
        try await waitFor { controller.phase == .idle }
        await engine.engine.releaseFinalization()
        do {
            _ = try await cancelledWidget.value
            throw Failure.check("Platform cancellation before completion must fail")
        } catch is CancellationError { checks += 1 }
        try check(!bridge.hasActiveSession && controller.transcript.isEmpty,
                  "Genuine platform cancellation before completion retires capture and late output")
        try check(bridge.diagnostic?.outcome == .cancelled
                  && bridge.diagnostic?.cancellationReason == .userCancelled,
                  "Genuine platform cancellation preserves its diagnostic after Stop unwinds")

        // A genuine callback can precede completion even when its MainActor
        // cleanup task is still queued. The scope must fail before handing off.
        let actualHandler = DictationActionRuntime.handler!
        let queuedSession = UUID()
        let queuedScope = DictationActionRuntime.CancellationScope(sessionID: queuedSession)
        DictationActionRuntime.handler = { _ in
            queuedScope.cancel(reason: .userCancelled)
            return "Must not be returned."
        }
        do {
            _ = try await queuedScope.perform(.finish(sessionID: queuedSession))
            throw Failure.check("Queued genuine cancellation must fence completed output")
        } catch is CancellationError { checks += 1 }
        DictationActionRuntime.handler = actualHandler

        // Explicit platform cancellation can arrive while model discovery awaits.
        controller.keepModelLoaded = false
        try check(!controller.actionButtonModelReady, "Discovery cancellation begins with a genuinely cold runtime")
        await engine.holdModelDiscovery()
        let requestedSession = UUID()
        let armsBeforeCancelledDiscovery = recorder.armCalls
        let start = Task { try await DictationActionRuntime.perform(.startSession(sessionID: requestedSession)) }
        await engine.waitUntilDiscoveryIsHeld()
        await DictationActionRuntime.cancel(sessionID: requestedSession, reason: .timeout)
        await engine.releaseDiscovery()
        do {
            _ = try await start.value
            throw Failure.check("Cancelled model discovery must not resurrect capture")
        } catch is CancellationError { checks += 1 }
        try check(!bridge.hasActiveSession && controller.phase == .idle && !recorder.recording
                  && recorder.armCalls == armsBeforeCancelledDiscovery,
                  "Discovery cancellation retires the reserved session before audio activation")
        controller.keepModelLoaded = true
        controller.setForeground(true)
        let restoredRequest = UUID()
        guard controller.reserveActionButtonRecording(requestID: restoredRequest, model: controller.selectedModel),
              await controller.prepareReservedActionButtonRecording(requestID: restoredRequest) else {
            throw Failure.check("Selected runtime must be restored after cold discovery cancellation")
        }
        await controller.cancelActionButtonRecording(requestID: restoredRequest)
        controller.setForeground(false)

        for skip in 0...1 {
            await engine.engine.holdNextBackgroundCapability(skip: skip)
            let capabilitySession = UUID()
            let armsBeforeCapability = recorder.armCalls
            let capabilityStart = Task {
                try await DictationActionRuntime.perform(.startSession(sessionID: capabilitySession))
            }
            try await waitFor { await engine.engine.backgroundCapabilityIsHeld() }
            await DictationActionRuntime.cancel(sessionID: capabilitySession, reason: .timeout)
            await engine.engine.releaseBackgroundCapability()
            do {
                _ = try await capabilityStart.value
                throw Failure.check("Cancelled capability discovery must fail")
            } catch is CancellationError { checks += 1 }
            try check(!bridge.hasActiveSession && controller.phase == .idle && !recorder.recording
                      && !controller.actionButtonRecording && recorder.armCalls == armsBeforeCapability,
                      "Cancellation across capability await \(skip) cannot leave an orphan microphone")
            let replacement = try await ToggleDictationShortcut().perform()
            let replacementID = bridge.sessionIdentifier!
            await DictationActionRuntime.cancel(sessionID: capabilitySession, reason: .userCancelled)
            try check(replacement.value == "" && replacementID != capabilitySession
                      && controller.phase == .recording && recorder.recording,
                      "Replacement Action capture survives the cancelled startup's late cleanup")
            await DictationActionRuntime.cancel(sessionID: replacementID)
        }

        await engine.engine.holdNextBackgroundCapability()
        let manualReplacementSession = UUID()
        let manualReplacedStart = Task {
            try await DictationActionRuntime.perform(.startSession(sessionID: manualReplacementSession))
        }
        try await waitFor { await engine.engine.backgroundCapabilityIsHeld() }
        controller.setForeground(true)
        await controller.startRecording()
        let manualRecording = controller.currentRecordingID
        await DictationActionRuntime.cancel(sessionID: manualReplacementSession, reason: .userCancelled)
        await engine.engine.releaseBackgroundCapability()
        do {
            _ = try await manualReplacedStart.value
            throw Failure.check("Cancelled startup replaced by manual capture must fail")
        } catch is CancellationError { checks += 1 }
        await DictationActionRuntime.cancel(sessionID: manualReplacementSession, reason: .timeout)
        try check(manualRecording != nil && controller.currentRecordingID == manualRecording
                  && controller.phase == .recording && recorder.recording && !bridge.hasActiveSession,
                  "Cancelled Action startup and its late cancellation preserve a newer manual capture")
        await controller.cancelRecording()
        controller.setForeground(false)

        // Activity startup can suspend while a prior platform end finishes.
        // Cancellation retires it; the action gate excludes a concurrent start,
        // and a replacement after unwind must acquire a fresh recording contract.
        DictationLiveActivity.holdNextStart = true
        let heldActivitySession = UUID()
        let heldActivityStart = Task {
            try await DictationActionRuntime.perform(.startSession(sessionID: heldActivitySession))
        }
        try await waitFor { DictationLiveActivity.heldStart != nil }
        await DictationActionRuntime.cancel(sessionID: heldActivitySession)
        do {
            _ = try await DictationActionRuntime.perform(.startSession(sessionID: UUID()))
            throw Failure.check("Pending Activity start must retain the action gate until unwind")
        } catch DictationActionError.busy { checks += 1 }
        DictationLiveActivity.releaseStart()
        do {
            _ = try await heldActivityStart.value
            throw Failure.check("Cancelled Activity startup must not resume capture")
        } catch is CancellationError { checks += 1 }
        let replacementAfterHeldStart = try await ToggleDictationShortcut().perform()
        let replacementAfterHeldID = bridge.sessionIdentifier!
        try check(replacementAfterHeldStart.value == ""
                  && controller.phase == .recording && controller.actionButtonRecording
                  && recorder.recording && replacementAfterHeldID != heldActivitySession,
                  "Replacement after cancelled Activity startup owns its fresh recording contract")
        await DictationActionRuntime.cancel(sessionID: heldActivitySession)
        try check(controller.phase == .recording && recorder.recording,
                  "Old Activity startup cleanup cannot cancel the replacement")
        await DictationActionRuntime.cancel(sessionID: replacementAfterHeldID)

        // Change the preference during discovery. This Action must retain its
        // original model for capture, initial Island name and preview policy.
        controller.selectedModel = .parakeetRealtimeEOU
        controller.keepModelLoaded = false
        controller.setForeground(true)
        try check(!controller.actionButtonModelReady, "Model-freeze discovery begins with a genuinely cold runtime")
        let preparationCountBeforeFreeze = await engine.engine.preparations().count
        await engine.holdModelDiscovery()
        let frozenSession = UUID()
        let frozenStart = Task {
            try await DictationActionRuntime.perform(.startSession(sessionID: frozenSession))
        }
        await engine.waitUntilDiscoveryIsHeld()
        controller.selectedModel = .parakeetPhonon
        await engine.releaseDiscovery()
        _ = try await frozenStart.value
        try check(controller.phase == .recording && controller.actionButtonRecording
                  && controller.recordingModel == .parakeetRealtimeEOU
                  && controller.selectedModel == .parakeetPhonon
                  && DictationLiveActivity.lastModelName == SpeechModel.parakeetRealtimeEOU.name,
                  "Preference changes during discovery cannot change the frozen capture or initial Island name")
        recorder.feed(32_000)
        let frozenResult = try await ToggleDictationShortcut().perform()
        let frozenPreparations = await engine.engine.preparations()
        try check(frozenResult.value == "Retry words."
                  && frozenPreparations.dropFirst(preparationCountBeforeFreeze).allSatisfy { $0 == .parakeetRealtimeEOU },
                  "Discovery never prewarms the changed preference or switches final transcription")
        controller.selectedModel = .parakeetRealtimeEOU
        controller.keepModelLoaded = true

        // Startup failures must leave Toggle on Start, with no microphone or
        // result to copy. Exercise retry through the actual shortcut each time.
        controller.setForeground(true)
        let failureCheckPreparationID = UUID()
        try check(controller.reserveActionButtonRecording(requestID: failureCheckPreparationID, model: controller.selectedModel),
                  "Failed-start checks reserve the restored selected model")
        let failureChecksReady = await controller.prepareReservedActionButtonRecording(requestID: failureCheckPreparationID)
        try check(failureChecksReady, "Failed-start checks begin with the selected runtime Ready")
        await controller.cancelActionButtonRecording(requestID: failureCheckPreparationID)
        controller.setForeground(false)
        let preservedTranscript = controller.transcript
        for failure in ["authorization", "activity", "microphone"] {
            let armsBeforeFailure = recorder.armCalls
            let activitiesBeforeFailure = DictationLiveActivity.starts
            switch failure {
            case "authorization": DictationLiveActivity.authorized = false
            case "activity": DictationLiveActivity.requestSucceeds = false
            default: recorder.microphonePermissionGranted = false
            }
            do {
                _ = try await ToggleDictationShortcut().perform()
                throw Failure.check("Rejected \(failure) startup must fail")
            } catch DictationActionError.failed { checks += 1 }
            try check(!bridge.hasActiveSession && controller.phase == .idle
                      && !controller.actionButtonRecording && !recorder.recording && !recorder.armed,
                      "Rejected \(failure) startup leaves no capture or session for Stop")
            try check(recorder.armCalls == armsBeforeFailure
                      && controller.transcript == preservedTranscript,
                      "Rejected \(failure) startup neither activates audio nor replaces completed text")
            if failure == "authorization" {
                try check(DictationLiveActivity.starts == activitiesBeforeFailure,
                          "Disabled Activity authorization fails before requesting a recording Activity")
            }
            DictationLiveActivity.authorized = true
            DictationLiveActivity.requestSucceeds = true
            recorder.microphonePermissionGranted = true
            let retry = try await ToggleDictationShortcut().perform()
            let retryID = bridge.sessionIdentifier!
            try check(retry.value == "" && controller.phase == .recording && recorder.recording
                      && bridge.diagnostic?.action == .start,
                      "First hold after rejected \(failure) startup starts and returns without Copy output")
            await DictationActionRuntime.cancel(sessionID: retryID)
            // Explicit cancellation discards its capture, so retain an existing
            // editable transcript for the next failure's preservation check.
            controller.transcript = preservedTranscript
        }

        // Rejected bridge acquisition cannot retire a controller reservation
        // owned by another request, even if the failed shortcut is cancelled.
        let reservedID = UUID()
        try check(controller.reserveActionButtonRecording(requestID: reservedID, model: controller.selectedModel),
                  "Independent controller request acquires the idle reservation")
        let rejectedID = UUID()
        do {
            _ = try await DictationActionRuntime.perform(.startSession(sessionID: rejectedID))
            throw Failure.check("Bridge acquisition must reject another request's reservation")
        } catch DictationActionError.busy { checks += 1 }
        await DictationActionRuntime.cancel(sessionID: rejectedID, reason: .timeout)
        try check(!bridge.hasActiveSession && !recorder.recording,
                  "Rejected reservation never publishes a bridge session or microphone")
        await controller.startReservedActionButtonRecording(requestID: reservedID)
        try check(controller.phase == .recording && controller.actionButtonRecording && recorder.recording,
                  "Rejected shortcut and its cancellation preserve the actual reservation owner")
        await controller.cancelActionButtonRecording(requestID: reservedID)
        let reservationRetry = try await ToggleDictationShortcut().perform()
        let reservationRetryID = bridge.sessionIdentifier!
        try check(reservationRetry.value == "" && controller.phase == .recording && recorder.recording,
                  "Hold after the independent owner retires starts a fresh bridge capture")
        await DictationActionRuntime.cancel(sessionID: reservationRetryID)

        // A cold background rejection is intentional: readiness precedes the
        // microphone. Loading the same selection must make the next hold Start.
        controller.keepModelLoaded = false
        try await waitFor { controller.preparedModel == nil }
        let armsBeforeColdFailure = recorder.armCalls
        let activitiesBeforeColdFailure = DictationLiveActivity.starts
        do {
            _ = try await ToggleDictationShortcut().perform()
            throw Failure.check("Cold background startup must report missing readiness")
        } catch DictationActionError.failed(let message) {
            try check(message.contains("Ready"), "Cold background startup reports its readiness requirement")
        }
        try check(!bridge.hasActiveSession && controller.phase == .idle
                  && !controller.actionButtonRecording && !recorder.recording && !recorder.armed
                  && recorder.armCalls == armsBeforeColdFailure
                  && DictationLiveActivity.starts == activitiesBeforeColdFailure,
                  "Readiness rejection retires ownership before Activity or microphone activation")
        controller.keepModelLoaded = true
        controller.setForeground(true)
        let readyRequest = UUID()
        try check(controller.reserveActionButtonRecording(requestID: readyRequest, model: controller.selectedModel),
                  "Readiness rejection releases its reservation for explicit preparation")
        let restoredReady = await controller.prepareReservedActionButtonRecording(requestID: readyRequest)
        try check(restoredReady,
                  "Selected runtime can be prepared after rejected cold startup")
        await controller.cancelActionButtonRecording(requestID: readyRequest)
        controller.setForeground(false)
        let readyRetry = try await ToggleDictationShortcut().perform()
        try check(readyRetry.value == "" && controller.phase == .recording && recorder.recording
                  && bridge.diagnostic?.action == .start,
                  "First hold after readiness recovery starts and returns to the speaker")
        recorder.feed(32_000)
        let readyStop = try await ToggleDictationShortcut().perform()
        try check(readyStop.value == "Retry words." && !bridge.hasActiveSession
                  && controller.phase == .idle && !recorder.recording && !recorder.armed,
                  "Next hold after readiness recovery stops and returns only its new transcript")
        controller.setForeground(true)
        await controller.enableKeyboardSession()
        controller.setForeground(false)
        let leaseActivations = recorder.activations
        let finishesBeforeLease = DictationLiveActivity.finishes
        _ = try await ToggleDictationShortcut().perform()
        let leasedRecord = bridge.sessionIdentifier!
        recorder.feed(32_000)
        let leasedResult = try await ToggleDictationShortcut().perform()
        try check(leasedResult.value == "Retry words." && !bridge.hasActiveSession
                  && controller.keyboardSessionActive && recorder.armed && !recorder.recording
                  && DictationLiveActivity.finishes == finishesBeforeLease
                  && DictationLiveActivity.lastMessage == "Ready · Mic on",
                  "Action result retires its utterance while retaining Activity and explicit microphone lease")
        _ = try await ToggleDictationShortcut().perform()
        let nextLeasedRecord = bridge.sessionIdentifier!
        do {
            _ = try await StopLiveDictationIntent(sessionID: leasedRecord).perform()
            throw Failure.check("Old lease Activity must not stop its replacement recording")
        } catch DictationActionError.noSession { checks += 1 }
        try check(nextLeasedRecord != leasedRecord && bridge.sessionIdentifier == nextLeasedRecord
                  && recorder.recording && recorder.activations == leaseActivations,
                  "Lease reuses one armed microphone and stale old Stop preserves new capture")
        recorder.feed(32_000)
        _ = try await ToggleDictationShortcut().perform()

        await engine.setFinalText("")
        _ = try await ToggleDictationShortcut().perform()
        recorder.feed(32_000)
        let finishesBeforeEmptyLease = DictationLiveActivity.finishes
        do {
            _ = try await ToggleDictationShortcut().perform()
            throw Failure.check("Empty leased recording must still fail")
        } catch DictationActionError.failed { checks += 1 }
        try check(!bridge.hasActiveSession && recorder.armed && !recorder.recording
                  && DictationLiveActivity.finishes == finishesBeforeEmptyLease
                  && DictationLiveActivity.lastMessage?.contains("Mic on") == true,
                  "No-speech failure preserves a truthful Activity while its explicit microphone remains armed")
        await engine.setFinalText("Retry words.")
        _ = try await ToggleDictationShortcut().perform()
        await DictationActionRuntime.cancel(sessionID: bridge.sessionIdentifier!)
        try check(!bridge.hasActiveSession && recorder.armed && !recorder.recording
                  && DictationLiveActivity.lastMessage == "Cancelled · Mic on",
                  "Explicit utterance cancellation preserves Activity coverage for the separate microphone lease")

        _ = try await ToggleDictationShortcut().perform()
        let leasedWidgetSession = bridge.sessionIdentifier!
        recorder.feed(32_000)
        _ = try await StopLiveDictationIntent(sessionID: leasedWidgetSession).perform()
        let finishesBeforeEnd = DictationLiveActivity.finishes
        controller.disableKeyboardSession()
        try check(!recorder.armed && !controller.keyboardSessionActive
                  && DictationLiveActivity.finishes == finishesBeforeEnd + 1
                  && DictationLiveActivity.lastMessage == nil,
                  "Explicit End retires only the completed Activity covering its microphone lease")
        let activationsBeforePendingCopy = recorder.activations
        let leasePendingCopy = try await ToggleDictationShortcut().perform()
        try check(leasePendingCopy.value == "Retry words." && !bridge.hasActiveSession
                  && recorder.activations == activationsBeforePendingCopy && !recorder.armed,
                  "Ending the lease preserves Widget's owned result for the next hold without phantom capture")
        for rejectedActivity in ["authorization", "request"] {
            controller.setForeground(true)
            await controller.enableKeyboardSession()
            controller.setForeground(false)
            DictationLiveActivity.authorized = rejectedActivity != "authorization"
            DictationLiveActivity.requestSucceeds = rejectedActivity != "request"
            do {
                _ = try await ToggleDictationShortcut().perform()
                throw Failure.check("Missing Activity must reject the leased Start")
            } catch DictationActionError.failed { checks += 1 }
            try check(!bridge.hasActiveSession && !recorder.armed && !recorder.recording
                      && !controller.keyboardSessionActive,
                      "Failed first \(rejectedActivity) request ends an idle microphone with no covering Activity")
            DictationLiveActivity.authorized = true
            DictationLiveActivity.requestSucceeds = true
        }
        try check(UIPasteboard.general.writes.isEmpty && controller.history.isEmpty,
                  "Repeated/empty/cancelled sessions use no app clipboard access or history writes")
        print("PASS: \(checks) repeated Action Button session checks")
    }
}
