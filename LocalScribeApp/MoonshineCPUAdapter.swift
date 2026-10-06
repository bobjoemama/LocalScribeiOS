#if canImport(MoonshineVoice)
import Foundation
import LocalScribeCore
import MoonshineVoice

/// Owns the official native runtime on a serial executor. No microphone or
/// model-discovery API is used; all inference consumes the app's bounded PCM.
actor MoonshineCPUAdapter {
    private var transcriber: Transcriber?
    private var stream: MoonshineVoice.Stream?
    private var pendingSamples = 0
    private var latest = Transcript()

    init(directory: URL) throws {
        transcriber = try Transcriber(modelPath: directory.path, modelArch: .smallStreaming,
            options: [TranscriberOption(name: "ort_providers", value: "cpu"),
                      TranscriberOption(name: "return_audio_data", value: "false"),
                      TranscriberOption(name: "log_output_text", value: "false"),
                      TranscriberOption(name: "vad_max_segment_duration", value: "30")])
    }
    func begin() throws {
        try Task.checkCancellation()
        cancel()
        guard let transcriber else { throw ModelInstallationError.missingModel }
        // Updates are explicit so native failures propagate instead of being
        // swallowed by event handlers or Stream.stop's final update.
        let value = try transcriber.createStream(updateInterval: 3600)
        try value.start()
        stream = value
        latest = Transcript()
        pendingSamples = 0
    }
    func append(_ samples: [Float]) throws -> SpeechTranscriptUpdate? {
        try Task.checkCancellation()
        guard let stream else { throw ModelInstallationError.missingModel }
        try stream.addAudio(samples, sampleRate: 16_000)
        pendingSamples += samples.count
        guard pendingSamples >= 8_000 else { return nil }
        latest = try stream.updateTranscription()
        pendingSamples = 0
        try Task.checkCancellation()
        return Self.update(latest)
    }
    func finish() throws -> String {
        try Task.checkCancellation()
        guard let stream else { throw ModelInstallationError.missingModel }
        defer { cancel() }
        try stream.stop()
        latest = try stream.updateTranscription(flags: TranscribeStreamFlags.flagForceUpdate)
        try Task.checkCancellation()
        return latest.lines.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func transcribe(_ samples: [Float]) throws -> String {
        try begin()
        defer { cancel() }
        for offset in stride(from: 0, to: samples.count, by: 32_000) {
            _ = try append(Array(samples[offset..<min(samples.count, offset + 32_000)]))
        }
        return try finish()
    }
    func cancel() {
        // Stream and Transcriber close() are also called by their deinits;
        // release ownership once rather than explicitly freeing twice.
        stream = nil
        latest = Transcript()
        pendingSamples = 0
    }
    func unload() {
        cancel()
        transcriber = nil
    }
    private static func update(_ transcript: Transcript) -> SpeechTranscriptUpdate {
        .init(confirmedText: transcript.lines.filter(\.isComplete).map(\.text).joined(separator: " "),
              volatileText: transcript.lines.filter { !$0.isComplete }.map(\.text).joined(separator: " "))
    }
}
#endif
