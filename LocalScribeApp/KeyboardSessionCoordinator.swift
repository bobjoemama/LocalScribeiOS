import Combine
import Foundation

/// Bridges the keyboard to the already-authorized audio session in the containing app.
/// This never launches the app or arms its microphone in response to an extension command.
@MainActor
final class KeyboardSessionCoordinator {
    private weak var controller: AppController?
    private let store: SharedKeyboardStore?
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var sessionID: UUID?
    private var expiresAt: Date?
    private var deliveryExpiresAt: Date?
    private var expirationRequested = false
    private var utteranceID: UUID?
    private var result: String?
    private var sawRecording = false
    private var lastPublishedAt = Date.distantPast
    private var processedCommands = Set<UUID>()
    private var handlingCommand = false
    private var storageFailed = false
    private var revision = UUID()

    init(controller: AppController, store: SharedKeyboardStore? = try? SharedKeyboardStore.appGroupStore()) {
        self.controller = controller
        self.store = store
        subscription = controller.$keyboardSessionExpiresAt.sink { [weak self] expiration in
            self?.sessionChanged(expiration)
        }
        controller.onDictationFinished = { [weak self] in self?.dictationFinished() }
        publish()
    }

    private func sessionChanged(_ expiration: Date?, preserveResult: Bool = true) {
        if storageFailed {
            if expiration != nil { revokeFailedSession() }
            return
        }
        guard expiration != expiresAt else { return }
        if let expiration, let previous = expiresAt, sessionID != nil,
           previous > Date() || controller?.phase == .recording {
            // Activity extends the existing microphone lease. Keep utterance IDs,
            // receipts and pending results valid instead of creating a new session.
            expiresAt = expiration
            expirationRequested = false
            publish()
            return
        }
        if expiration == nil, preserveResult, sessionID != nil, let controller,
           result != nil || (controller.phase == .transcribing && (sawRecording || handlingCommand)) {
            // The microphone has already stopped. Keep only a bounded result-delivery lease.
            expiresAt = Date()
            deliveryExpiresAt = result == nil ? Date().addingTimeInterval(120) : min(deliveryExpiresAt ?? .distantFuture, Date().addingTimeInterval(30))
            expirationRequested = true
            publish()
            return
        }
        if expiration != nil && store == nil {
            failStorage()
            return
        }
        revision = UUID()
        timer?.invalidate()
        timer = nil
        expiresAt = expiration
        deliveryExpiresAt = nil
        expirationRequested = false
        sessionID = expiration == nil ? nil : UUID()
        utteranceID = nil
        result = nil
        sawRecording = false
        processedCommands.removeAll()
        if expiration != nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
        publish()
    }

    private func tick() {
        guard !storageFailed, let controller, let expiresAt else { return }
        if let deliveryExpiresAt, deliveryExpiresAt <= Date() {
            result = nil
            utteranceID = nil
            sawRecording = false
            self.deliveryExpiresAt = nil
            if expiresAt <= Date() {
                sessionChanged(nil, preserveResult: false)
                return
            }
        }
        if expiresAt <= Date(), deliveryExpiresAt == nil, !expirationRequested {
            expirationRequested = true
            Task { @MainActor [weak self, weak controller] in
                guard let controller else { return }
                await controller.finishKeyboardSession()
                self?.tick()
            }
            return
        }
        // A consumed result is overwritten rather than retained as a dictation archive.
        if let utteranceID, let receipt = try? store?.readReceipt(), receipt.utteranceID == utteranceID {
            result = nil
            sawRecording = false
            self.utteranceID = nil
            deliveryExpiresAt = nil
            if expiresAt <= Date() {
                sessionChanged(nil, preserveResult: false)
                return
            }
        }
        // Capture a result produced by an app interruption as well as a keyboard stop.
        if utteranceID != nil {
            if sawRecording && controller.phase == .idle && !handlingCommand {
                sawRecording = false
                if !controller.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    acceptResult(controller.transcript)
                }
            }
        }
        if Date().timeIntervalSince(lastPublishedAt) >= 0.5 { publish() }
        guard !storageFailed, !handlingCommand, let command = try? store?.readCommand(),
              !processedCommands.contains(command.id), let status = currentStatus(),
              command.isValid(for: status) else { return }
        processedCommands.insert(command.id)
        // Keep command IDs bounded even during a deliberately rapid series of recordings.
        if processedCommands.count > 512 { processedCommands = [command.id] }
        switch command.action {
        case .start:
            guard controller.phase == .idle, result == nil else { return }
            utteranceID = command.utteranceID
            result = nil
            sawRecording = false
            publish()
            guard !storageFailed else { return }
        case .stop, .cancel:
            guard controller.phase == .recording, utteranceID == command.utteranceID else { return }
        }
        handlingCommand = true
        let commandRevision = revision
        Task { @MainActor [weak self, weak controller] in
            guard let self, let controller, !self.storageFailed, self.revision == commandRevision else { return }
            if command.action == .start {
                await controller.startRecording()
                if self.revision == commandRevision && controller.phase == .recording {
                    self.sawRecording = true
                }
            } else if command.action == .cancel {
                // Clear ownership before publishing idle so no discarded speech
                // can be delivered by the completion callback or polling fallback.
                self.sawRecording = false
                self.result = nil
                self.utteranceID = nil
                self.deliveryExpiresAt = nil
                await controller.cancelRecording()
            } else {
                await controller.stopRecording()
            }
            self.handlingCommand = false
            self.publish()
        }
    }

    private func currentStatus() -> KeyboardSessionStatus? {
        guard let controller else { return nil }
        let phase: KeyboardSessionPhase
        if sessionID == nil {
            phase = .inactive
        } else if controller.errorMessage != nil {
            phase = .failed
        } else {
            switch controller.phase {
            case .idle: phase = .ready
            case .preparing, .transcribing: phase = .transcribing
            case .recording: phase = .recording
            }
        }
        return KeyboardSessionStatus(sessionID: sessionID, expiresAt: expiresAt, deliveryExpiresAt: deliveryExpiresAt, phase: phase,
                                     utteranceID: utteranceID, transcript: result,
                                     message: controller.errorMessage)
    }

    private func acceptResult(_ text: String) {
        result = text
        deliveryExpiresAt = min(deliveryExpiresAt ?? .distantFuture, Date().addingTimeInterval(30))
    }

    /// Called before the app releases its finite transcription background task.
    /// A timer after suspension is not a reliable way to publish the finished words.
    private func dictationFinished() {
        guard !storageFailed, let controller, sawRecording, utteranceID != nil else { return }
        sawRecording = false
        if !controller.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            acceptResult(controller.transcript)
        }
        publish()
    }

    private func publish() {
        guard !storageFailed, let status = currentStatus() else { return }
        // An unconfigured optional keyboard must not block ordinary app dictation.
        // Report missing shared access only when the user actually arms a session.
        guard let store else {
            if sessionID != nil || controller?.keyboardSessionActive == true { failStorage() }
            return
        }
        do {
            try store.writeStatus(status)
            lastPublishedAt = Date()
        } catch {
            failStorage()
        }
    }

    /// Failure is terminal for this coordinator. Never try to persist a failure status into
    /// the same broken store, including from synchronous @Published subscription callbacks.
    private func failStorage() {
        guard !storageFailed else { return }
        storageFailed = true
        revision = UUID()
        timer?.invalidate()
        timer = nil
        sessionID = nil
        expiresAt = nil
        deliveryExpiresAt = nil
        expirationRequested = false
        utteranceID = nil
        result = nil
        sawRecording = false
        handlingCommand = false
        processedCommands.removeAll()
        revokeFailedSession()
    }

    private func revokeFailedSession() {
        controller?.errorMessage = "Keyboard shared access failed. Reopen Local Scribe after checking App Group access. Continue dictating in the app."
        // @Published invokes the sink before assigning the new expiry. Defer revocation
        // until that assignment completes, so a failed arm cannot overwrite nil again.
        Task { @MainActor [weak controller] in
            await controller?.finishKeyboardSession()
        }
    }

    isolated deinit { timer?.invalidate() }
}
