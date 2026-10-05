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
    private var foregroundSubscription: AnyCancellable?
    private var transcriptSubscription: AnyCancellable?
    private var recordingActivityStarted = false
    private var pendingResult: String?
    private var pendingElapsed: TimeInterval = 0
    private var sessionModelName = ""
    private var activeSessionID: UUID?
    private var didBeginRecording = false
    private var handlingAction = false

    init(controller: AppController) {
        self.controller = controller
        liveActivity.clearOrphanedActivities()
        subscription = controller.$phase.dropFirst().sink { [weak self] phase in
            self?.phaseChanged(phase)
        }
        DictationActionRuntime.handler = { [weak self] action in
            guard let self else { throw DictationActionError.notReady }
            try await self.perform(action)
        }
        foregroundSubscription = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.deliverPendingResult()
        }
        transcriptSubscription = controller.$partialText.dropFirst().sink { [weak self] text in
            guard let self, self.didBeginRecording, self.pendingResult == nil, !text.isEmpty else { return }
            self.liveActivity.update(phase: controller.phase == .recording ? .recording : .transcribing, elapsed: controller.elapsed, transcript: text)
        }
        #if canImport(UIKit)
        LocalScribeShortcuts.updateAppShortcutParameters()
        #endif
        logger.notice("Shortcut handler registered")
    }

    private func perform(_ action: DictationActionRuntime.Action) async throws {
        guard let controller else { throw DictationActionError.notReady }
        guard !handlingAction else { throw DictationActionError.busy }
        handlingAction = true
        defer { handlingAction = false }
        // Both shortcut activation and widget Stop deliberately foreground the app.
        // Never activate a microphone or submit ANE inference from a cold background intent.
        for _ in 0..<50 where UIApplication.shared.applicationState != .active {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard UIApplication.shared.applicationState == .active else { throw DictationActionError.notReady }
        logger.notice("Shortcut app ready in foreground")
        controller.setForeground(true)
        switch action {
        case .start:
            try await start(controller)
        case let .stop(expectedID):
            try await stop(controller, expectedID: expectedID)
        case .toggle:
            if activeSessionID == nil { try await start(controller) }
            else { try await stop(controller, expectedID: nil) }
        }
    }

    private func start(_ controller: AppController) async throws {
        guard activeSessionID == nil, controller.phase == .idle else { throw DictationActionError.busy }
        guard liveActivity.canStartRecordingActivity else {
            throw DictationActionError.failed("Enable Live Activities for LocalScribe in iPhone Settings to record through shortcuts. You can still record directly in LocalScribe.")
        }
        await controller.refreshInstalledModels()
        recordingActivityStarted = false
        activeSessionID = UUID()
        sessionModelName = controller.selectedModel.name
        pendingResult = nil
        didBeginRecording = false
        logger.notice("Shortcut microphone start requested")
        await controller.startActionButtonRecording()
        logger.notice("Shortcut start returned; recording=\(controller.phase == .recording, privacy: .public) activity=\(self.recordingActivityStarted, privacy: .public)")
        if controller.phase == .recording, !recordingActivityStarted {
            await controller.stopActionButtonRecording()
            activeSessionID = nil
            throw DictationActionError.failed("iOS could not start the recording Live Activity. Open LocalScribe to record directly, or check Live Activities in iPhone Settings.")
        }
        guard controller.phase == .recording, didBeginRecording else {
            activeSessionID = nil
            logger.error("Shortcut microphone capture did not start")
            throw DictationActionError.failed(controller.errorMessage ?? "Dictation could not start. Open Local Scribe to check microphone access and your selected model.")
        }
    }

    private func stop(_ controller: AppController, expectedID: UUID?) async throws {
        guard let id = activeSessionID, expectedID == nil || expectedID == id else { throw DictationActionError.noSession }
        if controller.phase == .recording { await controller.stopActionButtonRecording() }
        else if controller.phase == .transcribing {
            // A microphone interruption/backpressure stop may already be finishing.
            // Foreground activation releases the controller's inference pause.
            while activeSessionID == id && controller.phase == .transcribing {
                try await Task.sleep(for: .milliseconds(100))
            }
        } else if pendingResult != nil { deliverPendingResult() }
        else { throw DictationActionError.noSession }
        logger.notice("Shortcut stop completed")
        if controller.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DictationActionError.failed(controller.errorMessage ?? "No speech was recognized.")
        }
    }

    private func phaseChanged(_ phase: DictationPhase) {
        guard let controller, let id = activeSessionID else { return }
        logger.notice("Shortcut controller phase: \(String(describing: phase), privacy: .public)")
        switch phase {
        case .preparing: break
        case .recording:
            guard controller.actionButtonRecording, pendingResult == nil else { return }
            didBeginRecording = true
            let start = Date()
            recordingActivityStarted = liveActivity.start(sessionID: id, modelName: sessionModelName, startedAt: start, required: true)
        case .transcribing:
            guard didBeginRecording else { return }
            liveActivity.update(phase: .transcribing, elapsed: controller.elapsed)
        case .idle:
            guard didBeginRecording else { return }
            let text = controller.transcript
            didBeginRecording = false
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                liveActivity.finish(copied: false, elapsed: controller.elapsed)
                activeSessionID = nil
            } else {
                // Clipboard writes require foreground access. Preserve exactly this
                // completed session's value if a background interruption finished it.
                liveActivity.update(phase: .transcribing, elapsed: controller.elapsed, transcript: text)
                pendingResult = text
                pendingElapsed = controller.elapsed
                deliverPendingResult()
            }
        }
    }

    private func deliverPendingResult() {
        guard let text = pendingResult, UIApplication.shared.applicationState == .active else { return }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
        pendingResult = nil
        activeSessionID = nil
        liveActivity.finish(copied: true, elapsed: pendingElapsed, transcript: text)
        logger.notice("Shortcut result copied in foreground")
    }
}
