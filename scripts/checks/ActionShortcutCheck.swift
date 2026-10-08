import AppIntents
import Foundation
import LocalScribeCore

protocol LiveActivityIntent: AppIntent {}
@MainActor enum AppContext { static let shared = 0 }

@MainActor final class UIPasteboard {
  enum OptionsKey: Hashable { case localOnly }
  static let general = UIPasteboard()
  private(set) var writes = [[String: Any]]()
  func setItems(_ items: [[String: Any]], options: [OptionsKey: Any]) {
    writes.append(contentsOf: items)
  }
}
struct DictationActivityAttributes {
  enum Phase: Equatable { case recording, transcribing, ready, cancelled, failed }
}
@MainActor final class DictationLiveActivity {
  enum PreviewCapability { case streamingText, statusOnly }
  private var previewCapability = PreviewCapability.statusOnly
  static var lastModelName = ""
  static var holdNextStart = false
  static var heldStart: CheckedContinuation<Void, Never>?
  private var startingSessionID: UUID?
  static func releaseStart() { heldStart?.resume(); heldStart = nil }
  static var authorized = true
  static var requestSucceeds = true
  static var starts = 0
  static var finishes = 0
  static var requiredStarts = 0
  static var lastPhase = DictationActivityAttributes.Phase.recording
  static var lastText = ""
  static var lastMessage: String?
  static var regressedToRecording = false
  var canStartRecordingActivity: Bool { Self.authorized }
  func clearOrphanedActivities() {}
  @discardableResult func start(
    sessionID: UUID, modelName: String, startedAt: Date,
    previewCapability: PreviewCapability, required: Bool = false
  ) async -> Bool {
    startingSessionID = sessionID
    defer { if startingSessionID == sessionID { startingSessionID = nil } }
    if Self.holdNextStart {
      Self.holdNextStart = false
      await withCheckedContinuation { Self.heldStart = $0 }
    }
    guard startingSessionID == sessionID, !Task.isCancelled else { return false }
    self.previewCapability = previewCapability
    Self.lastModelName = modelName
    Self.starts += 1
    Self.lastPhase = .recording
    Self.lastText = ""
    Self.regressedToRecording = false
    if required { Self.requiredStarts += 1 }
    return Self.authorized && Self.requestSucceeds
  }
  func update(
    phase: DictationActivityAttributes.Phase, elapsed: TimeInterval, message: String? = nil,
    transcript: String? = nil
  ) {
    if Self.lastPhase == .transcribing && phase == .recording { Self.regressedToRecording = true }
    Self.lastPhase = phase
    if previewCapability == .streamingText, let transcript { Self.lastText = transcript }
  }
  func finish(transcript: String, elapsed: TimeInterval) {
    Self.finishes += 1
    Self.lastPhase = .ready
    Self.lastText = previewCapability == .streamingText ? transcript : ""
  }
  func fail(message: String?, elapsed: TimeInterval) {
    Self.lastPhase = .failed
    Self.lastMessage = message
    Self.lastText = ""
  }
  func cancel(elapsed: TimeInterval) {
    startingSessionID = nil
    Self.lastPhase = .cancelled
    Self.lastText = ""
  }
}

@main struct ActionShortcutCheck {
  enum Failure: Error { case check(String) }
  @MainActor static var checks = 0
  @MainActor static var startedHandlerContinuation: CheckedContinuation<Void, Never>?
  @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure.check(message) }
    checks += 1
  }
  @MainActor static func fixture(engine: LifecycleEngine = LifecycleEngine()) async -> AppController
  {
    await engine.releasePreparation()
    let defaults = UserDefaults(suiteName: "ShortcutCheck-\(UUID())")!
    defaults.set(false, forKey: "saveHistory")
    defaults.set(SpeechModel.parakeetRealtimeEOU.rawValue, forKey: "selectedModel")
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ShortcutCheck-\(UUID())/history.json")
    let controller = AppController(engine: engine, defaults: defaults, historyURL: path)
    await controller.refreshInstalledModels()
    return controller
  }
  @MainActor static func main() async throws {
    // Compile and execute the actual intent perform, runtime, bridge and controller.
    // Only UIKit/audio/ActivityKit platform boundaries are fixtures.
    DictationActionRuntime.handler = nil
    let coldIntent = Task { try await ToggleDictationShortcut().perform() }
    try await Task.sleep(for: .milliseconds(150))
    let engine = LifecycleEngine()
    let controller = await fixture(engine: engine)
    controller.selectedModel = .parakeetRealtimeEOU
    controller.setForeground(false)
    UIApplication.shared.applicationState = .background
    let recorder = AudioRecorder.latest!
    var owner: DictationActionBridge? = DictationActionBridge(controller: controller)
    weak var retainedBridge = owner
    let startResult = try await coldIntent.value
    try check(startResult.value == "", "Start exposes empty output without touching clipboard")
    try check(
      controller.phase == .recording && recorder.recording,
      "Cold registration starts capture before successful intent result")
    try check(
      controller.selectedModel == .parakeetRealtimeEOU
        && controller.recordingModel == controller.selectedModel,
      "Background shortcut uses the same selected model as Dictate")
    try check(
      !StartDictationShortcut.openAppWhenRun && !ToggleDictationShortcut.openAppWhenRun
        && !StopDictationShortcut.openAppWhenRun && !StopLiveDictationIntent.openAppWhenRun,
      "All recording intents keep the caller foreground")
    try check(UIPasteboard.general.writes.isEmpty, "Start never overwrites clipboard")
    try check(
      controller.actionButtonRecording, "Intent return retains Action Button session ownership")
    try check(
      recorder.lastMixWithOtherAudio, "Action Button activation uses mixable microphone session")
    try check(retainedBridge != nil, "App owner retains bridge after intent returns")
    try await Task.sleep(for: .milliseconds(200))
    try check(controller.phase == .recording, "First toggle stays recording after perform returns")
    try check(
      DictationLiveActivity.requiredStarts == 1, "Recording requests mandatory Live Activity")
    controller.setForeground(false)
    try check(
      recorder.recording && controller.phase == .recording,
      "Returning to caller does not stop app-owned microphone")
    recorder.feed(32_000)
    let stopResult = try await ToggleDictationShortcut().perform()
    try check(
      stopResult.value == "Captured words.",
      "Stop exposes the final transcript for a Shortcuts Copy action")
    try check(controller.phase == .idle && !recorder.recording, "Next toggle stops same session")
    try check(
      UIPasteboard.general.writes.isEmpty,
      "Background Stop delegates clipboard delivery to the system Shortcut")
    try check(
      DictationLiveActivity.lastPhase == .ready, "Completed transcript ends with a ready Activity")
    try check(
      !DictationLiveActivity.regressedToRecording,
      "Stop never resets Activity processing to recording when partial text clears")
    try check(
      DictationLiveActivity.lastText == "Captured words.",
      "Final Activity preview uses actual final transcript")
    do {
      _ = try await StopLiveDictationIntent(sessionID: UUID()).perform()
      throw Failure.check("Stale stop must fail")
    } catch DictationActionError.noSession { checks += 1 }
    try check(UIPasteboard.general.writes.isEmpty, "Stale Stop never writes the app clipboard")
    _ = try await StartDictationShortcut().perform()
    let widgetSession = owner!.sessionIdentifier!
    let activityFinishesBeforeWidgetStop = DictationLiveActivity.finishes
    recorder.feed(32_000)
    let widgetResult = try await StopLiveDictationIntent(sessionID: widgetSession).perform()
    try check(
      widgetResult.value == "Captured words." && controller.phase == .idle && !recorder.recording,
      "Widget Stop finalizes the owned microphone and returns its actual transcript")
    try check(
      owner!.sessionIdentifier == widgetSession && DictationLiveActivity.lastPhase == .ready
        && DictationLiveActivity.finishes == activityFinishesBeforeWidgetStop,
      "Widget Stop retains its ready result for the Action Button Copy workflow")
    let armCallsAfterWidgetStop = recorder.armCalls
    controller.transcript = "Edited after Widget Stop."
    let widgetCopyResult = try await ToggleDictationShortcut().perform()
    try check(
      widgetCopyResult.value == "Captured words." && recorder.armCalls == armCallsAfterWidgetStop,
      "Next toggle returns the widget snapshot for native Copy without starting a microphone")
    try check(
      owner!.sessionIdentifier == nil && UIPasteboard.general.writes.isEmpty
        && DictationLiveActivity.finishes == activityFinishesBeforeWidgetStop + 1,
      "Native Copy output consumes the widget result once without app clipboard access")
    do {
      _ = try await StopDictationShortcut().perform()
      throw Failure.check("Widget result consumed by Toggle must not be returned twice")
    } catch DictationActionError.noSession { checks += 1 }
    controller.setForeground(true)
    await controller.startRecording()
    do {
      _ = try await StopLiveDictationIntent(sessionID: widgetSession).perform()
      throw Failure.check("Stale Widget Stop must fail")
    } catch DictationActionError.noSession { checks += 1 }
    let cancelledStaleWidgetStop = Task {
      try await StopLiveDictationIntent(sessionID: widgetSession).perform()
    }
    cancelledStaleWidgetStop.cancel()
    do {
      _ = try await cancelledStaleWidgetStop.value
      throw Failure.check("Cancelled stale Widget Stop must fail")
    } catch is CancellationError { checks += 1 }
    try await Task.sleep(for: .milliseconds(20))
    try check(
      controller.phase == .recording && recorder.recording,
      "Stale or cancelled Widget Stop cannot end a later foreground recording")
    await controller.cancelRecording()
    controller.setForeground(false)
    _ = try await StartDictationShortcut().perform()
    let interruptedSession = owner!.sessionIdentifier!
    recorder.feed(32_000)
    recorder.onInterruption?()
    while controller.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
    try check(
      owner!.sessionIdentifier == interruptedSession && !recorder.recording,
      "Interruption retains its completed session for the next Action Button hold")
    controller.transcript = "An edit after the recording finished."
    let interruptedResult = try await ToggleDictationShortcut().perform()
    try check(
      interruptedResult.value == "Captured words." && controller.phase == .idle,
      "Next toggle returns the interrupted session snapshot instead of starting a microphone")
    try check(owner!.sessionIdentifier == nil, "Successful result is consumed once")
    do {
      _ = try await StopDictationShortcut().perform()
      throw Failure.check("Consumed Stop must fail")
    } catch DictationActionError.noSession { checks += 1 }
    _ = try await StartDictationShortcut().perform()
    let completedSession = owner!.sessionIdentifier!
    recorder.feed(32_000)
    _ = try await StopLiveDictationIntent(sessionID: completedSession).perform()
    controller.setForeground(true)
    await controller.startRecording()
    let repeatedWidgetResult = try await StopLiveDictationIntent(sessionID: completedSession)
      .perform()
    try check(
      repeatedWidgetResult.value == "Captured words." && controller.phase == .recording
        && recorder.recording,
      "Repeating Widget Stop returns its retained snapshot without stopping unrelated capture")
    await DictationActionRuntime.cancel(sessionID: completedSession)
    try check(
      controller.phase == .recording && recorder.recording && owner!.sessionIdentifier == nil,
      "Canceling a pending Widget Stop result cannot cancel a later foreground recording")
    await controller.cancelRecording()
    controller.setForeground(false)
    _ = try await StartDictationShortcut().perform()
    do {
      _ = try await ToggleDictationShortcut().perform()
      throw Failure.check("Empty dictation must fail instead of reaching the Copy action")
    } catch DictationActionError.failed { checks += 1 }
    try check(
      owner!.sessionIdentifier == nil && UIPasteboard.general.writes.isEmpty,
      "Empty recognition retires the session without returning stale text or overwriting clipboard")

    _ = try await StartDictationShortcut().perform()
    let cancelSession = DictationActionRuntime.sessionIdentifier?()!
    recorder.feed(32_000)
    controller.saveHistory = true
    await engine.holdFinalization()
    let canceledStop = Task { try await StopDictationShortcut().perform() }
    while !(await engine.finalizationIsHeld()) { try await Task.sleep(for: .milliseconds(10)) }
    let writesBeforeCancellation = UIPasteboard.general.writes.count
    canceledStop.cancel()
    while controller.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
    try check(
      !recorder.recording && !controller.actionButtonRecording,
      "Canceled finalization stops microphone and releases Action ownership")
    await engine.releaseFinalization()
    do {
      _ = try await canceledStop.value
      throw Failure.check("Canceled Stop must fail")
    } catch is CancellationError { checks += 1 }
    try check(
      controller.transcript.isEmpty && controller.history.isEmpty,
      "Canceled finalization never commits late text or history")
    try check(
      UIPasteboard.general.writes.count == writesBeforeCancellation,
      "Canceled finalization never writes clipboard")
    try check(
      DictationLiveActivity.lastPhase == .cancelled && DictationLiveActivity.lastText.isEmpty,
      "Canceled finalization has a cancelled Activity without transcript")
    _ = try await StartDictationShortcut().perform()
    await DictationActionRuntime.cancel(sessionID: cancelSession!)
    try check(
      controller.phase == .recording && recorder.recording,
      "Stale cancellation cannot end a later Action session")
    let canceledStaleStop = Task {
      try await DictationActionRuntime.perform(.stop(sessionID: cancelSession!))
    }
    canceledStaleStop.cancel()
    do {
      _ = try await canceledStaleStop.value
      throw Failure.check("Canceled stale Stop must fail")
    } catch is CancellationError { checks += 1 }
    try await Task.sleep(for: .milliseconds(20))
    try check(
      controller.phase == .recording && recorder.recording,
      "Canceling a stale explicit Stop never cancels the current session")
    let currentSession = DictationActionRuntime.sessionIdentifier?()!
    await DictationActionRuntime.cancel(sessionID: currentSession!)
    try check(
      controller.phase == .idle && !recorder.recording,
      "Matching explicit cancellation ends recording")
    try check(
      DictationLiveActivity.lastPhase == .cancelled, "Explicit cancellation never renders as failed"
    )
    _ = try await StartDictationShortcut().perform()
    await controller.cancelRecording()
    try check(
      DictationLiveActivity.lastPhase == .cancelled,
      "App Discard action ends Action Button Activity as cancelled")
    let actualHandler = DictationActionRuntime.handler!
    DictationActionRuntime.handler = { action in
      let result = try await actualHandler(action)
      if case .startSession = action {
        await withCheckedContinuation { startedHandlerContinuation = $0 }
      }
      return result
    }
    let canceledStart = Task { try await StartDictationShortcut().perform() }
    while startedHandlerContinuation == nil { try await Task.sleep(for: .milliseconds(10)) }
    try check(
      controller.phase == .recording && recorder.recording,
      "Start cancellation fixture suspends after real capture begins")
    canceledStart.cancel()
    while controller.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
    startedHandlerContinuation?.resume()
    startedHandlerContinuation = nil
    do {
      _ = try await canceledStart.value
      throw Failure.check("Canceled Start must fail")
    } catch is CancellationError { checks += 1 }
    try check(
      !recorder.recording && !controller.actionButtonRecording && controller.transcript.isEmpty,
      "Start cancellation after its handler returns retires only its newly started microphone")
    try check(
      UIPasteboard.general.writes.count == writesBeforeCancellation && controller.history.isEmpty,
      "Canceled Start saves no history and leaves clipboard unchanged")
    DictationActionRuntime.handler = actualHandler
    controller.saveHistory = false
    _ = try await StartDictationShortcut().perform()
    recorder.feed(96_000)
    let completionProgress = Progress(totalUnitCount: 1)
    let progressText = try await DictationActionRuntime.perform(
      .stop(sessionID: nil, progress: completionProgress))
    try check(
      progressText == "Captured words." && completionProgress.totalUnitCount >= 3
        && completionProgress.completedUnitCount == completionProgress.totalUnitCount,
      "Preparation, drained audio chunks, finalization and completed storage advance real progress")
    let blockedEngine = LifecycleEngine()
    await blockedEngine.disableCPUBackground()
    let blockedController = await fixture(engine: blockedEngine)
    blockedController.setForeground(false)
    await blockedController.startActionButtonRecording()
    try check(
      blockedController.phase == .idle && !blockedController.actionButtonRecording,
      "Runtime denial prevents CPU-named model from background execution")
    controller.selectedModel = .parakeetPhonon
    do {
      _ = try await StartDictationShortcut().perform()
      throw Failure.check("Accelerated background model must fail")
    } catch DictationActionError.failed { checks += 1 }
    try check(
      controller.phase == .idle && !recorder.recording,
      "Unsupported background model never starts microphone")
    controller.selectedModel = .parakeetRealtimeEOU
    recorder.microphonePermissionGranted = false
    do {
      _ = try await StartDictationShortcut().perform()
      throw Failure.check("Unconfigured microphone must fail")
    } catch DictationActionError.failed { checks += 1 }
    try check(
      !recorder.recording, "Background start never prompts or records without prior permission")
    try check(
      DictationLiveActivity.lastPhase == .failed
        && DictationLiveActivity.lastMessage?.contains("microphone access") == true,
      "Microphone start failure preserves an Activity failure reason")
    recorder.microphonePermissionGranted = true
    DictationLiveActivity.authorized = false
    do {
      _ = try await StartDictationShortcut().perform()
      throw Failure.check("Disabled activity must fail")
    } catch DictationActionError.failed { checks += 1 }
    try check(
      controller.phase == .idle && !recorder.recording,
      "Unavailable required Live Activity does not activate microphone")
    DictationLiveActivity.authorized = true
    DictationLiveActivity.requestSucceeds = false
    AudioRecorder.samplesOnBeginCapture = 8_000
    controller.saveHistory = true
    let writesBeforeFailedStart = UIPasteboard.general.writes.count
    let transcriptBeforeFailedStart = controller.transcript
    let armCallsBeforeFailedStart = recorder.armCalls
    do {
      _ = try await StartDictationShortcut().perform()
      throw Failure.check("Activity creation failure must fail")
    } catch DictationActionError.failed { checks += 1 }
    try check(
      controller.phase == .idle && !recorder.recording
        && recorder.armCalls == armCallsBeforeFailedStart,
      "Activity creation failure never activates microphone")
    try check(
      controller.transcript == transcriptBeforeFailedStart && controller.history.isEmpty,
      "Failed Activity creation preserves existing text and saves no new recording")
    try check(
      UIPasteboard.general.writes.count == writesBeforeFailedStart,
      "Failed shortcut start never replaces the clipboard")
    AudioRecorder.samplesOnBeginCapture = 0
    owner = nil
    try check(retainedBridge == nil, "Handler holds no hidden second recorder owner")
    retainedBridge = nil
    do {
      _ = try await StartDictationShortcut().perform()
      throw Failure.check("Missing retained app owner must fail")
    } catch DictationActionError.notReady { checks += 1 }
    print("PASS: \(checks) actual shortcut/bridge/controller checks")
  }
}
