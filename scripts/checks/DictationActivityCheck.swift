import ActivityKit
import Foundation

@main struct DictationActivityCheck {
  enum Failure: Error { case check(String) }
  @MainActor static var checks = 0
  @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure.check(message) }
    checks += 1
  }
  @MainActor static func waitForEnd(_ activity: Activity<DictationActivityAttributes>) async throws
  {
    for _ in 0..<100 {
      if activity.dismissalPolicy != nil { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw Failure.check("Activity end did not reach the platform boundary")
  }
  @MainActor static func main() async throws {
    let activity = DictationLiveActivity()
    let orphan = try Activity<DictationActivityAttributes>.request(
      attributes: DictationActivityAttributes(sessionID: UUID(), startedAt: Date(), modelName: "Old"),
      content: ActivityContent(
        state: DictationActivityAttributes.ContentState(phase: .recording, elapsed: 0, message: nil),
        staleDate: nil), pushType: nil)
    activity.clearOrphanedActivities()
    let cancelID = UUID()
    let started = await activity.start(
      sessionID: cancelID, modelName: "Realtime", startedAt: Date(), previewCapability: .streamingText)
    try check(started, "Start creates an Activity")
    try check(orphan.dismissalPolicy == .immediate, "Orphan cleanup finishes before a new request")
    let cancelled = Activity<DictationActivityAttributes>.activities.last!
    activity.update(phase: .recording, elapsed: 12, transcript: "Private captured words.")
    let cancelTime = Date()
    activity.cancel(elapsed: 12)
    try await waitForEnd(cancelled)
    try check(cancelled.finalState?.phase == .cancelled, "Cancellation has its own persisted phase")
    try check(
      cancelled.finalState?.transcriptTail == nil, "Cancelled Activity contains no captured speech")
    try check(
      cancelled.finalState?.status == "Cancelled" && cancelled.finalState?.phase.symbol == "xmark",
      "Cancelled presentation is explicit")
    if case .after(let date) = cancelled.dismissalPolicy {
      try check(
        (3.9...4.5).contains(date.timeIntervalSince(cancelTime)),
        "Cancellation dismisses after four seconds")
    } else {
      throw Failure.check("Cancellation must have timed dismissal")
    }
    let encoded = try JSONEncoder().encode(cancelled.finalState!)
    let decoded = try JSONDecoder().decode(
      DictationActivityAttributes.ContentState.self, from: encoded)
    try check(decoded.phase == .cancelled, "Cancelled state round-trips across app/widget boundary")
    let startedAfterCancel = await activity.start(
      sessionID: UUID(), modelName: "Realtime", startedAt: Date(), previewCapability: .streamingText)
    try check(startedAfterCancel, "A new Activity can start after cancellation")
    let failed = Activity<DictationActivityAttributes>.activities.last!
    activity.update(
      phase: .transcribing, elapsed: 3, transcript: "Private speech should not survive failure.")
    activity.fail(message: "Microphone unavailable. Open LocalScribe and try again.", elapsed: 3)
    try await waitForEnd(failed)
    try check(
      failed.finalState?.phase == .failed && failed.finalState?.status == "Microphone unavailable",
      "Failure shows its short cause")
    try check(failed.finalState?.transcriptTail == nil, "Failed Activity contains no transcript")
    let startedAfterFailure = await activity.start(
      sessionID: UUID(), modelName: "Realtime", startedAt: Date(), previewCapability: .streamingText)
    try check(startedAfterFailure, "A new Activity can start after failure")
    let completed = Activity<DictationActivityAttributes>.activities.last!
    let finalText = "One. Two. Three. Four."
    activity.finish(transcript: finalText, elapsed: 7)
    try await waitForEnd(completed)
    try check(
      completed.finalState?.phase == .ready && completed.finalState?.status == "Ready",
      "Completed transcription is ready without claiming clipboard delivery")
    try check(
      completed.finalState?.transcriptTail == DictationTranscriptTail.make(from: finalText),
      "Final preview follows the production bounded-tail policy")
    try check(
      DictationActivityAttributes.Phase.transcribing.symbol == "waveform",
      "Processing symbol represents dictation")
    activity.cancel(elapsed: 0)
    try check(
      completed.finalState?.phase == .ready,
      "An already ended Activity cannot be overwritten by late cancellation")
    let statusStarted = await activity.start(
      sessionID: UUID(), modelName: "Phonon-2", startedAt: Date(), previewCapability: .statusOnly)
    try check(statusStarted, "Status-only Activity starts with the chosen model")
    let statusOnly = Activity<DictationActivityAttributes>.activities.last!
    try check(statusOnly.attributes.modelName == "Phonon-2", "Model name survives into initial attributes")
    for elapsed in 1...10 {
      activity.update(phase: .recording, elapsed: Double(elapsed), transcript: "Window \(elapsed).")
    }
    await Task.yield()
    try check(statusOnly.updateStates.isEmpty,
      "Discarded text and timer ticks do not send redundant recording updates")
    for phase in [DictationActivityAttributes.Phase.transcribing, .ready] {
      let previousCount = statusOnly.updateStates.count
      activity.update(phase: phase, elapsed: 9, transcript: "Private windowed result.")
      let deadline = ContinuousClock.now.advanced(by: .seconds(1))
      while statusOnly.updateStates.count == previousCount, ContinuousClock.now < deadline {
        await Task.yield()
      }
      try check(statusOnly.updateStates.last?.phase == phase
        && statusOnly.updateStates.last?.transcriptTail == nil,
        "Status-only \(phase) update reaches the platform without text")
    }
    activity.finish(transcript: "Full result still returned outside Island.", elapsed: 9)
    // Immediate replacement must await the queued end, rather than request
    // another recording while the former one is still active at ActivityKit.
    let replacementStarted = await activity.start(
      sessionID: UUID(), modelName: "Moonshine Small", startedAt: Date(),
      previewCapability: .streamingText)
    try check(replacementStarted && statusOnly.finalState?.phase == .ready,
      "Queued previous end completes before replacement request")
    try check(statusOnly.finalState?.transcriptTail == nil
      && statusOnly.updateStates.allSatisfy { $0.transcriptTail == nil },
      "Status-only policy gates every update and final ready content")
    let replacement = Activity<DictationActivityAttributes>.activities.last!
    for index in 0..<100 {
      activity.update(phase: .recording, elapsed: 0, transcript: "Revision \(index).")
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while replacement.updateStates.isEmpty, ContinuousClock.now < deadline {
      await Task.yield()
    }
    try check(replacement.updateStates.count == 1
      && replacement.updateStates.last?.transcriptTail == "Revision 99.",
      "A burst coalesces into one latest snapshot without replacing the Activity")
    try check(Activity<DictationActivityAttributes>.activities.last?.id == replacement.id
      && replacement.dismissalPolicy == nil,
      "Recording revisions keep one active Activity identity")
    activity.cancel(elapsed: 0)
    try await waitForEnd(replacement)
    print("PASS: \(checks) production Activity state/lifecycle checks")
  }
}
