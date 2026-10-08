import Foundation

public enum SpeechModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case parakeetPhonon, parakeetPhononG4, parakeetPhononG1, parakeetPhononLUT6, parakeetPhononLUT3, moonshineSmall, parakeetUltra, parakeetRedux, parakeetRealtimeEOU
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .parakeetUltra: "Parakeet Ultra"
        case .parakeetPhonon: "Phonon-2"
        case .parakeetPhononG4: "Phonon-2 · compact"
        case .parakeetPhononG1: "Phonon-2 · smallest"
        case .parakeetPhononLUT6: "Phonon-2 · dense 6-bit"
        case .parakeetPhononLUT3: "Phonon-2 · dense 3-bit GPU"
        case .moonshineSmall: "Moonshine Small"
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
        case .parakeetPhononLUT6: "About 507 MB"
        case .parakeetPhononLUT3: "About 290 MB"
        case .moonshineSmall: "About 142 MB"
        case .parakeetRedux: "About 220 MB"
        case .parakeetRealtimeEOU: "About 224 MB"
        }
    }
    public var languages: String { [.parakeetPhonon, .parakeetPhononG4, .parakeetPhononG1, .parakeetPhononLUT6, .parakeetPhononLUT3, .moonshineSmall, .parakeetRealtimeEOU].contains(self) ? "English" : "25 European languages" }
    public var detail: String {
        switch self {
        case .parakeetUltra: "A larger local engine to compare for recognition quality. On-demand in-app execution requests CPU and Neural Engine. Keep model loaded prepares the same files on CPU for Dictate and Action Button."
        case .parakeetPhonon: "Native Core ML English dictation. Compare speed and memory on your iPhone."
        case .parakeetPhononG4: "The same learned weights in a smaller encoder graph. Measure the storage and speed tradeoff."
        case .parakeetPhononG1: "The smallest exact-weight Phonon-2 graph. May prepare and transcribe more slowly."
        case .parakeetPhononLUT6: "Dense 6-bit encoder. On-demand in-app execution requests CPU and Neural Engine. Keep model loaded prepares the same files on CPU for Dictate and Action Button. Compare speed and memory on your iPhone."
        case .parakeetPhononLUT3: "On-demand in-app encoder requests CPU and GPU. Keep model loaded prepares the same files on CPU for Dictate and Action Button."
        case .moonshineSmall: "English streaming recognition with cached audio state and CPU execution. Text updates throughout recording."
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

/// Processor requirements are frozen when a recording starts.
public enum ModelExecutionContext: String, Codable, Sendable {
    case foreground, backgroundCapable

    /// These runtimes use the same CPU configuration in either context.
    public func normalized(for model: SpeechModel) -> Self {
        model == .parakeetRealtimeEOU || model == .moonshineSmall ? .foreground : self
    }
}

/// Loads the selected model with explicit processor requirements, without
/// granting background execution time or changing the selected model files.
public protocol ContextualLocalTranscriptionEngine: LocalTranscriptionEngine {
    func prepare(_ model: SpeechModel, context: ModelExecutionContext) async throws
    func supportsBackgroundInference(for model: SpeechModel, context: ModelExecutionContext) async -> Bool
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
    public var isEnabled: Bool
    public init(id: UUID = UUID(), heard: String, replacement: String, isEnabled: Bool = true) {
        self.id = id; self.heard = heard; self.replacement = replacement; self.isEnabled = isEnabled
    }
    private enum CodingKeys: String, CodingKey { case id, heard, replacement, isEnabled }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        heard = try values.decode(String.self, forKey: .heard)
        replacement = try values.decode(String.self, forKey: .replacement)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

public enum TranscriptCorrection {
    /// Kept for existing callers. Longest literal whole-phrase matches apply once.
    public static func apply(_ rules: [DictionaryRule], to text: String) -> String {
        TranscriptPersonalizer(dictionary: rules, snippets: []).apply(text)
    }
}
