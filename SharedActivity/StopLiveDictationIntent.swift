import AppIntents
import Foundation
import OSLog

/// The app registers its handler at launch. LiveActivityIntent executes in that process;
/// an unregistered or stale session fails explicitly instead of pretending to stop audio.
@MainActor
enum DictationActionRuntime {
    /// Set by the caller only inside an active platform execution extension.
    enum CompletionExecution: Sendable, Equatable { case application, longRunningIntent }
    enum Action: Sendable {
        case start, startSession(sessionID: UUID), toggle
        case cancel(sessionID: UUID, reason: CancellationReason = .requested)
        case stop(sessionID: UUID?, progress: Progress? = nil, completionExecution: CompletionExecution = .application)
        case finish(sessionID: UUID, progress: Progress? = nil, completionExecution: CompletionExecution = .application)
    }
    enum CancellationReason: String, Sendable {
        case userCancelled, timeout, taskCancelled, requested, other

        #if os(iOS)
        @available(iOS 26.4, *)
        init(_ reason: IntentCancellationReason) {
            self = reason == .timeout ? .timeout : reason == .userCancelled ? .userCancelled : .other
        }
        #endif
    }
    typealias Handler = @MainActor @Sendable (Action) async throws -> String?
    static var handler: Handler?
    static var sessionIdentifier: (@MainActor @Sendable () -> UUID?)?
    private static let logger = Logger(subsystem: "com.devesh.localscribe.ios", category: "DictationShortcut")

    /// Platform cancellation belongs to an invocation, not the longer-lived
    /// recording/result. A delayed callback after Widget Stop must not discard
    /// the successfully retained result. Explicit session cancellation remains
    /// available through cancel(sessionID:reason:).
    @MainActor final class CancellationScope {
        private let sessionID: UUID
        private let state = DictationActionCancellationState()
        init(sessionID: UUID) { self.sessionID = sessionID }
        func perform(_ action: Action) async throws -> String? {
            do {
                let result = try await DictationActionRuntime.perform(action)
                try Task.checkCancellation()
                // The callback may have arrived before its MainActor cleanup
                // task. Never return output from that cancelled invocation.
                if let reason = state.complete() {
                    await DictationActionRuntime.cancel(sessionID: sessionID, reason: reason)
                    throw CancellationError()
                }
                return result
            } catch {
                if let reason = state.complete() {
                    await DictationActionRuntime.cancel(sessionID: sessionID, reason: reason)
                    throw CancellationError()
                }
                if error is CancellationError || Task.isCancelled {
                    await DictationActionRuntime.cancel(sessionID: sessionID, reason: .taskCancelled)
                    throw CancellationError()
                }
                throw error
            }
        }
        nonisolated func cancel(reason: CancellationReason) {
            // Claim cancellation on the callback's executor, before dispatching
            // cleanup, to preserve ordering across an occupied MainActor.
            guard state.requestCancellation(reason) else { return }
            Task { @MainActor in
                await DictationActionRuntime.cancel(sessionID: sessionID, reason: reason)
            }
        }
    }

    static func perform(_ action: Action) async throws -> String? {
        logger.notice("Shortcut intent perform entered")
        // A background intent can arrive while SwiftUI is constructing AppContext.
        // Wait briefly for registration; never construct a second recorder/model engine.
        for _ in 0..<50 where handler == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let handler else {
            logger.error("Shortcut app handler unavailable")
            throw DictationActionError.notReady
        }
        let sessionID: UUID?
        let operation: Action
        switch action {
        case .start:
            let id = UUID()
            sessionID = id
            operation = .startSession(sessionID: id)
        case let .startSession(id):
            sessionID = id
            operation = action
        case let .stop(expectedID, progress, execution):
            sessionID = expectedID ?? sessionIdentifier?()
            operation = .stop(sessionID: sessionID, progress: progress, completionExecution: execution)
        case let .finish(id, _, _):
            sessionID = id
            operation = action
        case .toggle:
            if let id = sessionIdentifier?() {
                sessionID = id
                operation = .stop(sessionID: id)
            } else {
                let id = UUID()
                sessionID = id
                operation = .startSession(sessionID: id)
            }
        case let .cancel(id, _):
            sessionID = id
            operation = action
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                let result = try await handler(operation)
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            guard let sessionID else { return }
            Task { @MainActor in await cancel(sessionID: sessionID, reason: .taskCancelled) }
        }
    }
    static func cancel(sessionID: UUID, reason: CancellationReason = .requested) async {
        logger.notice("Shortcut cancellation: \(reason.rawValue, privacy: .public)")
        _ = try? await handler?(.cancel(sessionID: sessionID, reason: reason))
    }
}

/// Synchronizes the platform callback with completion; holds no transcript.
private final class DictationActionCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var cancellation: DictationActionRuntime.CancellationReason?
    func requestCancellation(_ reason: DictationActionRuntime.CancellationReason) -> Bool {
        lock.withLock {
            guard !completed else { return false }
            cancellation = reason
            return true
        }
    }
    func complete() -> DictationActionRuntime.CancellationReason? {
        lock.withLock {
            completed = true
            return cancellation
        }
    }
}

enum DictationActionError: LocalizedError {
    case notReady, noSession, busy, failed(String)
    var errorDescription: String? {
        switch self {
        case .notReady: "Open Local Scribe and try again."
        case .noSession: "This dictation session has ended."
        case .busy: "Local Scribe is finishing dictation."
        case let .failed(message): message
        }
    }
}

struct StopLiveDictationIntent: LiveActivityIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "Stop and Copy Dictation"
    static let description = IntentDescription("Finish this recording in the background. Your transcript is available in LocalScribe.")
    static let openAppWhenRun = false
    static let isDiscoverable = false
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Session") var sessionIdentifier: String

    init() { sessionIdentifier = "" }
    init(sessionID: UUID) { sessionIdentifier = sessionID.uuidString }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let sessionID = UUID(uuidString: sessionIdentifier) else { throw DictationActionError.noSession }
        #if os(iOS)
        if #available(iOS 27.0, *) {
            progress.totalUnitCount = 1
            let cancellation = await MainActor.run { DictationActionRuntime.CancellationScope(sessionID: sessionID) }
            let text = try await performBackgroundTask {
                let result = try await cancellation.perform(.finish(sessionID: sessionID, progress: progress, completionExecution: .longRunningIntent))
                return result
            } onCancel: { reason in
                cancellation.cancel(reason: .init(reason))
            }
            return .result(value: text ?? "")
        }
        #endif
        let text = try await DictationActionRuntime.perform(.finish(sessionID: sessionID))
        return .result(value: text ?? "")
    }
}

#if os(iOS)
@available(iOS 27.0, *)
extension StopLiveDictationIntent: LongRunningIntent, CancellableIntent {}
#endif
