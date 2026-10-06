import Foundation
import LocalScribeCore

struct EnginePreparationPhaseTiming: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case previousModelRelease, installationCheck, integrityVerification, localCoreMLLoad, nativeCPULoad, vocabularyLoad, preprocessorLoad, encoderLoad, decoderLoad, jointLoad, recognizerInitialization
    }
    let phase: Phase
    let elapsedSeconds: Double
    let completed: Bool
}

private struct EnginePreparationTimer {
    private var phase: EnginePreparationPhaseTiming.Phase?
    private var started = ContinuousClock.now
    private(set) var measurements: [EnginePreparationPhaseTiming] = []

    mutating func begin(_ next: EnginePreparationPhaseTiming.Phase) {
        finish(completed: true)
        phase = next
        started = ContinuousClock.now
    }
    mutating func finish(completed: Bool) {
        guard let phase else { return }
        let duration = started.duration(to: ContinuousClock.now).components
        measurements.append(.init(phase: phase,
            elapsedSeconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
            completed: completed))
        self.phase = nil
    }
}

struct EnginePerformanceReport: Codable, Identifiable, Sendable {
    enum Stage: String, Codable, Sendable { case modelLoad, alreadyLoaded, transcription }
    let id: UUID
    let date: Date
    let model: SpeechModel
    let stage: Stage
    let successful: Bool
    let resources: PerformanceReport
    let requestedBackend: String
    let preparationPhases: [EnginePreparationPhaseTiming]?
}
protocol PerformanceReportingEngine: LocalTranscriptionEngine {
    func performanceReports() async -> [EnginePerformanceReport]
}
#if canImport(FluidAudio)
@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import MoonshineVoice

/// The runtime is isolated from the main UI actor. Only explicit installation
/// uses networking; prepare and transcription load verified local files.
actor LocalModelEngine: PerformanceReportingEngine, ModelPreparationReportingEngine, StreamingLocalTranscriptionEngine, BackgroundInferenceReportingEngine {
    private struct PreparedRuntime: Sendable {
        let id = UUID()
        let model: SpeechModel
        let models: AsrModels?
        let offline: AsrManager?
        let realtime: StreamingEouAsrManager?
        var moonshine: MoonshineCPUAdapter? = nil
    }
    /// Transfers sole ownership of the previous runtime into its release phase.
    private actor PreviousRuntimeRelease {
        private var runtime: PreparedRuntime?
        init(_ runtime: PreparedRuntime?) { self.runtime = runtime }
        func release() async {
            await LocalModelEngine.cleanup(runtime)
            runtime = nil
        }
    }
    private struct PreparationFlight {
        let id: UUID
        let model: SpeechModel
        let task: Task<PreparedRuntime, Error>
        var waiters: Set<UUID>
    }
    private struct StreamState {
        let id: UUID
        let model: SpeechModel
        let windowed: SlidingWindowAsrManager?
        let realtime: StreamingEouAsrManager?
        var moonshine: MoonshineCPUAdapter? = nil
        let onUpdate: @Sendable (SpeechTranscriptUpdate) -> Void
        let probe: PerformanceProbe
        var updates: Task<Void, Never>?
        var pending: [Float] = []
        var firstWindow = true
        var acknowledgedWindows = 0
        var sampleCount = 0
        var finishing = false
    }
    private var prepared: PreparedRuntime?
    private var preparation: PreparationFlight?
    private var preparationEpoch = UUID()
    private var stage: ModelPreparationStage?
    private var releaseTask: Task<Void, Never>?
    private var preparationCleanupTask: Task<Void, Never>?
    private var streamCleanupTask: Task<Void, Never>?
    private var stream: StreamState?
    private var beginOperation: (id: UUID, task: Task<Void, Error>)?
    private var streamOperation: (id: UUID, task: Task<Void, Error>)?
    private var finishOperation: (id: UUID, task: Task<String, Error>)?
    private var offlineOperation: (id: UUID, task: Task<String, Error>)?
    private var reports: [EnginePerformanceReport] = []
    private let manifest: ModelIntegrityManifest
    private let root: URL
    private static func computeUnits(for model: SpeechModel) -> MLComputeUnits {
        model == .parakeetRealtimeEOU || model == .moonshineSmall ? .cpuOnly : model == .parakeetPhononLUT3 ? .cpuAndGPU : .cpuAndNeuralEngine
    }
    private static func backend(_ model: SpeechModel) -> String {
        if model == .moonshineSmall { return "Moonshine native ONNX Runtime CPU only; GPU and Neural Engine disabled" }
        if model == .parakeetPhononLUT3 { return "Core ML encoder CPU + GPU; other components CPU + Neural Engine; foreground inference only" }
        return computeUnits(for: model) == .cpuOnly
            ? "Core ML CPU only; GPU and Neural Engine disabled"
            : "Core ML CPU + Neural Engine; GPU disabled; foreground inference only"
    }
    private static let chunkSamples = 3 * 16_000
    private static let firstWindowSamples = 5 * 16_000

    init() throws {
        manifest = try .bundled()
        root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("SpeechModels", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excludedRoot = root
        try excludedRoot.setResourceValues(values)
        AppLogger.minimumLevel = .fault
        AppLogger.mirrorsToConsole = false
        ModelRegistry.revisionOverrides = Dictionary(manifest.models.map { ($0.repository, $0.revision) }, uniquingKeysWith: { first, _ in first })
    }
    private func entry(_ model: SpeechModel) throws -> ModelIntegrityManifest.Model {
        let id = switch model {
        case .parakeetUltra: "ultra"
        case .parakeetPhonon: "phonon2"
        case .parakeetPhononG4: "phonon2-g4"
        case .parakeetPhononG1: "phonon2-g1"
        case .parakeetPhononLUT6: "phonon2-lut6"
        case .parakeetPhononLUT3: "phonon2-lut3"
        case .moonshineSmall: "moonshine-small"
        case .parakeetRedux: "redux"
        case .parakeetRealtimeEOU: "parakeet-eou-320ms"
        }
        guard let value = manifest.models.first(where: { $0.id == id }) else { throw ModelInstallationError.missingManifest }
        return value
    }
    private func repo(_ model: SpeechModel) -> Repo {
        switch model {
        case .parakeetUltra: .parakeetUltra
        case .parakeetPhonon, .parakeetPhononG4, .parakeetPhononG1, .parakeetPhononLUT6, .parakeetPhononLUT3: .phonon2
        case .parakeetRedux: .parakeetRedux
        case .parakeetRealtimeEOU: .parakeetEou320
        case .moonshineSmall: .phonon2 // Never used for Moonshine local paths.
        }
    }
    private func version(_ model: SpeechModel) -> AsrModelVersion {
        switch model {
        case .parakeetUltra: .ultra
        case .parakeetPhonon, .parakeetPhononG4, .parakeetPhononG1, .parakeetPhononLUT6, .parakeetPhononLUT3: .phonon2
        case .parakeetRedux: .redux
        case .moonshineSmall: .phonon2 // Separate native runtime.
        case .parakeetRealtimeEOU: .phonon2 // EOU uses its separate streaming recognizer.
        }
    }
    private func location(_ model: SpeechModel) throws -> URL {
        let item = try entry(model)
        return root.appendingPathComponent("\(item.id)-\(item.revision)", isDirectory: true)
    }
    private func modelDirectory(_ model: SpeechModel) throws -> URL {
        try location(model).appendingPathComponent(model == .moonshineSmall ? "moonshine-small" : repo(model).folderName, isDirectory: true)
    }
    func isInstalled(_ model: SpeechModel) async -> Bool {
        guard let dir = try? modelDirectory(model), let item = try? entry(model) else { return false }
        let marker = dir.appendingPathComponent("localscribe-verified-revision")
        guard (try? String(contentsOf: marker, encoding: .utf8)) == item.revision else { return false }
        return item.files.allSatisfy { file in
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file.path).path)
            return (attrs?[.size] as? NSNumber)?.int64Value == file.size
        }
    }
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let installRoot = try location(model)
        let item = try entry(model)
        try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var excluded = installRoot
        try excluded.setResourceValues(resourceValues)
        let directory = try modelDirectory(model)
        try await PinnedModelDownloader.download(item, to: directory, progress: progress)
        try ModelIntegrity.verify(item, at: directory)
        try Data(item.revision.utf8).write(to: directory.appendingPathComponent("localscribe-verified-revision"), options: .atomic)
        progress(1)
    }

    func preparationStage() async -> ModelPreparationStage? { stage }
    func supportsBackgroundInference(for model: SpeechModel) async -> Bool {
        Self.computeUnits(for: model) == .cpuOnly
    }

    /// A single loading flight owns the old/new runtime transition. The synchronous
    /// Core ML load runs away from this actor, so progress and cancellation stay responsive.
    func prepare(_ model: SpeechModel) async throws {
        try Task.checkCancellation()
        if let releaseTask { await releaseTask.value }
        if let preparationCleanupTask { await preparationCleanupTask.value }
        if let streamCleanupTask { await streamCleanupTask.value }
        try Task.checkCancellation()
        guard stream == nil, offlineOperation == nil else { throw StreamingEngineError.busy }
        while let flight = preparation {
            if flight.task.isCancelled {
                _ = await flight.task.result
                // Its final waiter installs a serialized cleanup task after
                // resuming. Give that actor continuation a turn before retrying.
                await Task.yield()
                try Task.checkCancellation()
                continue
            }
            if flight.model == model { try await joinPreparation(flight); return }
            let completed = try? await flight.task.value
            try Task.checkCancellation()
            if flight.task.isCancelled { await Task.yield(); continue }
            if preparation?.id == flight.id {
                // Adopt the completed references before changing models. This
                // lets the next flight release them even if its original waiter
                // has not yet resumed to adopt the same result.
                prepared = completed
                preparation = nil
            }
        }
        if let preparationCleanupTask { await preparationCleanupTask.value }
        try Task.checkCancellation()
        if preparation != nil { try await prepare(model); return }
        guard stream == nil, offlineOperation == nil, releaseTask == nil else { throw StreamingEngineError.busy }
        if let current = prepared, current.model == model {
            stage = .ready
            let probe = await PerformanceProbe.start()
            let resources = await probe.finish()
            try Task.checkCancellation()
            guard prepared?.id == current.id else { throw CancellationError() }
            record(model, stage: .alreadyLoaded, successful: true, resources: resources)
            return
        }
        let item = try entry(model)
        let directory = try modelDirectory(model)
        let asrVersion = version(model)
        let old = PreviousRuntimeRelease(prepared)
        prepared = nil
        let id = UUID()
        preparationEpoch = id
        stage = .checkingInstallation
        let task = Task.detached(priority: .userInitiated) { [weak self] () throws -> PreparedRuntime in
            let probe = await PerformanceProbe.start()
            var timer = EnginePreparationTimer()
            timer.begin(.previousModelRelease)
            do {
                await old.release()
                try Task.checkCancellation()
                timer.begin(.installationCheck)
                guard Self.installed(item, at: directory) else { throw ModelInstallationError.missingModel }
                timer.begin(.integrityVerification)
                await self?.setPreparationStage(.verifyingFiles, id: id)
                try ModelIntegrity.verify(item, at: directory)
                try Task.checkCancellation()
                timer.begin(model == .moonshineSmall ? .nativeCPULoad : .localCoreMLLoad)
                await self?.setPreparationStage(.loadingCoreML, id: id)
                let configuration = MLModelConfiguration()
                // iOS 27 restricts background ANE access without an additional
                // inference entitlement. Realtime uses CPU throughout, including
                // encoder, decoder and joint, for the background dictation path.
                configuration.computeUnits = Self.computeUnits(for: model)
                let runtime: PreparedRuntime
                if model == .moonshineSmall {
                    let manager = try MoonshineCPUAdapter(directory: directory)
                    try Task.checkCancellation()
                    timer.begin(.recognizerInitialization)
                    await self?.setPreparationStage(.initializingRecognizer, id: id)
                    runtime = PreparedRuntime(model: model, models: nil, offline: nil, realtime: nil, moonshine: manager)
                } else if model == .parakeetRealtimeEOU {
                    let manager = StreamingEouAsrManager(configuration: configuration, chunkSize: .ms320)
                    do {
                        try await manager.loadModels(from: directory)
                        try Task.checkCancellation()
                        timer.begin(.recognizerInitialization)
                        await self?.setPreparationStage(.initializingRecognizer, id: id)
                        await manager.reset()
                        runtime = PreparedRuntime(model: model, models: nil, offline: nil, realtime: manager)
                    } catch { await manager.cleanup(); throw error }
                } else {
                    let models: AsrModels
                    if model == .parakeetPhononLUT3 || model == .parakeetPhononLUT6 {
                        configuration.computeUnits = .cpuAndNeuralEngine
                        models = try Self.loadDensePhonon(directory: directory, model: model, configuration: configuration, timer: &timer)
                    } else {
                        models = try AsrModels.loadLocal(from: directory, version: asrVersion,
                            configuration: configuration, encoderComputeUnits: configuration.computeUnits)
                    }
                    try Task.checkCancellation()
                    timer.begin(.recognizerInitialization)
                    await self?.setPreparationStage(.initializingRecognizer, id: id)
                    runtime = PreparedRuntime(model: model, models: models, offline: AsrManager(models: models), realtime: nil)
                }
                try Task.checkCancellation()
                timer.finish(completed: true)
                await self?.record(model, stage: .modelLoad, successful: true,
                                   resources: await probe.finish(), preparationPhases: timer.measurements)
                return runtime
            } catch {
                timer.finish(completed: false)
                await self?.record(model, stage: .modelLoad, successful: false,
                                   resources: await probe.finish(), preparationPhases: timer.measurements)
                throw error
            }
        }
        let flight = PreparationFlight(id: id, model: model, task: task, waiters: [])
        preparation = flight
        try await joinPreparation(flight)
    }

    private func joinPreparation(_ flight: PreparationFlight) async throws {
        guard !flight.task.isCancelled else { throw CancellationError() }
        let waiter = UUID()
        preparation?.waiters.insert(waiter)
        do {
            let runtime = try await withTaskCancellationHandler {
                try await flight.task.value
            } onCancel: {
                Task { await self.removePreparationWaiter(waiter, id: flight.id, cancelIfEmpty: true) }
            }
            try Task.checkCancellation()
            guard !flight.task.isCancelled, preparationEpoch == flight.id else { throw CancellationError() }
            prepared = runtime
            stage = .ready
            if preparation?.id == flight.id { preparation = nil }
        } catch {
            removePreparationWaiter(waiter, id: flight.id, cancelIfEmpty: true)
            if preparation?.id == flight.id, preparation?.waiters.isEmpty == true {
                preparation = nil
                let cleanup = Task {
                    if let abandoned = try? await flight.task.value { await Self.cleanup(abandoned) }
                }
                preparationCleanupTask = cleanup
                await cleanup.value
                if prepared == nil { stage = nil }
            }
            throw error
        }
    }
    private func removePreparationWaiter(_ waiter: UUID, id: UUID, cancelIfEmpty: Bool) {
        guard preparation?.id == id else { return }
        preparation?.waiters.remove(waiter)
        if cancelIfEmpty, preparation?.waiters.isEmpty == true { preparation?.task.cancel() }
    }
    private func setPreparationStage(_ value: ModelPreparationStage, id: UUID) {
        if preparationEpoch == id { stage = value }
    }
    private static func installed(_ item: ModelIntegrityManifest.Model, at directory: URL) -> Bool {
        guard (try? String(contentsOf: directory.appendingPathComponent("localscribe-verified-revision"), encoding: .utf8)) == item.revision else { return false }
        return item.files.allSatisfy {
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($0.path).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == $0.size
        }
    }
    private static func loadDensePhonon(directory: URL, model: SpeechModel,
                                        configuration: MLModelConfiguration,
                                        timer: inout EnginePreparationTimer) throws -> AsrModels {
        timer.begin(.vocabularyLoad)
        let data = try Data(contentsOf: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile))
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        let vocabulary = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Int(key).map { ($0, value) } })
        guard (0..<AsrModelVersion.phonon2.blankId).allSatisfy({ vocabulary[$0] != nil }) else {
            throw ModelInstallationError.integrity("incomplete Phonon vocabulary")
        }
        func component(_ name: String, units: MLComputeUnits,
                       phase: EnginePreparationPhaseTiming.Phase) throws -> MLModel {
            try Task.checkCancellation()
            timer.begin(phase)
            let config = MLModelConfiguration()
            config.computeUnits = units
            return try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: config)
        }
        let preprocessor = try component(ModelNames.ASR.preprocessorFile, units: .cpuOnly, phase: .preprocessorLoad)
        // Catalog installs the selected dense encoder under FluidAudio's
        // canonical Encoder.mlmodelc path; no runtime artifact substitution.
        let encoder = try component(ModelNames.ASR.encoderFile,
            units: model == .parakeetPhononLUT3 ? .cpuAndGPU : .cpuAndNeuralEngine, phase: .encoderLoad)
        let decoder = try component(ModelNames.ASR.decoderFile, units: .cpuAndNeuralEngine, phase: .decoderLoad)
        let joint = try component(ModelNames.ASR.jointV3File, units: .cpuAndNeuralEngine, phase: .jointLoad)
        return AsrModels(encoder: encoder, preprocessor: preprocessor, decoder: decoder, joint: joint,
                         configuration: configuration, vocabulary: vocabulary, version: .phonon2)
    }

    private static func cleanup(_ runtime: PreparedRuntime?) async {
        await runtime?.offline?.cleanup()
        await runtime?.realtime?.cleanup()
        await runtime?.moonshine?.unload()
    }
    private func record(_ model: SpeechModel, stage: EnginePerformanceReport.Stage, successful: Bool,
                        resources: PerformanceReport, backend: String? = nil,
                        preparationPhases: [EnginePreparationPhaseTiming]? = nil) {
        reports.append(.init(id: UUID(), date: Date(), model: model, stage: stage,
                            successful: successful, resources: resources, requestedBackend: backend ?? Self.backend(model),
                            preparationPhases: preparationPhases))
        reports = Array(reports.suffix(20))
    }
    func performanceReports() async -> [EnginePerformanceReport] { reports }

    func unload() async {
        if let releaseTask { await releaseTask.value; return }
        preparationEpoch = UUID()
        let loading = preparation?.task
        loading?.cancel()
        let runtime = prepared
        prepared = nil
        stage = nil
        let cancelling = startStreamCleanup()
        let offline = offlineOperation?.task
        let abandonedPreparation = preparationCleanupTask
        offline?.cancel()
        let task = Task {
            await abandonedPreparation?.value
            await cancelling?.value
            _ = await offline?.result
            if let abandoned = try? await loading?.value { await Self.cleanup(abandoned) }
            await Self.cleanup(runtime)
        }
        releaseTask = task
        await task.value
        preparation = nil
        releaseTask = nil
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard !samples.isEmpty, samples.count <= 16_000 * 120, samples.allSatisfy(\.isFinite) else {
            throw ModelInstallationError.integrity("invalid audio")
        }
        guard stream == nil, offlineOperation == nil, let runtime = prepared else { throw StreamingEngineError.busy }
        // The fixture/offline API remains independent of the microphone streaming session.
        let id = UUID()
        let task = Task { [weak self] () throws -> String in
            let probe = await PerformanceProbe.start()
            do {
                try Task.checkCancellation()
                let text: String
                if let moonshine = runtime.moonshine {
                    text = try await moonshine.transcribe(samples)
                } else if let manager = runtime.offline {
                    var state = try TdtDecoderState()
                    text = try await manager.transcribe(samples, decoderState: &state).text
                } else if let realtime = runtime.realtime {
                    await realtime.reset()
                    for offset in stride(from: 0, to: samples.count, by: 32_000) {
                        try Task.checkCancellation()
                        let buffer = try Self.pcm(Array(samples[offset..<min(samples.count, offset + 32_000)]))
                        try await realtime.appendAudio(buffer)
                        try await realtime.processBufferedAudio()
                    }
                    text = try await realtime.finish()
                    await realtime.reset()
                } else { throw ModelInstallationError.missingModel }
                try Task.checkCancellation()
                await self?.record(runtime.model, stage: .transcription, successful: true,
                                   resources: await probe.finish(audioSeconds: Double(samples.count) / 16_000))
                return text
            } catch {
                await runtime.realtime?.reset()
                await runtime.moonshine?.cancel()
                await self?.record(runtime.model, stage: .transcription, successful: false,
                                   resources: await probe.finish(audioSeconds: Double(samples.count) / 16_000))
                throw error
            }
        }
        offlineOperation = (id, task)
        defer { if offlineOperation?.id == id { offlineOperation = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func beginStreaming(onUpdate: @escaping @Sendable (SpeechTranscriptUpdate) -> Void) async throws {
        if let streamCleanupTask { await streamCleanupTask.value }
        try Task.checkCancellation()
        guard stream == nil, offlineOperation == nil, preparation == nil, releaseTask == nil,
              let runtime = prepared else { throw StreamingEngineError.busy }
        let id = UUID()
        let probe = await PerformanceProbe.start()
        guard stream == nil, offlineOperation == nil, preparation == nil, releaseTask == nil,
              prepared?.id == runtime.id else { _ = await probe.finish(); throw StreamingEngineError.busy }
        let manager: SlidingWindowAsrManager?
        if runtime.models != nil {
            // Re-decode up to the full model context while keeping a three-second
            // update cadence. Device WER measurements determine whether this
            // wider context improves seams; confirmation only affects display.
            let configuration = SlidingWindowAsrConfig(chunkSeconds: 3, hypothesisChunkSeconds: 1,
                leftContextSeconds: 10, rightContextSeconds: 2, minContextForConfirmation: 10,
                confirmationThreshold: 0.8)
            manager = SlidingWindowAsrManager(config: configuration)
        } else { manager = nil }
        stream = StreamState(id: id, model: runtime.model, windowed: manager, realtime: runtime.realtime,
                             moonshine: runtime.moonshine, onUpdate: onUpdate, probe: probe)
        let operationID = UUID()
        let task = Task { try await self.startStreamingSession(runtime, id: id) }
        beginOperation = (operationID, task)
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard stream?.id == id else { throw CancellationError() }
            if beginOperation?.id == operationID { beginOperation = nil }
            onUpdate(.init(confirmedText: "", volatileText: ""))
        } catch {
            if beginOperation?.id == operationID { beginOperation = nil }
            await cancelStreaming()
            throw error
        }
    }

    private func startStreamingSession(_ runtime: PreparedRuntime, id: UUID) async throws {
        try Task.checkCancellation()
        guard stream?.id == id else { throw CancellationError() }
        if let moonshine = runtime.moonshine {
            try await moonshine.begin()
        } else if let realtime = runtime.realtime {
            await realtime.reset()
            try Task.checkCancellation()
            guard stream?.id == id, let callback = stream?.onUpdate else { throw CancellationError() }
            await realtime.setPartialTranscriptCallback { text in
                callback(.init(confirmedText: "", volatileText: text))
            }
        } else if let models = runtime.models, let manager = stream?.windowed {
            try await manager.loadModels(models)
            try Task.checkCancellation()
            guard stream?.id == id else { throw CancellationError() }
            let updates = await manager.transcriptionUpdates
            let observer = Task { [weak self] in
                for await _ in updates {
                    guard !Task.isCancelled else { break }
                    await self?.receiveWindowUpdate(id: id, manager: manager)
                }
            }
            stream?.updates = observer
            try await manager.startStreaming(source: .microphone)
        } else { throw ModelInstallationError.missingModel }
        try Task.checkCancellation()
        guard stream?.id == id else { throw CancellationError() }
    }

    private func receiveWindowUpdate(id: UUID, manager: SlidingWindowAsrManager) async {
        guard stream?.id == id else { return }
        let confirmed = await manager.confirmedTranscript
        let provisional = await manager.volatileTranscript
        guard stream?.id == id else { return }
        stream?.acknowledgedWindows += 1
        stream?.onUpdate(.init(confirmedText: confirmed, volatileText: provisional))
    }

    func appendStreaming(samples: [Float]) async throws {
        try Task.checkCancellation()
        guard !samples.isEmpty else { return }
        guard samples.count <= 32_000, samples.allSatisfy(\.isFinite) else { throw StreamingEngineError.invalidAudio }
        guard let state = stream, !state.finishing, beginOperation == nil, streamOperation == nil else { throw StreamingEngineError.busy }
        let operationID = UUID()
        let task = Task { try await self.processStreamingSamples(samples, id: state.id) }
        streamOperation = (operationID, task)
        defer { if streamOperation?.id == operationID { streamOperation = nil } }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if streamOperation?.id == operationID { streamOperation = nil }
            await cancelStreaming()
            throw error
        }
    }

    private func processStreamingSamples(_ samples: [Float], id: UUID) async throws {
        guard stream?.id == id else { throw CancellationError() }
        stream?.sampleCount += samples.count
        if let moonshine = stream?.moonshine {
            let update = try await moonshine.append(samples)
            try Task.checkCancellation()
            guard stream?.id == id else { throw CancellationError() }
            if let update { stream?.onUpdate(update) }
            return
        }
        if let realtime = stream?.realtime {
            try await realtime.appendAudio(Self.pcm(samples))
            try await realtime.processBufferedAudio()
            try Task.checkCancellation()
            guard stream?.id == id else { throw CancellationError() }
            return
        }
        guard let manager = stream?.windowed else { throw ModelInstallationError.missingModel }
        stream?.pending.append(contentsOf: samples)
        while stream?.id == id {
            let required = stream?.firstWindow == true ? Self.firstWindowSamples : Self.chunkSamples
            guard let pending = stream?.pending, pending.count >= required else { break }
            let expected = (stream?.acknowledgedWindows ?? 0) + 1
            await manager.streamAudio(try Self.pcm(Array(pending.prefix(required))))
            try await waitForWindows(expected, id: id, seconds: 30)
            guard stream?.id == id else { throw CancellationError() }
            stream?.pending.removeFirst(required)
            stream?.firstWindow = false
        }
    }

    private func waitForWindows(_ expected: Int, id: UUID, seconds: Double) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while true {
            try Task.checkCancellation()
            guard stream?.id == id else { throw CancellationError() }
            if (stream?.acknowledgedWindows ?? 0) >= expected { return }
            guard ContinuousClock.now < deadline else { throw StreamingEngineError.processingStopped }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func finishStreaming() async throws -> String {
        guard var state = stream, !state.finishing, beginOperation == nil, streamOperation == nil else { throw StreamingEngineError.busy }
        state.finishing = true
        stream = state
        let operationID = UUID()
        let task = Task { () throws -> String in
            if let moonshine = state.moonshine { return try await moonshine.finish() }
            if let realtime = state.realtime { return try await realtime.finish() }
            guard let manager = state.windowed else { throw ModelInstallationError.missingModel }
            if !state.pending.isEmpty { await manager.streamAudio(try Self.pcm(state.pending)) }
            let text = try await manager.finish()
            // finish() suppresses partial-window errors upstream. Require one
            // acknowledgement per remaining window, including silent windows.
            let expected = Int(ceil(Double(state.sampleCount) / Double(Self.chunkSamples)))
            try await self.waitForWindows(expected, id: state.id, seconds: 5)
            return text
        }
        finishOperation = (operationID, task)
        do {
            let text = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard stream?.id == state.id else { throw CancellationError() }
            record(state.model, stage: .transcription, successful: true,
                   resources: await state.probe.finish(audioSeconds: Double(state.sampleCount) / 16_000),
                   backend: Self.backend(state.model) + "; live session elapsed includes recording and backpressure waits")
            if finishOperation?.id == operationID { finishOperation = nil }
            await cancelStreaming()
            return text
        } catch {
            record(state.model, stage: .transcription, successful: false,
                   resources: await state.probe.finish(audioSeconds: Double(state.sampleCount) / 16_000),
                   backend: Self.backend(state.model) + "; live session elapsed includes recording and backpressure waits")
            if finishOperation?.id == operationID { finishOperation = nil }
            await cancelStreaming()
            throw error
        }
    }

    private func startStreamCleanup() -> Task<Void, Never>? {
        guard let state = stream else { return streamCleanupTask }
        stream = nil
        state.updates?.cancel()
        let starting = beginOperation?.task
        let processing = streamOperation?.task
        let finishing = finishOperation?.task
        starting?.cancel()
        processing?.cancel()
        finishing?.cancel()
        let previous = streamCleanupTask
        let task = Task {
            await previous?.value
            _ = await starting?.result
            _ = await processing?.result
            _ = await finishing?.result
            if let manager = state.windowed {
                await manager.cancel()
                _ = try? await manager.finish()
                await manager.cleanup()
            }
            if let manager = state.realtime {
                await manager.setPartialTranscriptCallback { _ in }
                await manager.reset()
            }
            await state.moonshine?.cancel()
            _ = await state.probe.finish()
        }
        streamCleanupTask = task
        return task
    }
    func cancelStreaming() async {
        let task = startStreamCleanup()
        await task?.value
    }
    private static func pcm(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                        channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw StreamingEngineError.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in channel.update(from: source.baseAddress!, count: samples.count) }
        return buffer
    }
}

private enum StreamingEngineError: LocalizedError {
    case busy, invalidAudio, processingStopped
    var errorDescription: String? {
        switch self {
        case .busy: "The speech model is busy. Wait for the current operation to finish."
        case .invalidAudio: "Live audio must be finite mono 16 kHz samples in ordered batches of at most two seconds."
        case .processingStopped: "The speech model did not acknowledge an audio window. Recording stopped to avoid losing words; your recognized text is preserved."
        }
    }
}
#else
actor LocalModelEngine: PerformanceReportingEngine, ModelPreparationReportingEngine, StreamingLocalTranscriptionEngine, BackgroundInferenceReportingEngine {
    init() throws {}
    func isInstalled(_ model: SpeechModel) async -> Bool { false }
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws { throw ModelInstallationError.noRuntime }
    func prepare(_ model: SpeechModel) async throws { throw ModelInstallationError.noRuntime }
    func transcribe(samples: [Float]) async throws -> String { throw ModelInstallationError.noRuntime }
    func beginStreaming(onUpdate: @escaping @Sendable (SpeechTranscriptUpdate) -> Void) async throws { throw ModelInstallationError.noRuntime }
    func appendStreaming(samples: [Float]) async throws { throw ModelInstallationError.noRuntime }
    func finishStreaming() async throws -> String { throw ModelInstallationError.noRuntime }
    func cancelStreaming() async {}
    func unload() async {}
    func preparationStage() async -> ModelPreparationStage? { nil }
    func supportsBackgroundInference(for model: SpeechModel) async -> Bool { false }
    func performanceReports() async -> [EnginePerformanceReport] { [] }
}
#endif
