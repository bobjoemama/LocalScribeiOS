import AppIntents
import Foundation
import OSLog

/// The app registers its handler at launch. LiveActivityIntent executes in that process;
/// an unregistered or stale session fails explicitly instead of pretending to stop audio.
@MainActor
enum DictationActionRuntime {
    enum Action: Sendable { case start, startSession(sessionID: UUID), stop(sessionID: UUID?, progress: Progress? = nil), toggle, cancel(sessionID: UUID) }
    typealias Handler = @MainActor @Sendable (Action) async throws -> String?
    static var handler: Handler?
    static var sessionIdentifier: (@MainActor @Sendable () -> UUID?)?
    private static let logger = Logger(subsystem: "com.devesh.localscribe.ios", category: "DictationShortcut")

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
        case let .stop(expectedID, progress):
            sessionID = expectedID ?? sessionIdentifier?()
            operation = .stop(sessionID: sessionID, progress: progress)
        case .toggle:
            if let id = sessionIdentifier?() {
                sessionID = id
                operation = .stop(sessionID: id)
            } else {
                let id = UUID()
                sessionID = id
                operation = .startSession(sessionID: id)
            }
        case let .cancel(id):
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
            Task { @MainActor in await cancel(sessionID: sessionID) }
        }
    }
    static func cancel(sessionID: UUID) async {
        _ = try? await handler?(.cancel(sessionID: sessionID))
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
    static let description = IntentDescription("Finish this recording on your iPhone in the background and copy the transcript.")
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
            let text = try await performBackgroundTask {
                let result = try await DictationActionRuntime.perform(.stop(sessionID: sessionID, progress: progress))
                return result
            } onCancel: { _ in
                Task { @MainActor in await DictationActionRuntime.cancel(sessionID: sessionID) }
            }
            return .result(value: text ?? "")
        }
        #endif
        let text = try await DictationActionRuntime.perform(.stop(sessionID: sessionID))
        return .result(value: text ?? "")
    }
}

#if os(iOS)
@available(iOS 27.0, *)
extension StopLiveDictationIntent: LongRunningIntent, CancellableIntent {}
#endif
