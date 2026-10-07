import AppIntents
import Combine
import Foundation
import OSLog
import LocalScribeCore
#if canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers

/// Uses the same app-owned recorder and model as Dictate. Clipboard writes apply only
/// to recordings explicitly started through these shortcuts, never keyboard/app sessions.
@MainActor
final class DictationActionBridge {
    private let logger = Logger(subsystem: "com.devesh.localscribe.ios", category: "DictationShortcut")
    private weak var controller: AppController?
    private let liveActivity = DictationLiveActivity()
    private var subscription: AnyCancellable?
    private var transcriptSubscription: AnyCancellable?
    private var recordingActivityStarted = false
    private var completedResult: String?
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
            guard let self, self.didBeginRecording, self.pendingResult == nil, !text.isEmpty else { return }
            self.liveActivity.update(phase: controller.phase == .recording ? .recording : .transcribing, elapsed: controller.elapsed, transcript: text)
        }
        #if canImport(UIKit)
        LocalScribeShortcuts.updateAppShortcutParameters()
        #endif
        logger.notice("Shortcut handler registered")
    }

    private func perform(_ action: DictationActionRuntime.Action) async throws -> String? {
        guard let controller else { throw DictationActionError.notReady }
        if case let .cancel(sessionID) = action {
            guard activeSessionID == sessionID else { return nil }
            didBeginRecording = false
            activeSessionID = nil
            pendingResult = nil
            completedResult = nil
            liveActivity.finish(copied: false, elapsed: controller.elapsed)
            await controller.cancelRecording()
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
        case let .startSession(sessionID):
            try await start(controller, sessionID: sessionID)
            if Task.isCancelled {
                _ = try await perform(.cancel(sessionID: sessionID))
                throw CancellationError()
            }
            return nil
        case let .stop(expectedID, progress):
            return try await stop(controller, expectedID: expectedID, progress: progress)
        case .toggle:
            if activeSessionID == nil { try await start(controller); return nil }
            return try await stop(controller, expectedID: nil)
        case .cancel: return nil
        }
    }

    private func start(_ controller: AppController, sessionID: UUID = UUID()) async throws {
        guard activeSessionID == nil, controller.phase == .idle else { throw DictationActionError.busy }
        guard liveActivity.canStartRecordingActivity else {
            throw DictationActionError.failed("Enable Live Activities for LocalScribe in iPhone Settings to record through shortcuts. You can still record directly in LocalScribe.")
        }
        await controller.refreshInstalledModels()
        recordingActivityStarted = false
        activeSessionID = sessionID
        sessionModelName = controller.selectedBackgroundModel.name
        pendingResult = nil
        completedResult = nil
        didBeginRecording = false
        recordingActivityStarted = liveActivity.start(sessionID: sessionID, modelName: sessionModelName, startedAt: Date(), required: true)
        guard recordingActivityStarted else {
            activeSessionID = nil
            throw DictationActionError.failed("iOS could not start the recording Live Activity. Check Live Activities in iPhone Settings.")
        }
        logger.notice("Shortcut microphone start requested")
        await controller.startActionButtonRecording()
        logger.notice("Shortcut start returned; recording=\(controller.phase == .recording, privacy: .public) activity=\(self.recordingActivityStarted, privacy: .public)")
        if controller.phase == .recording, !recordingActivityStarted {
            // This start never acquired the platform recording contract. Discard
            // its audio instead of finalizing it into history or the clipboard.
            didBeginRecording = false
            activeSessionID = nil
            pendingResult = nil
            await controller.cancelRecording()
            throw DictationActionError.failed("iOS could not start the recording Live Activity. Open LocalScribe to record directly, or check Live Activities in iPhone Settings.")
        }
        guard controller.phase == .recording, didBeginRecording else {
            activeSessionID = nil
            liveActivity.finish(copied: false, elapsed: 0)
            recordingActivityStarted = false
            logger.error("Shortcut microphone capture did not start")
            throw DictationActionError.failed(controller.errorMessage ?? "Dictation could not start. Open Local Scribe to check microphone access and your selected model.")
        }
    }

    private func stop(_ controller: AppController, expectedID: UUID?, progress: Progress? = nil) async throws -> String {
        guard let id = activeSessionID, expectedID == nil || expectedID == id else { throw DictationActionError.noSession }
        if controller.phase == .recording { await controller.stopActionButtonRecording(progress: progress) }
        else if controller.phase == .transcribing {
            // A microphone interruption/backpressure stop may already be finishing.
            while activeSessionID == id && controller.phase == .transcribing {
                try await Task.sleep(for: .milliseconds(100))
            }
        } else if pendingResult != nil { deliverPendingResult() }
        else { throw DictationActionError.noSession }
        try Task.checkCancellation()
        logger.notice("Shortcut stop completed")
        guard let result = completedResult, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictationActionError.failed(controller.errorMessage ?? "No speech was recognized.")
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
            completedResult = text
            didBeginRecording = false
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                liveActivity.finish(copied: false, elapsed: controller.elapsed)
                activeSessionID = nil
            } else {
                // Preserve exactly this completed session, including interruption results.
                liveActivity.update(phase: .transcribing, elapsed: controller.elapsed, transcript: text)
                pendingResult = text
                pendingElapsed = controller.elapsed
                deliverPendingResult()
            }
        }
    }

    private func deliverPendingResult() {
        guard let text = pendingResult else { return }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
        pendingResult = nil
        activeSessionID = nil
        liveActivity.finish(copied: true, elapsed: pendingElapsed, transcript: text)
        logger.notice("Shortcut result submitted to clipboard")
    }
}
