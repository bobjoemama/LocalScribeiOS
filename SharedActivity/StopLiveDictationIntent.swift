import AppIntents
import Foundation
import OSLog

/// The app registers its handler at launch. LiveActivityIntent executes in that process;
/// an unregistered or stale session fails explicitly instead of pretending to stop audio.
@MainActor
enum DictationActionRuntime {
    enum Action: Sendable { case start, stop(sessionID: UUID?), toggle }
    typealias Handler = @MainActor @Sendable (Action) async throws -> Void
    static var handler: Handler?
    private static let logger = Logger(subsystem: "com.devesh.localscribe.ios", category: "DictationShortcut")

    static func perform(_ action: Action) async throws {
        logger.notice("Shortcut intent perform entered")
        // A foreground intent can arrive while SwiftUI is constructing AppContext.
        // Wait briefly for registration; never construct a second recorder/model engine.
        for _ in 0..<50 where handler == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let handler else {
            logger.error("Shortcut app handler unavailable")
            throw DictationActionError.notReady
        }
        try await handler(action)
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
    static let description = IntentDescription("Open Local Scribe, finish this recording on your iPhone, and copy the transcript.")
    static let openAppWhenRun = true
    static let isDiscoverable = false
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Session") var sessionIdentifier: String

    init() { sessionIdentifier = "" }
    init(sessionID: UUID) { sessionIdentifier = sessionID.uuidString }

    func perform() async throws -> some IntentResult {
        guard let sessionID = UUID(uuidString: sessionIdentifier) else { throw DictationActionError.noSession }
        try await DictationActionRuntime.perform(.stop(sessionID: sessionID))
        return .result()
    }
}
