#if DEBUG
import AVFAudio
import CryptoKit
import Darwin
import Foundation
import LocalScribeCore
import UIKit

/// A finite, explicitly requested developer run. Never captures microphone audio.
/// Optional networking is limited to model installation when --benchmark-downloads
/// is explicitly supplied. Reports stay in this app's Documents directory.
struct BenchmarkRunner: Sendable {
    private let models: [SpeechModel]
    private let allowDownloads: Bool
    private let fixtureManifestURL: URL?
    private static let warmRunCount = 3

    init?(arguments: [String]) throws {
        guard let modelFlag = arguments.firstIndex(of: "--benchmark-models") else { return nil }
        guard arguments.filter({ $0 == "--benchmark-models" }).count == 1,
              modelFlag + 1 < arguments.count,
              !arguments[modelFlag + 1].hasPrefix("--") else {
            throw BenchmarkError.invalidArguments("--benchmark-models requires one comma-separated model list")
        }
        let identifiers = arguments[modelFlag + 1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !identifiers.isEmpty, identifiers.count <= SpeechModel.allCases.count,
              Set(identifiers).count == identifiers.count else {
            throw BenchmarkError.invalidArguments("Use one to five distinct model IDs")
        }
        models = try identifiers.map { id in
            switch id {
            case "phonon2": .parakeetPhonon
            case "phonon2-g4": .parakeetPhononG4
            case "phonon2-g1": .parakeetPhononG1
            case "ultra": .parakeetUltra
            case "redux": .parakeetRedux
            default: throw BenchmarkError.invalidArguments("Unknown benchmark model: \(id)")
            }
        }
        allowDownloads = arguments.contains("--benchmark-downloads")
        if let fixtureFlag = arguments.firstIndex(of: "--benchmark-fixture") {
            guard arguments.filter({ $0 == "--benchmark-fixture" }).count == 1,
                  fixtureFlag + 1 < arguments.count,
                  arguments[fixtureFlag + 1].hasPrefix("/") else {
                throw BenchmarkError.invalidArguments("--benchmark-fixture requires an absolute JSON manifest path")
            }
            fixtureManifestURL = URL(fileURLWithPath: arguments[fixtureFlag + 1])
        } else { fixtureManifestURL = nil }
    }

    /// Invoke on a dedicated task, with regular dictation disabled until it returns.
    /// A new runtime is used per model, but OS file/compilation caches are not reset.
    func run(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        let fixture = try loadFixture()
        let manifest = try ModelIntegrityManifest.bundled()
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let output = documents.appendingPathComponent("benchmark-\(UUID().uuidString).json")
        let lifecycle = await BenchmarkLifecycleMonitor.start(sidecar: output.deletingPathExtension().appendingPathExtension("lifecycle.json"))
        var report = BenchmarkReport(schemaVersion: 2, startedAt: Date(), completedAt: nil,
                                     device: DeviceMetadata.current(), fixture: fixture.metadata,
                                     sharedKeyboardCheck: Self.checkSharedKeyboard(),
                                     allowModelDownloads: allowDownloads,
                                     requestedWarmRunsPerModel: Self.warmRunCount, models: [], lifecycle: lifecycle.snapshot())
        try write(report, to: output, lifecycle: lifecycle)
        for model in models {
            try Task.checkCancellation()
            let modelID = Self.identifier(model)
            guard let catalog = manifest.models.first(where: { $0.id == modelID }) else {
                throw BenchmarkError.invalidArguments("Model is absent from bundled catalog: \(modelID)")
            }
            var result = ModelBenchmark(modelID: modelID, modelName: model.name,
                                        repository: catalog.repository, revision: catalog.revision,
                                        publishedDownloadBytes: catalog.totalBytes,
                                        status: "starting", installedStorageBeforeLoad: nil,
                                        installedStorageAfterRuns: nil, coldModelLoad: nil,
                                        firstTranscription: nil, warmTranscriptions: [], unloadAndSettle: nil,
                                        coldModelLoadLifecycle: nil, unloadAndSettleLifecycle: nil, error: nil)
            report.models.append(result)
            let index = report.models.count - 1
            var runtime: LocalModelEngine?
            do {
                result.status = "waitingForActiveModelSetup"
                report.models[index] = result
                try write(report, to: output, lifecycle: lifecycle)
                try await lifecycle.waitUntilActive()
                let engine = try LocalModelEngine()
                runtime = engine
                if !(await engine.isInstalled(model)) {
                    guard allowDownloads else { throw ModelInstallationError.missingModel }
                    result.status = "downloading"
                    report.models[index] = result
                    try write(report, to: output, lifecycle: lifecycle)
                    progress("Downloading \(model.name)")
                    try await engine.download(model) { _ in }
                }
                result.installedStorageBeforeLoad = try installedStorage(catalog)
                result.status = "waitingForActiveModelLoad"
                report.models[index] = result
                try write(report, to: output, lifecycle: lifecycle)
                try await lifecycle.waitUntilActive()
                result.status = "loading"
                report.models[index] = result
                try write(report, to: output, lifecycle: lifecycle)
                progress("Loading \(model.name)")
                let loadStart = lifecycle.beginOperation()
                do {
                    try await engine.prepare(model)
                    result.coldModelLoadLifecycle = lifecycle.finishOperation(loadStart)
                    result.coldModelLoad = await engine.performanceReports().last
                } catch {
                    result.coldModelLoadLifecycle = lifecycle.finishOperation(loadStart)
                    result.coldModelLoad = await engine.performanceReports().last
                    await engine.unload()
                    throw error
                }
                result.status = "transcribing"
                report.models[index] = result
                try write(report, to: output, lifecycle: lifecycle)
                // First inference is recorded separately; subsequent three runs
                // use the same loaded runtime and the exact same audio samples.
                for runIndex in 0...Self.warmRunCount {
                    try Task.checkCancellation()
                    result.status = "waitingForActiveTranscription-\(runIndex)"
                    report.models[index] = result
                    try write(report, to: output, lifecycle: lifecycle)
                    try await lifecycle.waitUntilActive()
                    result.status = "transcribing-\(runIndex)"
                    report.models[index] = result
                    try write(report, to: output, lifecycle: lifecycle)
                    progress("\(model.name): \(runIndex == 0 ? "first inference" : "warm run \(runIndex)/\(Self.warmRunCount)")")
                    var transcription: TranscriptionBenchmark
                    let priorReportID = await engine.performanceReports().last?.id
                    let inferenceStart = lifecycle.beginOperation()
                    do {
                        let text = try await engine.transcribe(samples: fixture.samples)
                        let validity = lifecycle.finishOperation(inferenceStart)
                        let latest = await engine.performanceReports().last
                        let resources = latest?.id != priorReportID && latest?.stage == .transcription ? latest : nil
                        let wer = WordErrorRate.evaluate(reference: fixture.metadata.reference, hypothesis: text)
                        transcription = TranscriptionBenchmark(index: runIndex, transcript: text,
                            wordErrors: wer, wordErrorRate: wer.rate, performance: resources,
                            realTimeFactor: validity.timingValid ? resources?.resources.realTimeFactor : nil,
                            averageActiveCPUCores: validity.timingValid ? resources?.resources.averageActiveCPUCores : nil,
                            lifecycle: validity, error: nil)
                    } catch {
                        let validity = lifecycle.finishOperation(inferenceStart)
                        let latest = await engine.performanceReports().last
                        let resources = latest?.id != priorReportID && latest?.stage == .transcription ? latest : nil
                        transcription = TranscriptionBenchmark(index: runIndex, transcript: nil,
                            wordErrors: nil, wordErrorRate: nil, performance: resources,
                            realTimeFactor: nil, averageActiveCPUCores: nil,
                            lifecycle: validity, error: error.localizedDescription)
                    }
                    if runIndex == 0 { result.firstTranscription = transcription }
                    else { result.warmTranscriptions.append(transcription) }
                    report.models[index] = result
                    try write(report, to: output, lifecycle: lifecycle)
                    try Task.checkCancellation()
                }
                result.installedStorageAfterRuns = try installedStorage(catalog)
                result.status = "waitingForActiveUnload"
                report.models[index] = result
                try write(report, to: output, lifecycle: lifecycle)
                try await lifecycle.waitUntilActive()
                result.status = "unloadingAndSettling"
                report.models[index] = result
                try write(report, to: output, lifecycle: lifecycle)
                let unloadStart = lifecycle.beginOperation()
                let unloadProbe = await PerformanceProbe.start()
                await engine.unload()
                do { try await Task.sleep(for: .seconds(1)) }
                catch {
                    result.unloadAndSettleLifecycle = lifecycle.finishOperation(unloadStart)
                    result.unloadAndSettle = await unloadProbe.finish()
                    throw error
                }
                result.unloadAndSettleLifecycle = lifecycle.finishOperation(unloadStart)
                result.unloadAndSettle = await unloadProbe.finish()
                result.status = result.firstTranscription?.error == nil && result.warmTranscriptions.allSatisfy({ $0.error == nil })
                    ? (result.coldModelLoadLifecycle?.timingValid == true
                        && result.unloadAndSettleLifecycle?.timingValid == true
                        && result.firstTranscription?.lifecycle.timingValid == true
                        && result.warmTranscriptions.allSatisfy({ $0.lifecycle.timingValid })
                        ? "completed" : "completedWithInterruptedTimings") : "completedWithErrors"
            } catch {
                await runtime?.unload()
                result.status = error is CancellationError ? "cancelled" : "failed"
                result.error = error.localizedDescription
                report.models[index] = result
                try write(report, to: output, lifecycle: lifecycle)
                if error is CancellationError { throw error }
            }
            report.models[index] = result
            try write(report, to: output, lifecycle: lifecycle)
        }
        report.completedAt = Date()
        try write(report, to: output, lifecycle: lifecycle)
        progress("Benchmark finished: \(output.lastPathComponent)")
        return output
    }

    private func loadFixture() throws -> LoadedFixture {
        guard let manifestURL = fixtureManifestURL
                ?? Bundle.main.url(forResource: "benchmark-fixture", withExtension: "json", subdirectory: "benchmark")
                ?? Bundle.main.url(forResource: "benchmark-fixture", withExtension: "json") else {
            throw BenchmarkError.invalidFixture("Bundle the benchmark resource directory or specify --benchmark-fixture")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        guard (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 65_536 else {
            throw BenchmarkError.invalidFixture("Fixture manifest exceeds 64 KB")
        }
        let metadata = try JSONDecoder().decode(FixtureMetadata.self, from: Data(contentsOf: manifestURL))
        guard metadata.schemaVersion == 1, metadata.sampleRate == 16_000,
              !metadata.audioFilename.isEmpty, !metadata.audioFilename.contains("/"),
              metadata.audioFilename != ".", metadata.audioFilename != "..",
              !WordErrorRate.normalizedWords(metadata.reference).isEmpty else {
            throw BenchmarkError.invalidFixture("Invalid fixture metadata")
        }
        let audioURL = manifestURL.deletingLastPathComponent().appendingPathComponent(metadata.audioFilename)
        let audioAttrs = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        guard (audioAttrs[.size] as? NSNumber)?.intValue ?? Int.max <= 10_485_760 else {
            throw BenchmarkError.invalidFixture("Fixture audio exceeds 10 MB")
        }
        let data = try Data(contentsOf: audioURL)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == metadata.sha256 else { throw BenchmarkError.invalidFixture("Audio hash mismatch") }
        let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              file.length > 0, file.length <= Int64(CaptureBuffer.maximumSamples),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw BenchmarkError.invalidFixture("Expected mono 16 kHz audio of at most 120 seconds")
        }
        try file.read(into: buffer)
        guard Int64(buffer.frameLength) == file.length, let values = buffer.floatChannelData?[0] else {
            throw BenchmarkError.invalidFixture("Could not read complete fixture audio")
        }
        let samples = Array(UnsafeBufferPointer(start: values, count: Int(buffer.frameLength)))
        guard samples.allSatisfy(\.isFinite), metadata.audioSeconds.isFinite,
              abs(Double(samples.count) / 16_000 - metadata.audioSeconds) <= 1.0 / 16_000 else {
            throw BenchmarkError.invalidFixture("Audio samples or declared duration are invalid")
        }
        return LoadedFixture(metadata: metadata, samples: samples)
    }

    private static func checkSharedKeyboard() -> String {
        do {
            let store = try SharedKeyboardStore.appGroupStore()
            let status = KeyboardSessionStatus(phase: .inactive)
            try store.writeStatus(status)
            guard try store.readStatus() == status else { return "FAILED: shared status did not round-trip" }
            guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedKeyboardStore.appGroup) else {
                return "FAILED: shared group container unavailable"
            }
            let directory = root.appendingPathComponent("KeyboardBridge", isDirectory: true)
            let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            return values.isExcludedFromBackup == true
                ? "PASS: App Group read/write, atomic status round-trip, backup exclusion"
                : "FAILED: shared bridge backup exclusion missing"
        } catch { return "FAILED: \(error.localizedDescription)" }
    }

    private func installedStorage(_ model: ModelIntegrityManifest.Model) throws -> InstalledStorage {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false)
        let directory = support.appendingPathComponent("SpeechModels/\(model.id)-\(model.revision)", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        var enumerationError: Error?
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw BenchmarkError.invalidFixture("Cannot enumerate installed model storage")
        }
        var logicalBytes: Int64 = 0
        var allocatedBytes: Int64 = 0
        var allocatedSizeAvailable = true
        var fileCount = 0
        for case let url as URL in files {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            logicalBytes += Int64(values.fileSize ?? 0)
            if let allocated = values.totalFileAllocatedSize { allocatedBytes += Int64(allocated) }
            else { allocatedSizeAvailable = false }
            fileCount += 1
        }
        if let enumerationError { throw enumerationError }
        return InstalledStorage(logicalFileBytes: logicalBytes,
                                allocatedFileBytes: allocatedSizeAvailable ? allocatedBytes : nil,
                                regularFileCount: fileCount)
    }

    private func write(_ report: BenchmarkReport, to url: URL, lifecycle: BenchmarkLifecycleMonitor) throws {
        var report = report
        report.lifecycle = lifecycle.snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: [.atomic, .completeFileProtection])
        var file = url
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try file.setResourceValues(attributes)
    }

    private static func identifier(_ model: SpeechModel) -> String {
        switch model {
        case .parakeetPhonon: "phonon2"
        case .parakeetPhononG4: "phonon2-g4"
        case .parakeetPhononG1: "phonon2-g1"
        case .parakeetUltra: "ultra"
        case .parakeetRedux: "redux"
        }
    }

    private struct LoadedFixture { let metadata: FixtureMetadata; let samples: [Float] }
    private struct FixtureMetadata: Codable, Sendable {
        let schemaVersion: Int
        let id: String
        let audioFilename: String
        let sha256: String
        let reference: String
        let sampleRate: Int
        let audioSeconds: Double
        let license: String
        let source: String
        let attribution: String
        let modifications: String
    }
    private struct InstalledStorage: Codable, Sendable {
        let logicalFileBytes: Int64
        let allocatedFileBytes: Int64?
        let regularFileCount: Int
    }
    private struct TranscriptionBenchmark: Codable, Sendable {
        let index: Int
        let transcript: String?
        let wordErrors: WordErrorRateResult?
        let wordErrorRate: Double?
        let performance: EnginePerformanceReport?
        let realTimeFactor: Double?
        let averageActiveCPUCores: Double?
        let lifecycle: BenchmarkOperationLifecycle
        let error: String?
    }
    private struct ModelBenchmark: Codable, Sendable {
        let modelID: String
        let modelName: String
        let repository: String
        let revision: String
        let publishedDownloadBytes: Int64
        var status: String
        var installedStorageBeforeLoad: InstalledStorage?
        var installedStorageAfterRuns: InstalledStorage?
        var coldModelLoad: EnginePerformanceReport?
        var firstTranscription: TranscriptionBenchmark?
        var warmTranscriptions: [TranscriptionBenchmark]
        var unloadAndSettle: PerformanceReport?
        var coldModelLoadLifecycle: BenchmarkOperationLifecycle?
        var unloadAndSettleLifecycle: BenchmarkOperationLifecycle?
        var error: String?
    }
    private struct BenchmarkReport: Encodable, Sendable {
        let schemaVersion: Int
        let startedAt: Date
        var completedAt: Date?
        let device: DeviceMetadata
        let fixture: FixtureMetadata
        let sharedKeyboardCheck: String
        let allowModelDownloads: Bool
        let requestedWarmRunsPerModel: Int
        var models: [ModelBenchmark]
        var lifecycle: BenchmarkLifecycleSnapshot
        let runtime = "FluidAudio 0.17.5 / Core ML"
        let limitations = [
            "Single short read-speech clip; WER does not establish dictation accuracy. Repetitions are timing runs, not independent accuracy samples.",
            "Cold model load uses a new runtime; process, OS file and Core ML compilation caches are not reset.",
            "Physical footprint samples include the app and probe; 50 ms sampling may miss transient peaks. Kernel peak is process lifetime.",
            "CPU time covers the app process. GPU/ANE utilization and energy are not measured; requested Core ML compute units do not prove actual partitioning.",
            "Installed storage covers regular files in this model installation directory, excluding shared runtime assets and system compilation caches. Allocated bytes are filesystem allocation, not physical NAND usage.",
            "Results depend on app build optimization, temperature, device activity and run order.",
            "An operation that starts/ends inactive, loses focus or enters background has invalid timing. Raw elapsed time may include suspension; interrupted derived timing values are omitted. The lifecycle sidecar records notifications immediately; checkpoints contain the current event snapshot."
        ]
    }
    private struct DeviceMetadata: Codable, Sendable {
        let hardwareIdentifier: String
        let operatingSystem: String
        let physicalMemoryBytes: UInt64
        let processorCount: Int
        let activeProcessorCount: Int
        let lowPowerModeEnabledAtStart: Bool
        let appVersion: String
        let appBuild: String
        let buildConfiguration: String
        let simulator: Bool
        static func current() -> Self {
            var length = 0
            var hardware = "unknown"
            if sysctlbyname("hw.machine", nil, &length, nil, 0) == 0, length > 0, length < 256 {
                var bytes = [CChar](repeating: 0, count: length)
                let status = bytes.withUnsafeMutableBufferPointer {
                    sysctlbyname("hw.machine", $0.baseAddress, &length, nil, 0)
                }
                if status == 0 { hardware = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            }
            #if targetEnvironment(simulator)
            let simulator = true
            #else
            let simulator = false
            #endif
            let process = ProcessInfo.processInfo
            return Self(hardwareIdentifier: hardware, operatingSystem: process.operatingSystemVersionString,
                        physicalMemoryBytes: process.physicalMemory, processorCount: process.processorCount,
                        activeProcessorCount: process.activeProcessorCount,
                        lowPowerModeEnabledAtStart: process.isLowPowerModeEnabled,
                        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                        appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                        buildConfiguration: "DEBUG / Swift \(Bundle.main.object(forInfoDictionaryKey: "LocalScribeOptimizationLevel") as? String ?? "unknown")",
                        simulator: simulator)
        }
    }
    private enum BenchmarkError: LocalizedError {
        case invalidArguments(String), invalidFixture(String)
        var errorDescription: String? {
            switch self {
            case .invalidArguments(let message), .invalidFixture(let message): message
            }
        }
    }
}

private struct BenchmarkLifecycleEvent: Codable, Sendable {
    let sequence: Int
    let date: Date
    let elapsedSinceMonitorStart: Double
    let notification: String
    let applicationState: String
}
private struct BenchmarkLifecycleSnapshot: Codable, Sendable {
    let initialApplicationState: String
    let applicationState: String
    let totalEventCount: Int
    let droppedEventCount: Int
    let activeLossCount: Int
    let backgroundEntryCount: Int
    let events: [BenchmarkLifecycleEvent]
    let sidecarWriteError: String?
}
private struct BenchmarkOperationLifecycle: Codable, Sendable {
    let startedApplicationState: String
    let finishedApplicationState: String
    let activeLossesDuringOperation: Int
    let backgroundEntriesDuringOperation: Int
    let startEventSequence: Int
    let endEventSequence: Int
    let timingValid: Bool
    let invalidTimingReason: String?
}

/// Notification callbacks synchronously record transitions, avoiding delayed
/// actor messages that could miss a brief background/foreground cycle.
/// The lock protects every mutable event/state field; observer tokens are only
/// created at initialization and removed at deinitialization.
private final class BenchmarkLifecycleMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let initialState: String
    private let startedUptime = ProcessInfo.processInfo.systemUptime
    private let sidecar: URL
    private var state: String
    private var events: [BenchmarkLifecycleEvent] = []
    private var eventCount = 0
    private var activeLossCount = 0
    private var backgroundEntryCount = 0
    private var sidecarWriteError: String?
    private var observers: [NSObjectProtocol] = []

    @MainActor static func start(sidecar: URL) -> BenchmarkLifecycleMonitor {
        let initial: String
        switch UIApplication.shared.applicationState {
        case .active: initial = "active"
        case .inactive: initial = "inactive"
        case .background: initial = "background"
        @unknown default: initial = "unknown"
        }
        return BenchmarkLifecycleMonitor(initialState: initial, sidecar: sidecar)
    }

    private init(initialState: String, sidecar: URL) {
        state = initialState
        self.initialState = initialState
        self.sidecar = sidecar
        let notifications: [(Notification.Name, String, String)] = [
            (UIApplication.didBecomeActiveNotification, "didBecomeActive", "active"),
            (UIApplication.willResignActiveNotification, "willResignActive", "inactive"),
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground", "background"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground", "inactive")
        ]
        for (name, event, nextState) in notifications {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.record(event: event, state: nextState)
            })
        }
        record(event: "monitorStarted", state: initialState)
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func snapshot() -> BenchmarkLifecycleSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshotLocked()
    }
    private func snapshotLocked() -> BenchmarkLifecycleSnapshot {
        BenchmarkLifecycleSnapshot(initialApplicationState: initialState, applicationState: state,
            totalEventCount: eventCount, droppedEventCount: max(0, eventCount - events.count),
            activeLossCount: activeLossCount, backgroundEntryCount: backgroundEntryCount,
            events: events, sidecarWriteError: sidecarWriteError)
    }
    private func record(event: String, state nextState: String) {
        lock.lock()
        if state == "active" && nextState != "active" { activeLossCount += 1 }
        if event == "didEnterBackground" { backgroundEntryCount += 1 }
        state = nextState
        eventCount += 1
        events.append(BenchmarkLifecycleEvent(sequence: eventCount, date: Date(),
            elapsedSinceMonitorStart: max(0, ProcessInfo.processInfo.systemUptime - startedUptime),
            notification: event, applicationState: nextState))
        if events.count > 256 { events.removeFirst(events.count - 256) }
        let current = snapshotLocked()
        lock.unlock()
        // Keep a small event checkpoint even if a model operation is suspended.
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(current).write(to: sidecar, options: [.atomic, .completeFileProtection])
            var url = sidecar
            var attributes = URLResourceValues()
            attributes.isExcludedFromBackup = true
            try url.setResourceValues(attributes)
            lock.lock(); sidecarWriteError = nil; lock.unlock()
        } catch {
            lock.lock(); sidecarWriteError = error.localizedDescription; lock.unlock()
        }
    }
    func waitUntilActive() async throws {
        while snapshot().applicationState != "active" {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
        }
        try Task.checkCancellation()
    }
    func beginOperation() -> BenchmarkLifecycleSnapshot { snapshot() }
    func finishOperation(_ start: BenchmarkLifecycleSnapshot) -> BenchmarkOperationLifecycle {
        let end = snapshot()
        let losses = end.activeLossCount - start.activeLossCount
        let backgroundEntries = end.backgroundEntryCount - start.backgroundEntryCount
        let valid = start.applicationState == "active" && end.applicationState == "active" && losses == 0 && backgroundEntries == 0
        return BenchmarkOperationLifecycle(startedApplicationState: start.applicationState,
            finishedApplicationState: end.applicationState, activeLossesDuringOperation: losses,
            backgroundEntriesDuringOperation: backgroundEntries,
            startEventSequence: start.totalEventCount, endEventSequence: end.totalEventCount,
            timingValid: valid,
            invalidTimingReason: valid ? nil : "App activity changed or was not active throughout this operation; elapsed time may include suspension and must not be used as an uninterrupted timing result.")
    }
}
#endif
