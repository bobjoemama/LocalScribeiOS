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
        await controller.refreshInstalledModels()
        controller.setForeground(false)
        let bridge = DictationActionBridge(controller: controller)
        let recorder = AudioRecorder.latest!
        let start = try await StartDictationShortcut().perform()
        try check(start.value == "" && bridge.diagnostic?.action == .start
                  && bridge.diagnostic?.outcome == .completed && bridge.diagnostic?.resultNonempty == false,
                  "Successful Start reports no result and still returns empty output")
        recorder.feed(32_000)
        try await waitFor { await engine.preparing() }
        let session = bridge.sessionIdentifier!
        let progress = Progress(totalUnitCount: 1)
        let stop = Task { try await DictationActionRuntime.perform(.stop(sessionID: session, progress: progress)) }
        try await waitFor { controller.phase == .transcribing && progress.localizedDescription == "Preparing recognition" }
        let preparingDescription = progress.localizedAdditionalDescription
        try await Task.sleep(for: .milliseconds(1_100))
        try check(progress.completedUnitCount == 0 && progress.localizedAdditionalDescription != preparingDescription,
                  "Cold preparation reports elapsed waiting without inventing completed work")
        await engine.releasePreparation()
        try await waitFor { await engine.finalizing() }
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
                  && bridge.diagnostic?.resultNonempty == true && bridge.diagnostic!.durationSeconds >= 2,
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

        await engine.holdFinalization()
        _ = try await StartDictationShortcut().perform()
        recorder.feed(32_000)
        let interruptedSession = bridge.sessionIdentifier!
        recorder.onInterruption?()
        try await waitFor { await engine.finalizing() }
        let interruptionProgress = Progress(totalUnitCount: 1)
        let interruptedStop = Task {
            try await DictationActionRuntime.perform(.stop(sessionID: interruptedSession, progress: interruptionProgress))
        }
        try await waitFor { interruptionProgress.localizedDescription == "Finalizing transcript" }
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
        let cancelledStop = Task { try await DictationActionRuntime.perform(.stop(sessionID: cancelSession, progress: cancelledProgress)) }
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
                  && bridge.diagnostic?.resultNonempty == false && !recorder.recording && !bridge.hasActiveSession,
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
