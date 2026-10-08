import Foundation
import LocalScribeCore

// Suspension points and late callbacks exercise the real intent/runtime/bridge/
// controller pipeline without activating a microphone or loading a speech model.
actor RepeatActionEngine: StreamingLocalTranscriptionEngine, BackgroundInferenceReportingEngine {
    let engine = LifecycleEngine()
    var discovery: CheckedContinuation<Void, Never>?
    var holdDiscovery = false
    var finalText = "Captured words."
    func holdModelDiscovery() { holdDiscovery = true }
    func discovering() -> Bool { discovery != nil }
    func releaseDiscovery() { holdDiscovery = false; discovery?.resume(); discovery = nil }
    func setFinalText(_ text: String) { finalText = text }
    func isInstalled(_ model: SpeechModel) async -> Bool {
        if holdDiscovery { await withCheckedContinuation { discovery = $0 } }
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
    @MainActor static func main() async throws {
        let engine = RepeatActionEngine()
        await engine.engine.releasePreparation()
        let defaults = UserDefaults(suiteName: "ActionRepeatCheck-\(UUID())")!
        defaults.set(false, forKey: "saveHistory")
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
        await engine.holdModelDiscovery()
        let requestedSession = UUID()
        let armsBeforeCancelledDiscovery = recorder.armCalls
        let start = Task { try await DictationActionRuntime.perform(.startSession(sessionID: requestedSession)) }
        try await waitFor { await engine.discovering() }
        await DictationActionRuntime.cancel(sessionID: requestedSession, reason: .timeout)
        await engine.releaseDiscovery()
        do {
            _ = try await start.value
            throw Failure.check("Cancelled model discovery must not resurrect capture")
        } catch is CancellationError { checks += 1 }
        try check(!bridge.hasActiveSession && controller.phase == .idle && !recorder.recording
                  && recorder.armCalls == armsBeforeCancelledDiscovery,
                  "Discovery cancellation retires the reserved session before audio activation")

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
        let preparationCountBeforeFreeze = await engine.engine.preparations().count
        await engine.holdModelDiscovery()
        let frozenSession = UUID()
        let frozenStart = Task {
            try await DictationActionRuntime.perform(.startSession(sessionID: frozenSession))
        }
        try await waitFor { await engine.discovering() }
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
        try check(UIPasteboard.general.writes.isEmpty && controller.history.isEmpty,
                  "Repeated/empty/cancelled sessions use no app clipboard access or history writes")
        print("PASS: \(checks) repeated Action Button session checks")
    }
}
