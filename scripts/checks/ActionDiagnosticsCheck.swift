import Foundation
import LocalScribeCore

actor ProgressEngine: StreamingLocalTranscriptionEngine, BackgroundInferenceReportingEngine {
    static let privateText = "Private transcription fixture 65A91539."
    var preparation: CheckedContinuation<Void, Never>?
    var finalization: CheckedContinuation<Void, Never>?
    var delayPreparation = true
    var delayFinalization = true
    func isInstalled(_ model: SpeechModel) async -> Bool { true }
    func supportsBackgroundInference(for model: SpeechModel) async -> Bool { true }
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func prepare(_ model: SpeechModel) async throws {
        if delayPreparation { await withCheckedContinuation { preparation = $0 } }
        try Task.checkCancellation()
    }
    func beginStreaming(onUpdate: @escaping @Sendable (SpeechTranscriptUpdate) -> Void) async throws {}
    func appendStreaming(samples: [Float]) async throws { try Task.checkCancellation() }
    func finishStreaming() async throws -> String {
        if delayFinalization { await withCheckedContinuation { finalization = $0 } }
        try Task.checkCancellation()
        return Self.privateText
    }
    func cancelStreaming() async {}
    func transcribe(samples: [Float]) async throws -> String { Self.privateText }
    func unload() async {}
    func releasePreparation() { delayPreparation = false; preparation?.resume(); preparation = nil }
    func releaseFinalization() { delayFinalization = false; finalization?.resume(); finalization = nil }
    func preparing() -> Bool { preparation != nil }
    func finalizing() -> Bool { finalization != nil }
    func holdFinalization() { delayFinalization = true }
}

@main struct ActionDiagnosticsCheck {
    enum Failure: Error { case check(String) }
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.check(message) }
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
        let engine = ProgressEngine()
        let defaults = UserDefaults(suiteName: "ActionDiagnosticsCheck-\(UUID())")!
        defaults.set(false, forKey: "saveHistory")
        defaults.set(SpeechModel.parakeetRealtimeEOU.rawValue, forKey: "selectedModel")
        let history = FileManager.default.temporaryDirectory.appendingPathComponent("ActionDiagnostics-\(UUID())/history.json")
        let controller = AppController(engine: engine, defaults: defaults, historyURL: history)
        controller.setForeground(false)
        await controller.refreshInstalledModels(prewarm: false)
        let bridge = DictationActionBridge(controller: controller)
        let recorder = AudioRecorder.latest!
        let activitiesBeforeColdStart = DictationLiveActivity.starts
        let armsBeforeColdStart = recorder.armCalls
        do {
            _ = try await StartDictationShortcut().perform()
            throw Failure.check("Cold background Action must reject unavailable readiness")
        } catch DictationActionError.failed(let message) {
            try check(message.localizedCaseInsensitiveContains("Ready"),
                      "Cold background Action explains how to make the selected model Ready")
            try check(bridge.diagnostic?.action == .start && bridge.diagnostic?.outcome == .failed
                      && bridge.diagnostic?.failureMessage == message,
                      "Failed first hold retains its actual operational reason in Last run")
        }
        try check(DictationLiveActivity.starts == activitiesBeforeColdStart
                  && recorder.armCalls == armsBeforeColdStart && !recorder.recording && !bridge.hasActiveSession,
                  "Cold background rejection creates no recording Activity and never activates audio")
        controller.setForeground(true)
        let foregroundStart = Task { try await StartDictationShortcut().perform() }
        try await waitFor { await engine.preparing() }
        try check(controller.phase == .preparing && !recorder.recording
                  && recorder.armCalls == armsBeforeColdStart && DictationLiveActivity.starts == activitiesBeforeColdStart,
                  "Foreground preparation finishes before microphone activation or recording Activity")
        try check(bridge.diagnostic?.outcome == .running && bridge.diagnostic?.failureMessage == nil,
                  "Retry clears the previous failure while the actual start is running")
        await engine.releasePreparation()
        let start = try await foregroundStart.value
        controller.setForeground(false)
        try check(start.value == "" && bridge.diagnostic?.action == .start
                  && bridge.diagnostic?.outcome == .completed && bridge.diagnostic?.resultNonempty == false,
                  "Successful Start reports no result and still returns empty output")
        try check(bridge.diagnostic?.failureMessage == nil,
                  "Successful retry leaves no stale readiness failure in Last run")
        recorder.feed(32_000)
        let session = bridge.sessionIdentifier!
        let progress = Progress(totalUnitCount: 1)
        let fallbackStartsBefore = UIApplication.shared.backgroundTaskStarts
        let stop = Task { try await DictationActionRuntime.perform(.stop(sessionID: session, progress: progress)) }
        try await waitFor { await engine.finalizing() }
        try check(UIApplication.shared.backgroundTaskStarts == fallbackStartsBefore + 1,
                  "Application fallback still acquires finite UIKit completion time")
        let retiredFallbackExpiration = UIApplication.shared.backgroundTaskExpirations[UIApplication.shared.backgroundTaskStarts]!
        try await waitFor { progress.localizedDescription == "Finalizing transcript" }
        let actualCompleted = progress.completedUnitCount
        let finalizingDescription = progress.localizedAdditionalDescription
        try await Task.sleep(for: .milliseconds(1_100))
        try check(actualCompleted > 0 && actualCompleted < progress.totalUnitCount
                  && progress.completedUnitCount == actualCompleted
                  && progress.localizedAdditionalDescription != finalizingDescription,
                  "Slow finalization retains real checkpoints and reports continued waiting")
        await engine.releaseFinalization()
        let result = try await stop.value
        try check(result == ProgressEngine.privateText && progress.completedUnitCount == progress.totalUnitCount,
                  "Completion returns the exact owned result and completes genuine work units")
        try check(bridge.diagnostic?.action == .stop && bridge.diagnostic?.outcome == .completed
                  && bridge.diagnostic?.resultNonempty == true && bridge.diagnostic!.durationSeconds >= 1,
                  "Stop diagnostics distinguish a completed nonempty result and real elapsed time")
        try check(!String(reflecting: bridge.diagnostic!).contains(ProgressEngine.privateText)
                  && !String(reflecting: bridge.diagnostic!).contains(session.uuidString),
                  "Diagnostics exclude captured text and session identity")
        let finishedDescription = progress.localizedAdditionalDescription
        try await Task.sleep(for: .milliseconds(1_100))
        try check(progress.localizedAdditionalDescription == finishedDescription,
                  "Completion retires the liveness reporter")
        try check(UIPasteboard.general.writes.isEmpty, "Diagnostics never access the clipboard")

        _ = try await StartDictationShortcut().perform()
        recorder.feed(32_000)
        let widgetSession = bridge.sessionIdentifier!
        let widget = try await StopLiveDictationIntent(sessionID: widgetSession).perform()
        try check(widget.value == ProgressEngine.privateText && bridge.diagnostic?.action == .widgetFinish
                  && bridge.diagnostic?.outcome == .completed && bridge.hasActiveSession,
                  "Widget diagnostic preserves its exact pending result")
        controller.transcript = "An unrelated edit."
        let consume = try await ToggleDictationShortcut().perform()
        try check(consume.value == ProgressEngine.privateText && bridge.diagnostic?.action == .stop
                  && !bridge.hasActiveSession,
                  "Next Toggle consumes the widget snapshot without starting new capture")

        // The platform operation explicitly owns completion time. Normalize a
        // nil session through the runtime without losing that execution policy.
        await engine.holdFinalization()
        _ = try await StartDictationShortcut().perform()
        recorder.feed(32_000)
        let managedStartsBefore = UIApplication.shared.backgroundTaskStarts
        let managedProgress = Progress(totalUnitCount: 1)
        let managedStop = Task {
            try await DictationActionRuntime.perform(.stop(
                sessionID: nil, progress: managedProgress, completionExecution: .longRunningIntent))
        }
        try await waitFor { await engine.finalizing() }
        try check(UIApplication.shared.backgroundTaskStarts == managedStartsBefore,
                  "Platform-managed Stop does not acquire a redundant finite UIKit lease")
        retiredFallbackExpiration()
        await Task.yield()
        try check(controller.errorMessage == nil && controller.phase == .transcribing,
                  "A retired fallback expiry cannot report a timeout in the later managed completion")
        await engine.releaseFinalization()
        let managedResult = try await managedStop.value
        try check(managedResult == ProgressEngine.privateText && controller.errorMessage == nil,
                  "Managed completion returns the full transcript without a finite-lease timeout")

        _ = try await StartDictationShortcut().perform()
        recorder.feed(32_000)
        let managedWidgetSession = bridge.sessionIdentifier!
        let widgetStartsBefore = UIApplication.shared.backgroundTaskStarts
        let managedWidget = try await DictationActionRuntime.perform(.finish(
            sessionID: managedWidgetSession, completionExecution: .longRunningIntent))
        try check(managedWidget == ProgressEngine.privateText && bridge.hasActiveSession
                  && UIApplication.shared.backgroundTaskStarts == widgetStartsBefore,
                  "Platform-managed Widget finish retains the result without a UIKit lease")
        _ = try await ToggleDictationShortcut().perform()

        await engine.holdFinalization()
        _ = try await StartDictationShortcut().perform()
        recorder.feed(32_000)
        let interruptedSession = bridge.sessionIdentifier!
        recorder.onInterruption?()
        try await waitFor { await engine.finalizing() }
        let interruptionLeaseStarts = UIApplication.shared.backgroundTaskStarts
        let interruptionLeaseEnds = UIApplication.shared.backgroundTaskEnds
        let interruptedFiniteExpiration = UIApplication.shared.backgroundTaskExpirations[interruptionLeaseStarts]!
        let interruptionProgress = Progress(totalUnitCount: 1)
        let interruptedStop = Task {
            try await DictationActionRuntime.perform(.stop(
                sessionID: interruptedSession, progress: interruptionProgress, completionExecution: .longRunningIntent))
        }
        try await waitFor { interruptionProgress.localizedDescription == "Finalizing transcript" }
        try check(UIApplication.shared.backgroundTaskStarts == interruptionLeaseStarts
                  && UIApplication.shared.backgroundTaskEnds == interruptionLeaseEnds + 1,
                  "Managed intent joining interruption completion retires its existing finite lease")
        interruptedFiniteExpiration()
        await Task.yield()
        try check(controller.errorMessage == nil && controller.phase == .transcribing,
                  "The adopted completion ignores its retired finite expiry while remaining cancellable")
        let interruptionDescription = interruptionProgress.localizedAdditionalDescription
        try await Task.sleep(for: .milliseconds(1_100))
        try check(interruptionProgress.completedUnitCount == 0
                  && interruptionProgress.localizedAdditionalDescription != interruptionDescription,
                  "Stop joining interruption finalization reports waiting without fictional work")
        await engine.releaseFinalization()
        let interruptionResult = try await interruptedStop.value
        try check(interruptionResult == ProgressEngine.privateText && !bridge.hasActiveSession,
                  "Joining an interrupted pipeline still returns the same owned snapshot")

        await engine.holdFinalization()
        _ = try await StartDictationShortcut().perform()
        recorder.feed(32_000)
        let cancelSession = bridge.sessionIdentifier!
        let cancelledProgress = Progress(totalUnitCount: 1)
        let cancelledStop = Task { try await DictationActionRuntime.perform(.stop(
            sessionID: cancelSession, progress: cancelledProgress, completionExecution: .longRunningIntent)) }
        try await waitFor { await engine.finalizing() }
        cancelledStop.cancel()
        try await waitFor { controller.phase == .idle }
        await DictationActionRuntime.cancel(sessionID: cancelSession, reason: .timeout)
        await engine.releaseFinalization()
        do {
            _ = try await cancelledStop.value
            throw Failure.check("Cancellation must fail")
        } catch is CancellationError { checks += 1 }
        try check(bridge.diagnostic?.outcome == .cancelled && bridge.diagnostic?.cancellationReason == .timeout
                  && bridge.diagnostic?.resultNonempty == false && bridge.diagnostic?.failureMessage == nil
                  && !recorder.recording && !bridge.hasActiveSession,
                  "Timeout diagnostics survive task cleanup without committing a late result")
        let cancelledDescription = cancelledProgress.localizedAdditionalDescription
        try await Task.sleep(for: .milliseconds(1_100))
        try check(cancelledProgress.localizedAdditionalDescription == cancelledDescription,
                  "Cancellation retires the liveness reporter")
        _ = try await StartDictationShortcut().perform()
        let currentDiagnostic = bridge.diagnostic
        await DictationActionRuntime.cancel(sessionID: cancelSession, reason: .userCancelled)
        try check(controller.phase == .recording && bridge.diagnostic == currentDiagnostic,
                  "Stale cancellation cannot overwrite later diagnostics or stop its microphone")
        await controller.cancelRecording()
        print("PASS: \(checks) Action Button diagnostics/progress checks")
    }
}
