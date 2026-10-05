import Foundation

public enum SpeechModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case parakeetPhonon, parakeetPhononG4, parakeetPhononG1, parakeetUltra, parakeetRedux, parakeetRealtimeEOU
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .parakeetUltra: "Parakeet Ultra"
        case .parakeetPhonon: "Phonon-2"
        case .parakeetPhononG4: "Phonon-2 · compact"
        case .parakeetPhononG1: "Phonon-2 · smallest"
        case .parakeetRedux: "Parakeet Redux"
        case .parakeetRealtimeEOU: "Parakeet Realtime"
        }
    }
    public var downloadSize: String {
        switch self {
        case .parakeetUltra: "About 632 MB"
        case .parakeetPhonon: "About 358 MB"
        case .parakeetPhononG4: "About 284 MB"
        case .parakeetPhononG1: "About 213 MB"
        case .parakeetRedux: "About 220 MB"
        case .parakeetRealtimeEOU: "About 224 MB"
        }
    }
    public var languages: String { [.parakeetPhonon, .parakeetPhononG4, .parakeetPhononG1, .parakeetRealtimeEOU].contains(self) ? "English" : "25 European languages" }
    public var detail: String {
        switch self {
        case .parakeetUltra: "A larger local engine to compare for recognition quality. CPU and Neural Engine execution requested."
        case .parakeetPhonon: "Native Core ML English dictation. Compare speed and memory on your iPhone."
        case .parakeetPhononG4: "The same learned weights in a smaller encoder graph. Measure the storage and speed tradeoff."
        case .parakeetPhononG1: "The smallest exact-weight Phonon-2 graph. May prepare and transcribe more slowly."
        case .parakeetRedux: "A compact download with multilingual speech recognition."
        case .parakeetRealtimeEOU: "Streaming with cached audio state and frequent text updates. English text has no automatic punctuation."
        }
    }
}

public enum DictationPhase: Equatable, Sendable {
    case idle, preparing, recording, transcribing
}

public protocol LocalTranscriptionEngine: AnyObject, Sendable {
    func isInstalled(_ model: SpeechModel) async -> Bool
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Load installed files only. Missing files must throw; dictation must never download.
    func prepare(_ model: SpeechModel) async throws
    /// Mono, 16 kHz PCM samples. Recognition must stay on device.
    func transcribe(samples: [Float]) async throws -> String
    /// Release loaded inference state without removing installed model files.
    func unload() async
}

public extension LocalTranscriptionEngine {
    func unload() async {}
}

/// Reports a runtime capability for its actual configuration of this model.
/// Hardware eligibility does not grant iOS background execution time or audio
/// session permission. Engines without this capability are foreground-only.
public protocol BackgroundInferenceReportingEngine: LocalTranscriptionEngine {
    func supportsBackgroundInference(for model: SpeechModel) async -> Bool
}

public enum ModelPreparationStage: String, Codable, Sendable {
    case checkingInstallation, verifyingFiles, loadingCoreML, initializingRecognizer, ready
}

public protocol ModelPreparationReportingEngine: LocalTranscriptionEngine {
    func preparationStage() async -> ModelPreparationStage?
}

/// A complete current snapshot. Replacing this snapshot avoids duplicating words
/// when the recognizer revises the boundary between confirmed and provisional text.
public struct SpeechTranscriptUpdate: Equatable, Sendable {
    public let confirmedText: String
    public let volatileText: String
    public init(confirmedText: String, volatileText: String) {
        self.confirmedText = confirmedText
        self.volatileText = volatileText
    }
    public var text: String {
        [confirmedText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public protocol StreamingLocalTranscriptionEngine: LocalTranscriptionEngine {
    /// Begin one utterance using the already-prepared model; never download.
    func beginStreaming(onUpdate: @escaping @Sendable (SpeechTranscriptUpdate) -> Void) async throws
    /// Supply ordered mono 16 kHz PCM in batches of at most 32,000 samples.
    /// Await each call before sending another. Completion acknowledges processing,
    /// or bounded retention until enough context is available; audio is never dropped.
    func appendStreaming(samples: [Float]) async throws
    /// Flush all admitted audio and return the complete deduplicated utterance.
    func finishStreaming() async throws -> String
    /// Cancel the utterance and settle inference before reusing its loaded model.
    func cancelStreaming() async
}

public struct TranscriptEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var text: String
    public let model: SpeechModel
    public let duration: TimeInterval

    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String, model: SpeechModel, duration: TimeInterval) {
        self.id = id; self.createdAt = createdAt; self.text = text; self.model = model; self.duration = duration
    }
}

public struct DictionaryRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var heard: String
    public var replacement: String
    public init(id: UUID = UUID(), heard: String, replacement: String) {
        self.id = id; self.heard = heard; self.replacement = replacement
    }
}

public enum TranscriptCorrection {
    /// Replace whole phrases once, longest first, without changing substrings or reprocessing replacements.
    public static func apply(_ rules: [DictionaryRule], to text: String) -> String {
        let valid = rules.filter { !$0.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.heard.count > $1.heard.count }
        guard !valid.isEmpty else { return text }
        let patterns = valid.map { NSRegularExpression.escapedPattern(for: $0.heard.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])(?:" + patterns.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])", options: .caseInsensitive) else { return text }
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let heard = source.substring(with: match.range)
            if let rule = valid.first(where: { $0.heard.trimmingCharacters(in: .whitespacesAndNewlines).compare(heard, options: .caseInsensitive) == .orderedSame }) {
                result.replaceCharacters(in: match.range, with: rule.replacement)
            }
        }
        return result as String
    }
}
