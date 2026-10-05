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
            return Activity<DictationActivityAttributes>.activities.first(where: { $0.id == activityID })?.attributes.sessionID == sessionID
        }
        let attributes = DictationActivityAttributes(sessionID: sessionID, startedAt: startedAt, modelName: modelName)
        let state = DictationActivityAttributes.ContentState(phase: .recording, elapsed: 0, message: nil)
        do {
            activityID = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil).id
            transcriptTail = nil
            lastState = state
            pendingState = nil
            return true
        } catch {
            activityID = nil
            return false
        }
    }

    func update(phase: DictationActivityAttributes.Phase, elapsed: TimeInterval, message: String? = nil, transcript: String? = nil) {
        guard let activityID else { return }
        if let transcript {
            let tail = DictationTranscriptTail.make(from: transcript)
            transcriptTail = tail.isEmpty ? nil : tail
        }
        let state = DictationActivityAttributes.ContentState(phase: phase, elapsed: elapsed, message: message, transcriptTail: transcriptTail)
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

    func finish(copied: Bool, elapsed: TimeInterval, transcript: String? = nil) {
        guard let activityID else { return }
        if copied, let transcript {
            let tail = DictationTranscriptTail.make(from: transcript)
            transcriptTail = tail.isEmpty ? nil : tail
        }
        self.activityID = nil
        pendingState = nil
        drainActivityID = nil
        let previous = updates
        let phase: DictationActivityAttributes.Phase = copied ? .ready : .failed
        let state = DictationActivityAttributes.ContentState(phase: phase, elapsed: elapsed, message: nil, transcriptTail: copied ? transcriptTail : nil)
        transcriptTail = nil
        lastState = nil
        updates = Task {
            await previous.value
            await Self.endActivity(id: activityID, state: state, dismissalAfter: 10)
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
    private nonisolated static func sendUpdate(id: String, state: DictationActivityAttributes.ContentState) async {
        await Task.detached {
            guard let activity = Activity<DictationActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }.value
    }

    private nonisolated static func endActivity(id: String, state: DictationActivityAttributes.ContentState?, dismissalAfter: TimeInterval?) async {
        await Task.detached {
            guard let activity = Activity<DictationActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
            let content = state.map { ActivityContent(state: $0, staleDate: nil) }
            let policy: ActivityUIDismissalPolicy = dismissalAfter.map { .after(Date().addingTimeInterval($0)) } ?? .immediate
            await activity.end(content, dismissalPolicy: policy)
        }.value
    }
}
