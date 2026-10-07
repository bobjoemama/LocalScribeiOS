import ActivityKit
import Foundation

@MainActor
final class DictationLiveActivity {
  private var activityID: String?
  private var updates = Task<Void, Never> {}
  private var drainActivityID: String?
  private var pendingState: DictationActivityAttributes.ContentState?
  private var lastState: DictationActivityAttributes.ContentState?
  private var transcriptTail: String?

  var canStartRecordingActivity: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

  var isEnabled: Bool { canStartRecordingActivity }

  @discardableResult
  func start(sessionID: UUID, modelName: String, startedAt: Date, required: Bool = false) -> Bool {
    guard required ? canStartRecordingActivity : isEnabled else { return false }
    if let activityID {
      return Activity<DictationActivityAttributes>.activities.first(where: { $0.id == activityID })?
        .attributes.sessionID == sessionID
    }
    let attributes = DictationActivityAttributes(
      sessionID: sessionID, startedAt: startedAt, modelName: modelName)
    let state = DictationActivityAttributes.ContentState(
      phase: .recording, elapsed: 0, message: nil)
    do {
      activityID = try Activity.request(
        attributes: attributes, content: ActivityContent(state: state, staleDate: nil),
        pushType: nil
      ).id
      transcriptTail = nil
      lastState = state
      pendingState = nil
      return true
    } catch {
      activityID = nil
      return false
    }
  }

  func update(
    phase: DictationActivityAttributes.Phase, elapsed: TimeInterval, message: String? = nil,
    transcript: String? = nil
  ) {
    guard let activityID else { return }
    if let transcript {
      let tail = DictationTranscriptTail.make(from: transcript)
      transcriptTail = tail.isEmpty ? nil : tail
    }
    let state = DictationActivityAttributes.ContentState(
      phase: phase, elapsed: elapsed, message: message, transcriptTail: transcriptTail)
    guard state != lastState else { return }
    lastState = state
    pendingState = state
    // At most one in-flight update and one replacing snapshot. Rapid live
    // recognition revisions cannot grow a queue of text-bearing tasks.
    guard drainActivityID != activityID else { return }
    drainActivityID = activityID
    let previous = updates
    updates = Task { [weak self] in
      await previous.value
      while let self, self.activityID == activityID, let state = self.pendingState {
        self.pendingState = nil
        await Self.sendUpdate(id: activityID, state: state)
      }
      if self?.drainActivityID == activityID { self?.drainActivityID = nil }
    }
  }

  func finish(transcript: String, elapsed: TimeInterval) {
    let tail = DictationTranscriptTail.make(from: transcript)
    end(
      phase: .ready, elapsed: elapsed, transcriptTail: tail.isEmpty ? nil : tail, dismissalAfter: 10
    )
  }

  func fail(message: String?, elapsed: TimeInterval) {
    // Keep the detailed audio error in the shortcut/app; the activity gets
    // only the first, bounded sentence and never contains captured speech.
    let reason = message?.split(separator: ".", maxSplits: 1).first.map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let shortReason = reason.map { String($0.prefix(100)) }
    end(phase: .failed, elapsed: elapsed, message: shortReason, dismissalAfter: 10)
  }

  func cancel(elapsed: TimeInterval) {
    end(phase: .cancelled, elapsed: elapsed, dismissalAfter: 4)
  }

  private func end(
    phase: DictationActivityAttributes.Phase, elapsed: TimeInterval, message: String? = nil,
    transcriptTail: String? = nil, dismissalAfter: TimeInterval
  ) {
    guard let activityID else { return }
    self.activityID = nil
    pendingState = nil
    drainActivityID = nil
    let previous = updates
    let state = DictationActivityAttributes.ContentState(
      phase: phase, elapsed: elapsed, message: message, transcriptTail: transcriptTail)
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
    let orphanedIDs = Set(Activity<DictationActivityAttributes>.activities.map(\.id))
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
