import AppIntents
import Combine
import Foundation
import LocalScribeCore
import OSLog

#if canImport(UIKit)
  import UIKit
#endif

/// Uses the app-owned recorder and returns only the transcript of its shortcut session.
/// The calling Shortcut copies this output using the system Copy to Clipboard action;
/// background pasteboard writes have no success acknowledgement from UIKit.
@MainActor
final class DictationActionBridge: ObservableObject {
  struct ActionDiagnostic: Equatable {
    enum Action: String { case start, stop, widgetFinish }
    enum Outcome: String { case running, completed, cancelled, failed }
    enum ExecutionContext: String { case foreground, background, inactive, unavailable }
    let action: Action
    let outcome: Outcome
    let resultNonempty: Bool
    let durationSeconds: TimeInterval
    let executionContext: ExecutionContext
    let cancellationReason: DictationActionRuntime.CancellationReason?
  }
  /// In-memory operational status only; never contains speech, clipboard text or identifiers.
  @Published private(set) var diagnostic: ActionDiagnostic?
  private var diagnosticStartedAt: ContinuousClock.Instant?
  private var diagnosticSessionID: UUID?

  private let logger = Logger(
    subsystem: "com.devesh.localscribe.ios", category: "DictationShortcut")
  private weak var controller: AppController?
  private let liveActivity = DictationLiveActivity()
  private var subscription: AnyCancellable?
  private var transcriptSubscription: AnyCancellable?
  private var recordingActivityStarted = false
  private var pendingResult: String?
  private var pendingElapsed: TimeInterval = 0
  private var sessionModelName = ""
  private var activeSessionID: UUID?
  private var didBeginRecording = false
  private var handlingAction = false

  var hasActiveSession: Bool { activeSessionID != nil }
  var sessionIdentifier: UUID? { activeSessionID }

  init(controller: AppController) {
    self.controller = controller
    liveActivity.clearOrphanedActivities()
    subscription = controller.$phase.dropFirst().sink { [weak self] phase in
      self?.phaseChanged(phase)
    }
    DictationActionRuntime.handler = { [weak self] action in
      guard let self else { throw DictationActionError.notReady }
      return try await self.perform(action)
    }
    DictationActionRuntime.sessionIdentifier = { [weak self] in self?.activeSessionID }
    transcriptSubscription = controller.$partialText.dropFirst().sink { [weak self] text in
      guard let self, self.didBeginRecording, self.pendingResult == nil, !text.isEmpty else {
        return
      }
      self.liveActivity.update(
        phase: controller.phase == .recording ? .recording : .transcribing,
        elapsed: controller.elapsed, transcript: text)
    }
    #if canImport(UIKit)
      LocalScribeShortcuts.updateAppShortcutParameters()
    #endif
    logger.notice("Shortcut handler registered")
  }

  private func perform(_ action: DictationActionRuntime.Action) async throws -> String? {
    guard let controller else { throw DictationActionError.notReady }
    if case .cancel(let sessionID, let reason) = action {
      // The platform reason can arrive after Swift task cancellation already
      // cleaned up audio. Correlate it only to this diagnostic operation.
      guard activeSessionID == sessionID else {
        if diagnosticSessionID == sessionID, let diagnostic, diagnostic.outcome == .cancelled {
          recordDiagnostic(action: diagnostic.action, outcome: .cancelled, reason: reason)
        }
        return nil
      }
      if let diagnostic {
        recordDiagnostic(action: diagnostic.action, outcome: .cancelled, reason: reason)
      }
      let needsRecordingCancellation = pendingResult == nil
      didBeginRecording = false
      activeSessionID = nil
      pendingResult = nil
      liveActivity.cancel(elapsed: controller.elapsed)
      if needsRecordingCancellation {
        await controller.cancelActionButtonRecording(requestID: sessionID)
      }
      return nil
    }
    try Task.checkCancellation()
    guard !handlingAction else { throw DictationActionError.busy }
    handlingAction = true
    defer { handlingAction = false }
    let diagnosticAction: ActionDiagnostic.Action
    switch action {
    case .start, .startSession: diagnosticAction = .start
    case .finish: diagnosticAction = .widgetFinish
    case .toggle: diagnosticAction = activeSessionID == nil ? .start : .stop
    case .stop: diagnosticAction = .stop
    case .cancel: return nil
    }
    switch action {
    case .startSession(let id), .finish(let id, _, _): diagnosticSessionID = id
    case .stop(let id, _, _): diagnosticSessionID = id ?? activeSessionID
    default: diagnosticSessionID = activeSessionID
    }
    diagnosticStartedAt = .now
    logger.notice("Shortcut invocation action=\(diagnosticAction.rawValue, privacy: .public) session_present=\(self.activeSessionID != nil, privacy: .public)")
    recordDiagnostic(action: diagnosticAction, outcome: .running)
    do {
      let result = try await performOwnedAction(action, controller: controller)
      recordDiagnostic(action: diagnosticAction, outcome: .completed, result: result)
      return result
    } catch {
      let cancelled = error is CancellationError || Task.isCancelled || diagnostic?.outcome == .cancelled
      recordDiagnostic(
        action: diagnosticAction, outcome: cancelled ? .cancelled : .failed,
        reason: cancelled ? diagnostic?.cancellationReason ?? .taskCancelled : nil)
      throw error
    }
  }

  private func recordDiagnostic(
    action: ActionDiagnostic.Action, outcome: ActionDiagnostic.Outcome, result: String? = nil,
    reason: DictationActionRuntime.CancellationReason? = nil
  ) {
    let duration = diagnosticStartedAt?.duration(to: .now) ?? .zero
    let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    let context: ActionDiagnostic.ExecutionContext
    #if canImport(UIKit)
      switch UIApplication.shared.applicationState {
      case .active: context = .foreground
      case .background: context = .background
      case .inactive: context = .inactive
      @unknown default: context = .unavailable
      }
    #else
      context = .unavailable
    #endif
    let nonempty = result.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    let effectiveReason: DictationActionRuntime.CancellationReason?
    if outcome == .cancelled, let previousReason = diagnostic?.cancellationReason,
       previousReason == .timeout || previousReason == .userCancelled,
       reason == .taskCancelled || reason == .requested {
      effectiveReason = previousReason
    } else {
      effectiveReason = reason
    }
    diagnostic = ActionDiagnostic(
      action: action, outcome: outcome, resultNonempty: nonempty, durationSeconds: seconds,
      executionContext: context, cancellationReason: effectiveReason)
    logger.notice("Shortcut action=\(action.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) result_nonempty=\(nonempty, privacy: .public) seconds=\(seconds, privacy: .public) context=\(context.rawValue, privacy: .public)")
  }

  private func performOwnedAction(
    _ action: DictationActionRuntime.Action, controller: AppController
  ) async throws -> String? {
    switch action {
    case .start:
      try await start(controller)
      return nil
    case .startSession(let sessionID):
      try await start(controller, sessionID: sessionID)
      if Task.isCancelled {
        _ = try await perform(.cancel(sessionID: sessionID))
        throw CancellationError()
      }
      return nil
    case .stop(let expectedID, let progress, let execution):
      return try await stop(controller, expectedID: expectedID, progress: progress, completionExecution: execution)
    case .finish(let expectedID, let progress, let execution):
      return try await stop(
        controller, expectedID: expectedID, progress: progress, consumeResult: false, completionExecution: execution)
    case .toggle:
      if activeSessionID == nil {
        try await start(controller)
        return nil
      }
      return try await stop(controller, expectedID: nil)
    case .cancel: return nil
    }
  }

  private func start(_ controller: AppController, sessionID: UUID = UUID()) async throws {
    guard activeSessionID == nil, controller.phase == .idle else { throw DictationActionError.busy }
    guard liveActivity.canStartRecordingActivity else {
      throw DictationActionError.failed(
        "Enable Live Activities for LocalScribe in iPhone Settings to record through shortcuts. You can still record directly in LocalScribe."
      )
    }
    // Freeze once before discovery or any other suspension. The recorder,
    // activity name and preview policy all refer to this exact session model.
    let model = controller.selectedModel
    guard controller.reserveActionButtonRecording(requestID: sessionID, model: model) else {
      throw DictationActionError.busy
    }
    recordingActivityStarted = false
    activeSessionID = sessionID
    diagnosticSessionID = sessionID
    pendingResult = nil
    didBeginRecording = false
    // Discovery suspends before microphone activation. Reserve ownership first
    // so a matching platform cancellation can retire this start while it waits.
    await controller.refreshInstalledModels(prewarm: false)
    guard activeSessionID == sessionID else { throw CancellationError() }
    if Task.isCancelled {
      _ = try await perform(.cancel(sessionID: sessionID, reason: .taskCancelled))
      throw CancellationError()
    }
    let runtimeReady = await controller.prepareReservedActionButtonRecording(requestID: sessionID)
    guard activeSessionID == sessionID else { throw CancellationError() }
    if Task.isCancelled {
      _ = try await perform(.cancel(sessionID: sessionID, reason: .taskCancelled))
      throw CancellationError()
    }
    guard runtimeReady else {
      let message = controller.errorMessage
        ?? "Model still loading. Open LocalScribe and wait until \(model.name) is Ready before using the Action Button."
      activeSessionID = nil
      await controller.cancelActionButtonRecording(requestID: sessionID)
      throw DictationActionError.failed(message)
    }
    sessionModelName = model.name
    let previewCapability: DictationLiveActivity.PreviewCapability =
      model == .parakeetRealtimeEOU || model == .moonshineSmall ? .streamingText : .statusOnly
    let didStartActivity = await liveActivity.start(
      sessionID: sessionID, modelName: sessionModelName, startedAt: Date(),
      previewCapability: previewCapability, required: true)
    guard activeSessionID == sessionID else { throw CancellationError() }
    if Task.isCancelled {
      _ = try await perform(.cancel(sessionID: sessionID, reason: .taskCancelled))
      throw CancellationError()
    }
    recordingActivityStarted = didStartActivity
    guard recordingActivityStarted else {
      activeSessionID = nil
      await controller.cancelActionButtonRecording(requestID: sessionID)
      throw DictationActionError.failed(
        "iOS could not start the recording Live Activity. Check Live Activities in iPhone Settings."
      )
    }
    logger.notice("Shortcut microphone start requested")
    await controller.startReservedActionButtonRecording(requestID: sessionID)
    guard activeSessionID == sessionID else { throw CancellationError() }
    logger.notice(
      "Shortcut start returned; recording=\(controller.phase == .recording, privacy: .public) activity=\(self.recordingActivityStarted, privacy: .public)"
    )
    if controller.phase == .recording, !recordingActivityStarted {
      // This start never acquired the platform recording contract. Discard
      // its audio instead of finalizing it into history or the clipboard.
      didBeginRecording = false
      activeSessionID = nil
      pendingResult = nil
      await controller.cancelActionButtonRecording(requestID: sessionID)
      throw DictationActionError.failed(
        "iOS could not start the recording Live Activity. Open LocalScribe to record directly, or check Live Activities in iPhone Settings."
      )
    }
    guard controller.phase == .recording, controller.actionButtonRecording, didBeginRecording else {
      let message = controller.errorMessage
      activeSessionID = nil
      liveActivity.fail(message: message, elapsed: 0)
      recordingActivityStarted = false
      logger.error("Shortcut microphone capture did not start")
      await controller.cancelActionButtonRecording(requestID: sessionID)
      throw DictationActionError.failed(
        message
          ?? "Dictation could not start. Open LocalScribe to check microphone access and your selected model."
      )
    }
  }

  private func stop(
    _ controller: AppController, expectedID: UUID?, progress: Progress? = nil,
    consumeResult: Bool = true,
    completionExecution: DictationActionRuntime.CompletionExecution = .application
  ) async throws -> String {
    guard let id = activeSessionID, expectedID == nil || expectedID == id else {
      throw DictationActionError.noSession
    }
    let progressUpdates = controller.monitorActionCompletionProgress(progress)
    defer { progressUpdates?.cancel() }
    if pendingResult == nil {
      if completionExecution == .longRunningIntent {
        guard controller.adoptPlatformManagedActionCompletion(requestID: id) else {
          throw DictationActionError.noSession
        }
      }
      if controller.phase == .recording {
        await controller.stopActionButtonRecording(
          progress: progress, completionIsPlatformManaged: completionExecution == .longRunningIntent)
      } else if controller.phase == .transcribing {
        // A microphone interruption/backpressure stop may already be finishing.
        while activeSessionID == id && controller.phase == .transcribing {
          try await Task.sleep(for: .milliseconds(100))
        }
      } else {
        throw DictationActionError.noSession
      }
    }
    try Task.checkCancellation()
    logger.notice("Shortcut stop completed")
    guard activeSessionID == id, let result = pendingResult,
      !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw DictationActionError.failed(controller.errorMessage ?? "No speech was recognized.")
    }
    if consumeResult {
      pendingResult = nil
      activeSessionID = nil
      liveActivity.finish(transcript: result, elapsed: pendingElapsed)
      logger.notice("Shortcut result returned for system clipboard action")
    } else {
      // Island Stop has no Copy action behind it. Retain this exact result so
      // the next Action Button hold returns it instead of starting new capture.
      logger.notice("Widget result retained for Action Button clipboard action")
    }
    return result
  }

  private func phaseChanged(_ phase: DictationPhase) {
    guard let controller, activeSessionID != nil else { return }
    logger.notice("Shortcut controller phase: \(String(describing: phase), privacy: .public)")
    switch phase {
    case .preparing: break
    case .recording:
      guard controller.actionButtonRecording, pendingResult == nil else { return }
      didBeginRecording = true
      liveActivity.update(phase: .recording, elapsed: controller.elapsed)
    case .transcribing:
      guard didBeginRecording else { return }
      liveActivity.update(phase: .transcribing, elapsed: controller.elapsed)
    case .idle:
      guard didBeginRecording else { return }
      let text = controller.transcript
      didBeginRecording = false
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let message = controller.errorMessage {
          liveActivity.fail(message: message, elapsed: controller.elapsed)
        } else {
          // Cancel from the app clears the utterance without an error.
          // Empty recognition has a real controller error instead.
          liveActivity.cancel(elapsed: controller.elapsed)
        }
        activeSessionID = nil
      } else {
        // Preserve exactly this completed session, including interruption results.
        pendingResult = text
        pendingElapsed = controller.elapsed
        liveActivity.update(phase: .ready, elapsed: controller.elapsed, transcript: text)
      }
    }
  }
}
