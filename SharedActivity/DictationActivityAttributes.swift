import ActivityKit
import Foundation

struct DictationActivityAttributes: ActivityAttributes, Sendable {
    enum Phase: String, Codable, Hashable, Sendable { case recording, transcribing, ready, failed }
    struct ContentState: Codable, Hashable, Sendable {
        var phase: Phase
        var elapsed: TimeInterval
        var message: String?
        var transcriptTail: String? = nil
    }
    let sessionID: UUID
    let startedAt: Date
    let modelName: String
}
