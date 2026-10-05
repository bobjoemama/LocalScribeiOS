#if DEBUG
import AVFAudio
import CryptoKit
import Darwin
import Foundation
import LocalScribeCore
import UIKit

/// Explicit developer verification. Hardware PCM is counted and discarded by a
/// no-op engine; only the pinned public fixture reaches the real speech engine.
@MainActor
struct RecordingVerificationRunner {
    private let models: [SpeechModel]
    private let verifyLongMicrophone: Bool
    init?(arguments: [String]) throws {
        guard arguments.contains("--verify-dictation") else { return nil }
        guard !arguments.contains("--benchmark-models") else { throw VerificationError("Run verification and benchmarking separately") }
        verifyLongMicrophone = arguments.contains("--verify-long-microphone")
        let values: [String]
        if let index = arguments.firstIndex(of: "--verify-models") {
            guard index + 1 < arguments.count else { throw VerificationError("--verify-models requires comma-separated IDs") }
            values = arguments[index + 1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        } else { values = ["phonon2"] }
        guard !values.isEmpty, values.count <= 6, Set(values).count == values.count else { throw VerificationError("Use distinct verification model IDs") }
        models = try values.map {
            switch $0 {
            case "phonon2": .parakeetPhonon
            case "phonon2-g4": .parakeetPhononG4
            case "phonon2-g1": .parakeetPhononG1
            case "ultra": .parakeetUltra
            case "redux": .parakeetRedux
            case "eou320", "parakeet-eou-320ms": .parakeetRealtimeEOU
            default: throw VerificationError("Unknown verification model: \($0)")
            }
        }
    }

    func run(engine: any LocalTranscriptionEngine, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        let fixture = try loadFixture()
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let output = documents.appendingPathComponent("dictation-verification-\(UUID().uuidString).json")
        let activity = VerificationActivity()
        var report = Report(startedAt: Date(), completedAt: nil, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                            lowPowerModeEnabledAtStart: ProcessInfo.processInfo.isLowPowerModeEnabled,
                            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                            buildOptimization: Bundle.main.object(forInfoDictionaryKey: "LocalScribeOptimizationLevel") as? String ?? "unknown",
                            status: "waitingForActiveHardwareTest", hardware: nil, longMicrophone: nil, models: [], lifecycle: activity.snapshot())
        try checkpoint(report, to: output, activity: activity)
        try await activity.waitUntilActive()
        progress("Checking the microphone for five seconds. Captured sound is discarded.")
        report.status = "hardwareCaptureWithWithheldNoOpPreparation"
        try checkpoint(report, to: output, activity: activity)
        report.hardware = await checkHardwareAndStop(activity: activity)
        try checkpoint(report, to: output, activity: activity)
        if verifyLongMicrophone {
            try await activity.waitUntilActive()
            progress("Checking microphone capture for 125 seconds. Captured sound is discarded.")
            report.status = "longHardwareCaptureWithReadyNoOpEngine"
            try checkpoint(report, to: output, activity: activity)
            report.longMicrophone = await checkLongMicrophone(activity: activity)
            try checkpoint(report, to: output, activity: activity)
        }
        guard let streaming = engine as? any StreamingLocalTranscriptionEngine else {
            throw VerificationError("The real engine does not implement streaming")
        }
        for model in models {
            try Task.checkCancellation()
            try await activity.waitUntilActive()
            var result = ModelResult(model: model, status: "checkingInstallation", preparation: nil,
                                     preparationTimingValid: nil, enginePreparationReport: nil, shortStream: nil, longStream: nil, seamVariants: [], error: nil)
            report.models.append(result)
            let index = report.models.count - 1
            report.status = "checking-\(model.rawValue)"
            try checkpoint(report, to: output, activity: activity)
            do {
                guard await engine.isInstalled(model) else { throw VerificationError("Model is not installed; verification never downloads it") }
                await engine.unload()
                try await activity.waitUntilActive()
                progress("Loading \(model.name) for public fixture verification")
                result.status = "preparing"
                report.models[index] = result
                try checkpoint(report, to: output, activity: activity)
                let initialActivity = activity.snapshot()
                let preparation = await PerformanceProbe.start()
                do {
                    try await engine.prepare(model)
                    result.preparation = await preparation.finish()
                } catch {
                    result.preparation = await preparation.finish()
                    throw error
                }
                if let reporting = engine as? any PerformanceReportingEngine {
                    result.enginePreparationReport = await reporting.performanceReports().last(where: { $0.model == model && $0.stage == .modelLoad })
                }
                result.preparationTimingValid = activity.validSince(initialActivity)
                result.status = "shortPublicFixture"
                report.models[index] = result
                try checkpoint(report, to: output, activity: activity)
                progress("\(model.name): short public speech fixture")
                result.shortStream = await checkStream(streaming, fixture: fixture, variant: .short, activity: activity)
                result.status = "longPublicFixture"
                report.models[index] = result
                try checkpoint(report, to: output, activity: activity)
                progress("\(model.name): 128.81 seconds of public speech, supplied in bounded chunks")
                result.longStream = await checkStream(streaming, fixture: fixture, variant: .baseline, activity: activity)
                for variant in [FixtureVariant.prefixShifted, .gapped] {
                    result.status = "publicFixture-\(variant.id)"
                    report.models[index] = result
                    try checkpoint(report, to: output, activity: activity)
                    progress("\(model.name): public fixture with \(variant.id) boundaries")
                    result.seamVariants.append(await checkStream(streaming, fixture: fixture, variant: variant, activity: activity))
                }
                result.status = result.shortStream?.passed == true && result.longStream?.passed == true
                    && result.seamVariants.allSatisfy(\.passed) ? "passed" : "failed"
            } catch {
                result.status = "failed"; result.error = error.localizedDescription
                if let reporting = engine as? any PerformanceReportingEngine {
                    result.enginePreparationReport = await reporting.performanceReports().last(where: { $0.model == model && $0.stage == .modelLoad })
                }
            }
            await streaming.cancelStreaming()
            await engine.unload()
            report.models[index] = result
            try checkpoint(report, to: output, activity: activity)
        }
        report.completedAt = Date()
        report.status = report.hardware?.passed == true && (!verifyLongMicrophone || report.longMicrophone?.passed == true) && report.models.allSatisfy({ $0.status == "passed" }) ? "passed" : "failed"
        try checkpoint(report, to: output, activity: activity)
        progress("Verification \(report.status): \(output.lastPathComponent)")
        return output
    }

    private func checkHardwareAndStop(activity: VerificationActivity) async -> HardwareResult {
        let engine = WithheldPreparationEngine()
        let suite = UserDefaults(suiteName: "LocalScribeVerification-\(UUID().uuidString)")!
        suite.register(defaults: ["selectedModel": SpeechModel.parakeetPhonon.rawValue, "saveHistory": false])
        let isolatedHistory = FileManager.default.temporaryDirectory.appendingPathComponent("Verification-\(UUID().uuidString)/history.json")
        // This fixture controller must permit its actual Record path. The normal
        // app controller stays in verificationMode and never touches this engine.
        let controller = AppController(engine: engine, defaults: suite, historyURL: isolatedHistory, verificationMode: false)
        let before = activity.snapshot()
        let probe = await PerformanceProbe.start()
        var recordingStarted = false
        var pendingWhenStopped = false
        var stopEnteredFinalization = false
        var captureStopped = false
        var failure: String?
        var snapshot: CaptureBufferSnapshot?
        var stopTask: Task<Void, Never>?
        do {
            await controller.refreshInstalledModels()
            await controller.startRecording()
            recordingStarted = controller.phase == .recording
            guard recordingStarted else { throw VerificationError(controller.errorMessage ?? "Record did not enter recording") }
            let start = ContinuousClock.now
            while start.duration(to: .now) < .seconds(5) {
                try Task.checkCancellation()
                guard UIApplication.shared.applicationState == .active else { throw VerificationError("App left the foreground during microphone verification") }
                try await Task.sleep(for: .milliseconds(100))
            }
            pendingWhenStopped = await engine.isPreparationPending()
            stopTask = Task { await controller.stopRecording() }
            try await Task.sleep(for: .milliseconds(100))
            stopEnteredFinalization = controller.phase == .transcribing
            snapshot = controller.verificationCaptureSnapshot
            captureStopped = snapshot?.generation == nil
            await engine.releasePreparation()
            await stopTask?.value
            guard controller.phase == .idle else { throw VerificationError("Stop did not settle to idle after releasing fixture preparation") }
        } catch { failure = error.localizedDescription }
        // Always settle this no-op engine and hardware recorder; no raw samples
        // leave the fixture controller and no transcript/history is generated.
        await engine.releasePreparation()
        if controller.phase == .recording { await controller.stopRecording() }
        await stopTask?.value
        controller.disableKeyboardSession()
        controller.setForeground(false)
        let counters = await engine.counters()
        let resources = await probe.finish()
        let valid = activity.validSince(before)
        let captured = snapshot?.receivedSamples ?? counters.samples
        let passed = recordingStarted && pendingWhenStopped && stopEnteredFinalization && captureStopped
            && controller.phase == .idle && captured > 0 && counters.samples == captured
            && counters.maximumChunkSamples <= 32_000 && counters.finished == 1
            && snapshot?.overflowSamples == 0 && snapshot?.processingFailureCount == 0
            && controller.history.isEmpty && controller.rawTranscript.isEmpty && valid && failure == nil
        return HardwareResult(passed: passed, recordingStarted: recordingStarted,
            preparationWithheldAtStop: pendingWhenStopped, stopEnteredFinalization: stopEnteredFinalization,
            captureStoppedBeforePreparationReleased: captureStopped, settledToIdle: controller.phase == .idle,
            capturedSamples: captured, samplesIgnoredByNoOpEngine: counters.samples,
            maximumFinalizationChunkSamples: counters.maximumChunkSamples,
            overflowSamples: snapshot?.overflowSamples, conversionFailures: snapshot?.processingFailureCount,
            hardwareAudioTranscribed: false, hardwareAudioSaved: false, timingValid: valid, resources: resources, error: failure)
    }

    private func checkLongMicrophone(activity: VerificationActivity) async -> LongMicrophoneResult {
        let engine = WithheldPreparationEngine()
        await engine.releasePreparation()
        let suite = UserDefaults(suiteName: "LocalScribeLongVerification-\(UUID().uuidString)")!
        suite.register(defaults: ["selectedModel": SpeechModel.parakeetPhonon.rawValue, "saveHistory": false])
        let history = FileManager.default.temporaryDirectory.appendingPathComponent("Verification-\(UUID().uuidString)/history.json")
        let controller = AppController(engine: engine, defaults: suite, historyURL: history, verificationMode: false)
        let before = activity.snapshot()
        let probe = await PerformanceProbe.start()
        var started: ContinuousClock.Instant?
        var recordingSeconds = 0.0
        var continuedBeyond120 = false
        var maximumQueued = 0
        var drainedWhileRecording: Int64 = 0
        var failure: String?
        do {
            await controller.refreshInstalledModels()
            await controller.startRecording()
            guard controller.phase == .recording else { throw VerificationError(controller.errorMessage ?? "Long microphone check did not start") }
            started = .now
            while let start = started, start.duration(to: .now) < .seconds(125) {
                try Task.checkCancellation()
                guard UIApplication.shared.applicationState == .active else { throw VerificationError("App left the foreground during long microphone verification") }
                guard controller.phase == .recording else { throw VerificationError("Microphone stopped before the 125-second check completed") }
                let snapshot = controller.verificationCaptureSnapshot
                maximumQueued = max(maximumQueued, snapshot.bufferedSamples)
                drainedWhileRecording = max(drainedWhileRecording, snapshot.drainedSamples)
                if start.duration(to: .now) > .seconds(120) { continuedBeyond120 = true }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch { failure = error.localizedDescription }
        if let started {
            let duration = started.duration(to: .now).components
            recordingSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
        if controller.phase == .recording { await controller.stopRecording() }
        let snapshot = controller.verificationCaptureSnapshot
        controller.disableKeyboardSession()
        controller.setForeground(false)
        let counters = await engine.counters()
        let resources = await probe.finish()
        let valid = activity.validSince(before)
        let passed = failure == nil && continuedBeyond120 && recordingSeconds >= 125
            && snapshot.receivedSamples > 120 * 16_000 && drainedWhileRecording > 0
            && counters.samples == snapshot.receivedSamples && counters.maximumChunkSamples <= 32_000 && counters.finished == 1
            && snapshot.overflowSamples == 0 && snapshot.processingFailureCount == 0
            && snapshot.generation == nil && controller.phase == .idle
            && controller.history.isEmpty && controller.rawTranscript.isEmpty && valid
        return LongMicrophoneResult(passed: passed, requestedRecordingSeconds: 125,
            actualRecordingSeconds: recordingSeconds, continuedRecordingBeyond120Seconds: continuedBeyond120,
            capturedSamples: snapshot.receivedSamples, drainedWhileRecordingSamples: drainedWhileRecording,
            samplesIgnoredByNoOpEngine: counters.samples, sampledMaximumCaptureFIFOQueuedSamples: maximumQueued,
            queueSamplingIntervalSeconds: 0.25, maximumSubmittedChunkSamples: counters.maximumChunkSamples,
            overflowSamples: snapshot.overflowSamples, conversionFailures: snapshot.processingFailureCount,
            settledToIdle: controller.phase == .idle, hardwareAudioTranscribed: false, hardwareAudioSaved: false,
            timingValid: valid, resources: resources, error: failure)
    }

    private func checkStream(_ engine: any StreamingLocalTranscriptionEngine, fixture: Fixture,
                             variant: FixtureVariant, activity: VerificationActivity) async -> StreamResult {
        var pcm = FixtureStreamPCM(clip: fixture.samples, repetitions: variant.repetitions, prefixSamples: variant.prefixSamples, gapPatternSamples: variant.gapPatternSamples)
        let totalSamples = pcm.totalSamples
        let queue = CaptureBuffer(capacitySamples: 64_000)
        let updates = VerificationUpdates()
        var admitted = 0
        var maximumChunk = 0
        var maximumQueued = 0
        var updatesBeforeFinish = 0
        var nonemptyBeforeFinish = 0
        var finalTail = 0
        var text: String?
        var failure: String?
        let before = activity.snapshot()
        let probe = await PerformanceProbe.start()
        queue.begin()
        do {
            try await activity.waitUntilActive()
            try await engine.beginStreaming { updates.record($0) }
            var offset = 0
            while offset < totalSamples {
                try Task.checkCancellation()
                guard UIApplication.shared.applicationState == .active else { throw VerificationError("App left the foreground during public fixture verification") }
                let count = min(32_000, totalSamples - offset)
                // Keep only one two-second batch and the five-second source clip.
                let chunk = pcm.next(maximumSamples: count)
                queue.append(chunk)
                maximumQueued = max(maximumQueued, queue.snapshot.bufferedSamples)
                let pending = queue.drain(minimumSamples: 32_000, maximumSamples: 32_000)
                if !pending.isEmpty {
                    maximumChunk = max(maximumChunk, pending.count)
                    try await engine.appendStreaming(samples: pending)
                    admitted += pending.count
                }
                offset += count
            }
            let tail = queue.finish()
            finalTail = tail.count
            if !tail.isEmpty {
                maximumChunk = max(maximumChunk, tail.count)
                try await engine.appendStreaming(samples: tail)
                admitted += tail.count
            }
            let liveUpdates = updates.snapshot()
            updatesBeforeFinish = liveUpdates.count
            nonemptyBeforeFinish = liveUpdates.nonemptyChangedCount
            text = try await engine.finishStreaming()
        } catch { failure = error.localizedDescription; await engine.cancelStreaming(); queue.discard() }
        let resource = await probe.finish(audioSeconds: Double(totalSamples) / 16_000)
        let update = updates.snapshot()
        let reference = Array(repeating: fixture.reference, count: variant.repetitions).joined(separator: " ")
        let wer = text.map { WordErrorRate.evaluate(reference: reference, hypothesis: $0) }
        let valid = activity.validSince(before)
        let finalSnapshot = queue.snapshot
        let passed = failure == nil && admitted == totalSamples && maximumChunk <= 32_000
            && maximumQueued <= 64_000 && finalSnapshot.overflowSamples == 0 && finalTail > 0
            && !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (variant.repetitions == 1 || nonemptyBeforeFinish > 0) && valid
        return StreamResult(passed: passed, fixtureID: fixture.id, variantID: variant.id, repetitions: variant.repetitions,
            prefixSilenceSeconds: Double(variant.prefixSamples) / 16_000,
            interRepeatGapPatternSeconds: variant.gapPatternSamples.map { Double($0) / 16_000 },
            expectedReferenceWordCount: WordErrorRate.normalizedWords(reference).count,
            audioSeconds: Double(totalSamples) / 16_000, suppliedSamples: admitted,
            maximumSubmittedChunkSamples: maximumChunk, maximumCaptureFIFOQueuedSamples: maximumQueued,
            submissionConcurrencyMaximum: 1, finalTailSamples: finalTail,
            updateCount: update.count, updatesBeforeFinish: updatesBeforeFinish,
            nonemptyChangedUpdateCount: update.nonemptyChangedCount, nonemptyChangedUpdatesBeforeFinish: nonemptyBeforeFinish,
            firstNonemptyUpdateAfterSeconds: update.firstNonemptyElapsed, publicFixtureTranscript: text,
            wordErrors: wer, wordErrorRate: wer?.rate, timingValid: valid, resources: resource,
            realTimeFactor: valid ? resource.realTimeFactor : nil, error: failure)
    }

    private func loadFixture() throws -> Fixture {
        guard let metadataURL = Bundle.main.url(forResource: "benchmark-fixture", withExtension: "json", subdirectory: "benchmark")
                ?? Bundle.main.url(forResource: "benchmark-fixture", withExtension: "json") else { throw VerificationError("Public fixture metadata is missing") }
        let metadata = try JSONDecoder().decode(FixtureMetadata.self, from: Data(contentsOf: metadataURL))
        guard !metadata.audioFilename.contains("/"), metadata.audioFilename != ".", metadata.audioFilename != ".." else { throw VerificationError("Invalid fixture filename") }
        let audioURL = metadataURL.deletingLastPathComponent().appendingPathComponent(metadata.audioFilename)
        let bytes = try Data(contentsOf: audioURL)
        guard bytes.count < 1_048_576, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == metadata.sha256 else { throw VerificationError("Public fixture hash is invalid") }
        let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              file.length > 0, file.length < 160_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw VerificationError("Invalid public fixture audio format") }
        try file.read(into: buffer)
        guard Int64(buffer.frameLength) == file.length, let data = buffer.floatChannelData?[0] else { throw VerificationError("Incomplete fixture read") }
        return Fixture(id: metadata.id, reference: metadata.reference, samples: Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
    }
    private func checkpoint(_ report: Report, to output: URL, activity: VerificationActivity) throws {
        var report = report; report.lifecycle = activity.snapshot()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: output, options: [.atomic, .completeFileProtection])
        var file = output; var values = URLResourceValues(); values.isExcludedFromBackup = true; try file.setResourceValues(values)
    }
    private struct FixtureVariant {
        let id: String
        let repetitions: Int
        let prefixSamples: Int
        let gapPatternSamples: [Int]
        static let short = Self(id: "short", repetitions: 1, prefixSamples: 0, gapPatternSamples: [])
        static let baseline = Self(id: "repeated-baseline", repetitions: 22, prefixSamples: 0, gapPatternSamples: [])
        static let prefixShifted = Self(id: "prefix-0.75s", repetitions: 22, prefixSamples: 12_000, gapPatternSamples: [])
        static let gapped = Self(id: "prefix-0.75s-alternating-gaps-0.3s-0.8s", repetitions: 22, prefixSamples: 12_000, gapPatternSamples: [4_800, 12_800])
    }
    private struct FixtureMetadata: Decodable { let id: String; let audioFilename: String; let sha256: String; let reference: String }
    private struct Fixture { let id: String; let reference: String; let samples: [Float] }
    private struct Report: Encodable {
        let schemaVersion = 2
        let startedAt: Date
        var completedAt: Date?
        let operatingSystem: String
        let lowPowerModeEnabledAtStart: Bool
        let physicalMemoryBytes: UInt64
        let buildOptimization: String
        var status: String
        var hardware: HardwareResult?
        var longMicrophone: LongMicrophoneResult?
        var models: [ModelResult]
        var lifecycle: VerificationActivity.Snapshot
        let privacy = "Hardware microphone PCM is only counted by a withheld/no-op fixture engine, never recognized, saved, or printed. The real model receives only pinned public LibriSpeech audio."
        let limitations = ["Hardware Stop-while-loading uses a no-op engine to withhold preparation deterministically. Optional 125-second capture uses a ready no-op engine with live draining; public fixture streams use the actual local model.", "Repeated fixture speech is an integration test, not a representative dictation accuracy benchmark. Supplied audio is accelerated rather than paced in real time.", "Reported FIFO/submission bounds are observed at the caller boundary; backend internal retained audio is not measured. Physical-footprint peaks are sampled at 50 ms. GPU/ANE utilization and energy are not measured.", "Timing is invalid if application activity changes; preparation caches are not reset.", "Pass indicates workflow completion, live nonempty updates and sample/batch bounds; WER is measured without an accuracy acceptance threshold."]
    }
    private struct HardwareResult: Encodable {
        let passed: Bool
        let recordingStarted: Bool
        let preparationWithheldAtStop: Bool
        let stopEnteredFinalization: Bool
        let captureStoppedBeforePreparationReleased: Bool
        let settledToIdle: Bool
        let capturedSamples: Int64
        let samplesIgnoredByNoOpEngine: Int64
        let maximumFinalizationChunkSamples: Int
        let overflowSamples: Int64?
        let conversionFailures: Int?
        let hardwareAudioTranscribed: Bool
        let hardwareAudioSaved: Bool
        let timingValid: Bool
        let resources: PerformanceReport
        let error: String?
    }
    private struct LongMicrophoneResult: Encodable {
        let passed: Bool
        let requestedRecordingSeconds: Double
        let actualRecordingSeconds: Double
        let continuedRecordingBeyond120Seconds: Bool
        let capturedSamples: Int64
        let drainedWhileRecordingSamples: Int64
        let samplesIgnoredByNoOpEngine: Int64
        let sampledMaximumCaptureFIFOQueuedSamples: Int
        let queueSamplingIntervalSeconds: Double
        let maximumSubmittedChunkSamples: Int
        let overflowSamples: Int64
        let conversionFailures: Int
        let settledToIdle: Bool
        let hardwareAudioTranscribed: Bool
        let hardwareAudioSaved: Bool
        let timingValid: Bool
        let resources: PerformanceReport
        let error: String?
    }
    private struct ModelResult: Encodable {
        let model: SpeechModel
        var status: String
        var preparation: PerformanceReport?
        var preparationTimingValid: Bool?
        var enginePreparationReport: EnginePerformanceReport?
        var shortStream: StreamResult?
        var longStream: StreamResult?
        var seamVariants: [StreamResult]
        var error: String?
    }
    private struct StreamResult: Encodable {
        let passed: Bool
        let fixtureID: String
        let variantID: String
        let repetitions: Int
        let prefixSilenceSeconds: Double
        let interRepeatGapPatternSeconds: [Double]
        let expectedReferenceWordCount: Int
        let audioSeconds: Double
        let suppliedSamples: Int
        let maximumSubmittedChunkSamples: Int
        let maximumCaptureFIFOQueuedSamples: Int
        let submissionConcurrencyMaximum: Int
        let finalTailSamples: Int
        let updateCount: Int
        let updatesBeforeFinish: Int
        let nonemptyChangedUpdateCount: Int
        let nonemptyChangedUpdatesBeforeFinish: Int
        let firstNonemptyUpdateAfterSeconds: Double?
        let timingContext = "Elapsed/update latency for accelerated public fixture submission; not wall-clock readiness while a person speaks"
        let publicFixtureTranscript: String?
        let wordErrors: WordErrorRateResult?
        let wordErrorRate: Double?
        let timingValid: Bool
        let resources: PerformanceReport
        let realTimeFactor: Double?
        let error: String?
    }
    private struct VerificationError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}

/// Segment cursor retains the original short clip and one submitted batch only.
/// Silence changes model window seams without adding another recording/reference.
private struct FixtureStreamPCM {
    private let clip: [Float]
    private let segments: [(speech: Bool, count: Int)]
    let totalSamples: Int
    private var segmentIndex = 0
    private var offset = 0
    init(clip: [Float], repetitions: Int, prefixSamples: Int, gapPatternSamples: [Int]) {
        precondition(!clip.isEmpty && repetitions > 0 && prefixSamples >= 0 && gapPatternSamples.allSatisfy { $0 >= 0 })
        self.clip = clip
        var segments: [(speech: Bool, count: Int)] = []
        if prefixSamples > 0 { segments.append((false, prefixSamples)) }
        for index in 0..<repetitions {
            segments.append((true, clip.count))
            if index + 1 < repetitions, !gapPatternSamples.isEmpty {
                let gap = gapPatternSamples[index % gapPatternSamples.count]
                if gap > 0 { segments.append((false, gap)) }
            }
        }
        self.segments = segments
        totalSamples = segments.reduce(0) { $0 + $1.count }
    }
    mutating func next(maximumSamples: Int) -> [Float] {
        precondition(maximumSamples > 0 && maximumSamples <= 32_000)
        var batch: [Float] = []
        batch.reserveCapacity(maximumSamples)
        while batch.count < maximumSamples, segmentIndex < segments.count {
            let segment = segments[segmentIndex]
            let count = min(maximumSamples - batch.count, segment.count - offset)
            if segment.speech { batch.append(contentsOf: clip[offset..<(offset + count)]) }
            else { batch.append(contentsOf: repeatElement(Float.zero, count: count)) }
            offset += count
            if offset == segment.count { segmentIndex += 1; offset = 0 }
        }
        return batch
    }
}

private actor WithheldPreparationEngine: StreamingLocalTranscriptionEngine, ModelPreparationReportingEngine {
    private var released = false
    private var preparationStarted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var sampleCount: Int64 = 0
    private var maximumChunk = 0
    private var finishCount = 0
    func isInstalled(_ model: SpeechModel) async -> Bool { true }
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws { throw CancellationError() }
    func prepare(_ model: SpeechModel) async throws {
        preparationStarted = true
        if !released { await withCheckedContinuation { waiters.append($0) } }
        try Task.checkCancellation()
    }
    func preparationStage() async -> ModelPreparationStage? { released ? .ready : .loadingCoreML }
    func isPreparationPending() -> Bool { preparationStarted && !released }
    func releasePreparation() { released = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
    func transcribe(samples: [Float]) async throws -> String { "" }
    func beginStreaming(onUpdate: @escaping @Sendable (SpeechTranscriptUpdate) -> Void) async throws {}
    func appendStreaming(samples: [Float]) async throws { sampleCount += Int64(samples.count); maximumChunk = max(maximumChunk, samples.count) }
    func finishStreaming() async throws -> String { finishCount += 1; return "" }
    func cancelStreaming() async {}
    func unload() async {}
    func counters() -> (samples: Int64, maximumChunkSamples: Int, finished: Int) { (sampleCount, maximumChunk, finishCount) }
}
private final class VerificationUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var count = 0
    private var nonemptyChangedCount = 0
    private var lastNonemptyText: String?
    private var firstNonemptyElapsed: Double?
    func record(_ update: SpeechTranscriptUpdate) {
        lock.withLock {
            count += 1
            let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != lastNonemptyText else { return }
            nonemptyChangedCount += 1
            lastNonemptyText = text
            if firstNonemptyElapsed == nil { firstNonemptyElapsed = ProcessInfo.processInfo.systemUptime - started }
        }
    }
    func snapshot() -> (count: Int, nonemptyChangedCount: Int, firstNonemptyElapsed: Double?) {
        lock.withLock { (count, nonemptyChangedCount, firstNonemptyElapsed) }
    }
}
private final class VerificationActivity: @unchecked Sendable {
    struct Snapshot: Codable, Sendable { let initialState: String; let state: String; let activeLossCount: Int; let events: [String] }
    private let lock = NSLock()
    private let initialState: String
    private var state: String
    private var losses = 0
    private var events: [String] = []
    private var observers: [NSObjectProtocol] = []
    @MainActor init() {
        let initial = UIApplication.shared.applicationState == .active ? "active" : "inactive"
        initialState = initial; state = initial
        for (name, value) in [(UIApplication.didBecomeActiveNotification, "active"), (UIApplication.willResignActiveNotification, "inactive"), (UIApplication.didEnterBackgroundNotification, "background")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    if self.state == "active", value != "active" { self.losses += 1 }
                    self.state = value
                    self.events.append(value)
                    if self.events.count > 64 { self.events.removeFirst() }
                }
            })
        }
    }
    deinit { for token in observers { NotificationCenter.default.removeObserver(token) } }
    func snapshot() -> Snapshot { lock.withLock { Snapshot(initialState: initialState, state: state, activeLossCount: losses, events: events) } }
    func validSince(_ start: Snapshot) -> Bool { let end = snapshot(); return start.state == "active" && end.state == "active" && end.activeLossCount == start.activeLossCount }
    func waitUntilActive() async throws { while snapshot().state != "active" { try await Task.sleep(for: .milliseconds(250)) }; try Task.checkCancellation() }
}
#endif
