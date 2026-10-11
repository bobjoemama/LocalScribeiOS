import ActivityKit
import Foundation

@MainActor
final class DictationLiveActivity {
  enum PreviewCapability: Equatable { case streamingText, statusOnly }
  private struct Session {
    let activityID: String
    let previewCapability: PreviewCapability
  }
  private var session: Session?
  private var startingSessionID: UUID?
  private var updates = Task<Void, Never> {}
  private var drainActivityID: String?
  private var pendingState: DictationActivityAttributes.ContentState?
  private var lastState: DictationActivityAttributes.ContentState?
  private var transcriptTail: String?
  private var microphoneLeaseRetained = false

  var canStartRecordingActivity: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

  var isEnabled: Bool { canStartRecordingActivity }
  var hasActiveActivity: Bool {
    guard let session,
      let activity = Activity<DictationActivityAttributes>.activities.first(where: { $0.id == session.activityID })
    else { return false }
    return activity.activityState == .active || activity.activityState == .stale
  }

  @discardableResult
  func start(
    sessionID: UUID, modelName: String, startedAt: Date,
    previewCapability: PreviewCapability, required: Bool = false
  ) async -> Bool {
    guard required ? canStartRecordingActivity : isEnabled else { return false }
    if let session {
      if hasActiveActivity, Activity<DictationActivityAttributes>.activities.first(where: { $0.id == session.activityID })?
        .attributes.sessionID == sessionID { return true }
      guard microphoneLeaseRetained else { return false }
    }
    guard startingSessionID == nil else { return false }
    startingSessionID = sessionID
    defer {
      if startingSessionID == sessionID { startingSessionID = nil }
    }
    // Finish the previous session and launch-time cleanup before requesting a
    // replacement. During recording, updates never end or recreate this activity.
    let previous = updates
    await previous.value
    guard startingSessionID == sessionID, !Task.isCancelled else { return false }
    let completedSession = microphoneLeaseRetained ? session : nil
    let attributes = DictationActivityAttributes(
      sessionID: sessionID, startedAt: startedAt, modelName: modelName)
    let state = DictationActivityAttributes.ContentState(
      phase: .recording, elapsed: 0, message: nil)
    do {
      let activity = try Activity.request(
        attributes: attributes, content: ActivityContent(state: state, staleDate: nil),
        pushType: nil
      )
      session = Session(activityID: activity.id, previewCapability: previewCapability)
      microphoneLeaseRetained = false
      transcriptTail = nil
      lastState = state
      pendingState = nil
      if let completedSession {
        // The explicit microphone lease stays covered while its utterance
        // Activity is replaced. Never end the old Activity before this request.
        let retirement = Task {
          await Self.endActivity(id: completedSession.activityID, state: nil, dismissalAfter: nil)
        }
        updates = retirement
        await retirement.value
        guard startingSessionID == sessionID, session?.activityID == activity.id,
          !Task.isCancelled else { return false }
      }
      return true
    } catch {
      // A denied replacement must preserve the completed Activity covering
      // the already-enabled microphone lease.
      if completedSession == nil { session = nil }
      return false
    }
  }

  func update(
    phase: DictationActivityAttributes.Phase, elapsed: TimeInterval, message: String? = nil,
    transcript: String? = nil
  ) {
    guard let session else { return }
    let activityID = session.activityID
    if session.previewCapability == .statusOnly {
      transcriptTail = nil
    } else if let transcript {
      let tail = DictationTranscriptTail.make(from: transcript)
      transcriptTail = tail.isEmpty ? nil : tail
    }
    let state = DictationActivityAttributes.ContentState(
      phase: phase, elapsed: elapsed, message: message, transcriptTail: transcriptTail)
    guard state != lastState else { return }
    // The system renders the recording timer from startedAt. Elapsed-only
    // changes (including discarded windowed text) need no ActivityKit update.
    if phase == .recording, let lastState, lastState.phase == .recording,
      lastState.message == message, lastState.transcriptTail == transcriptTail {
      return
    }
    lastState = state
    pendingState = state
    // At most one in-flight update and one replacing snapshot. Rapid live
    // recognition revisions cannot grow a queue of text-bearing tasks.
    guard drainActivityID != activityID else { return }
    drainActivityID = activityID
    let previous = updates
    updates = Task { [weak self] in
      await previous.value
      while let self, self.session?.activityID == activityID, let state = self.pendingState {
        self.pendingState = nil
        await Self.sendUpdate(id: activityID, state: state)
      }
      if self?.drainActivityID == activityID { self?.drainActivityID = nil }
    }
  }

  func finish(transcript: String, elapsed: TimeInterval, microphoneRemainsActive: Bool = false) {
    if microphoneRemainsActive, session != nil {
      microphoneLeaseRetained = true
      update(phase: .ready, elapsed: elapsed, message: "Ready · Mic on", transcript: transcript)
      return
    }
    let tail = session?.previewCapability == .streamingText
      ? DictationTranscriptTail.make(from: transcript) : ""
    end(
      phase: .ready, elapsed: elapsed, transcriptTail: tail.isEmpty ? nil : tail, dismissalAfter: 10
    )
  }

  func fail(message: String?, elapsed: TimeInterval, microphoneRemainsActive: Bool = false) {
    // Keep the detailed audio error in the shortcut/app; the activity gets
    // only the first, bounded sentence and never contains captured speech.
    let reason = message?.split(separator: ".", maxSplits: 1).first.map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let shortReason = reason.map { String($0.prefix(100)) }
    if microphoneRemainsActive, session != nil {
      startingSessionID = nil
      microphoneLeaseRetained = true
      transcriptTail = nil
      update(phase: .failed, elapsed: elapsed, message: (shortReason ?? "Dictation failed") + " · Mic on")
      return
    }
    end(phase: .failed, elapsed: elapsed, message: shortReason, dismissalAfter: 10)
  }

  func cancel(elapsed: TimeInterval, microphoneRemainsActive: Bool = false) {
    if microphoneRemainsActive, session != nil {
      startingSessionID = nil
      microphoneLeaseRetained = true
      transcriptTail = nil
      update(phase: .cancelled, elapsed: elapsed, message: "Cancelled · Mic on")
      return
    }
    end(phase: .cancelled, elapsed: elapsed, dismissalAfter: 4)
  }

  /// Ending the explicit idle microphone lease cannot end a newer recording.
  func endMicrophoneLease() {
    guard microphoneLeaseRetained, let lastState else { return }
    let message = lastState.phase == .ready ? nil
      : lastState.message?.replacingOccurrences(of: " · Mic on", with: "")
    end(phase: lastState.phase, elapsed: lastState.elapsed, message: message,
        transcriptTail: lastState.transcriptTail, dismissalAfter: 10)
  }

  private func end(
    phase: DictationActivityAttributes.Phase, elapsed: TimeInterval, message: String? = nil,
    transcriptTail: String? = nil, dismissalAfter: TimeInterval
  ) {
    startingSessionID = nil
    microphoneLeaseRetained = false
    guard let session else { return }
    let activityID = session.activityID
    self.session = nil
    pendingState = nil
    drainActivityID = nil
    let previous = updates
    let state = DictationActivityAttributes.ContentState(
      phase: phase, elapsed: elapsed, message: message,
      transcriptTail: session.previewCapability == .streamingText ? transcriptTail : nil)
    self.transcriptTail = nil
    lastState = nil
    updates = Task {
      await previous.value
      await Self.endActivity(id: activityID, state: state, dismissalAfter: dismissalAfter)
    }
  }

  /// Relaunch cannot continue a microphone session from a terminated process.
  func clearOrphanedActivities() {
    let previous = updates
    // Capture only launch-time IDs; cleanup can never reach a later request.
    let orphanedIDs = Set(Activity<DictationActivityAttributes>.activities.map(\.id))
      .subtracting(session.map { [$0.activityID] } ?? [])
    updates = Task {
      await previous.value
      for id in orphanedIDs {
        await Self.endActivity(id: id, state: nil, dismissalAfter: nil)
      }
    }
  }

  /// Activity itself is not Sendable. Look it up and use it entirely on a
  /// detached executor; only immutable IDs and value snapshots cross actors.
  private nonisolated static func sendUpdate(
    id: String, state: DictationActivityAttributes.ContentState
  ) async {
    await Task.detached {
      guard
        let activity = Activity<DictationActivityAttributes>.activities.first(where: { $0.id == id }
        )
      else { return }
      await activity.update(ActivityContent(state: state, staleDate: nil))
    }.value
  }

  private nonisolated static func endActivity(
    id: String, state: DictationActivityAttributes.ContentState?, dismissalAfter: TimeInterval?
  ) async {
    await Task.detached {
      guard
        let activity = Activity<DictationActivityAttributes>.activities.first(where: { $0.id == id }
        )
      else { return }
      let content = state.map { ActivityContent(state: $0, staleDate: nil) }
      let policy: ActivityUIDismissalPolicy =
        dismissalAfter.map { .after(Date().addingTimeInterval($0)) } ?? .immediate
      await activity.end(content, dismissalPolicy: policy)
    }.value
  }
}
