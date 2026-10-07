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
    let cancelID = UUID()
    try check(
      activity.start(sessionID: cancelID, modelName: "Realtime", startedAt: Date()),
      "Start creates an Activity")
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
    try check(
      activity.start(sessionID: UUID(), modelName: "Realtime", startedAt: Date()),
      "A new Activity can start after cancellation")
    let failed = Activity<DictationActivityAttributes>.activities.last!
    activity.update(
      phase: .transcribing, elapsed: 3, transcript: "Private speech should not survive failure.")
    activity.fail(message: "Microphone unavailable. Open LocalScribe and try again.", elapsed: 3)
    try await waitForEnd(failed)
    try check(
      failed.finalState?.phase == .failed && failed.finalState?.status == "Microphone unavailable",
      "Failure shows its short cause")
    try check(failed.finalState?.transcriptTail == nil, "Failed Activity contains no transcript")
    try check(
      activity.start(sessionID: UUID(), modelName: "Realtime", startedAt: Date()),
      "A new Activity can start after failure")
    let completed = Activity<DictationActivityAttributes>.activities.last!
    let finalText = "One. Two. Three. Four."
    activity.finish(transcript: finalText, elapsed: 7)
    try await waitForEnd(completed)
    try check(
      completed.finalState?.phase == .ready && completed.finalState?.status == "Copied",
      "Successful copy has its own ready outcome")
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
    print("PASS: \(checks) production Activity state/lifecycle checks")
  }
}
