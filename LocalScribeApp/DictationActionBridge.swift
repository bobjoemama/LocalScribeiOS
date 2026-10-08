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
final class DictationActionBridge {
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
    if case .cancel(let sessionID) = action {
      guard activeSessionID == sessionID else { return nil }
      let needsRecordingCancellation = pendingResult == nil
      didBeginRecording = false
      activeSessionID = nil
      pendingResult = nil
      liveActivity.cancel(elapsed: controller.elapsed)
      if needsRecordingCancellation { await controller.cancelRecording() }
      return nil
    }
    try Task.checkCancellation()
    guard !handlingAction else { throw DictationActionError.busy }
    handlingAction = true
    defer { handlingAction = false }
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
    case .stop(let expectedID, let progress):
      return try await stop(controller, expectedID: expectedID, progress: progress)
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
    await controller.refreshInstalledModels()
    recordingActivityStarted = false
    activeSessionID = sessionID
    sessionModelName = controller.selectedBackgroundModel.name
    pendingResult = nil
    didBeginRecording = false
    recordingActivityStarted = liveActivity.start(
      sessionID: sessionID, modelName: sessionModelName, startedAt: Date(), required: true)
    guard recordingActivityStarted else {
      activeSessionID = nil
      throw DictationActionError.failed(
        "iOS could not start the recording Live Activity. Check Live Activities in iPhone Settings."
      )
    }
    logger.notice("Shortcut microphone start requested")
    await controller.startActionButtonRecording()
    logger.notice(
      "Shortcut start returned; recording=\(controller.phase == .recording, privacy: .public) activity=\(self.recordingActivityStarted, privacy: .public)"
    )
    if controller.phase == .recording, !recordingActivityStarted {
      // This start never acquired the platform recording contract. Discard
      // its audio instead of finalizing it into history or the clipboard.
      didBeginRecording = false
      activeSessionID = nil
      pendingResult = nil
      await controller.cancelRecording()
      throw DictationActionError.failed(
        "iOS could not start the recording Live Activity. Open LocalScribe to record directly, or check Live Activities in iPhone Settings."
      )
    }
    guard controller.phase == .recording, didBeginRecording else {
      activeSessionID = nil
      liveActivity.fail(message: controller.errorMessage, elapsed: 0)
      recordingActivityStarted = false
      logger.error("Shortcut microphone capture did not start")
      throw DictationActionError.failed(
        controller.errorMessage
          ?? "Dictation could not start. Open LocalScribe to check microphone access and your selected model."
      )
    }
  }

  private func stop(_ controller: AppController, expectedID: UUID?, progress: Progress? = nil)
    async throws -> String
  {
    guard let id = activeSessionID, expectedID == nil || expectedID == id else {
      throw DictationActionError.noSession
    }
    if pendingResult == nil {
      if controller.phase == .recording {
        await controller.stopActionButtonRecording(progress: progress)
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
    pendingResult = nil
    activeSessionID = nil
    liveActivity.finish(transcript: result, elapsed: pendingElapsed)
    logger.notice("Shortcut result returned for system clipboard action")
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
