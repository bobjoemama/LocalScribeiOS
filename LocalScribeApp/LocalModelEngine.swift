import Foundation
import LocalScribeCore

struct EnginePerformanceReport: Codable, Identifiable, Sendable {
    enum Stage: String, Codable, Sendable { case modelLoad, alreadyLoaded, transcription }
    let id: UUID
    let date: Date
    let model: SpeechModel
    let stage: Stage
    let successful: Bool
    let resources: PerformanceReport
    let requestedBackend: String
}
protocol PerformanceReportingEngine: LocalTranscriptionEngine {
    func performanceReports() async -> [EnginePerformanceReport]
}
#if canImport(FluidAudio)
import CoreML
import FluidAudio

/// The runtime is isolated from the main UI actor. Only explicit installation
/// uses networking; prepare and transcription load verified local files.
actor LocalModelEngine: PerformanceReportingEngine {
    private var manager: AsrManager?
    private var loadedModel: SpeechModel?
    private var reports: [EnginePerformanceReport] = []
    private let manifest: ModelIntegrityManifest
    private let root: URL

    init() throws {
        manifest = try .bundled()
        root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("SpeechModels", isDirectory: true)
        AppLogger.minimumLevel = .fault
        AppLogger.mirrorsToConsole = false
        // Immutable upstream revisions; never resolve Hugging Face's moving main.
        ModelRegistry.revisionOverrides = Dictionary(manifest.models.map { ($0.repository, $0.revision) }, uniquingKeysWith: { first, _ in first })
    }

    private func entry(_ model: SpeechModel) throws -> ModelIntegrityManifest.Model {
        let id = switch model {
        case .parakeetUltra: "ultra"
        case .parakeetPhonon: "phonon2"
        case .parakeetPhononG4: "phonon2-g4"
        case .parakeetPhononG1: "phonon2-g1"
        case .parakeetRedux: "redux"
        }
        guard let value = manifest.models.first(where: { $0.id == id }) else { throw ModelInstallationError.missingManifest }
        return value
    }
    private func repo(_ model: SpeechModel) -> Repo {
        switch model {
        case .parakeetUltra: .parakeetUltra
        case .parakeetPhonon, .parakeetPhononG4, .parakeetPhononG1: .phonon2
        case .parakeetRedux: .parakeetRedux
        }
    }
    private func version(_ model: SpeechModel) -> AsrModelVersion {
        switch model {
        case .parakeetUltra: .ultra
        case .parakeetPhonon, .parakeetPhononG4, .parakeetPhononG1: .phonon2
        case .parakeetRedux: .redux
        }
    }
    private func location(_ model: SpeechModel) throws -> URL {
        let item = try entry(model)
        return root.appendingPathComponent("\(item.id)-\(item.revision)", isDirectory: true)
    }
    private func modelDirectory(_ model: SpeechModel) throws -> URL {
        try location(model).appendingPathComponent(repo(model).folderName, isDirectory: true)
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
        if model == .parakeetPhononG4 || model == .parakeetPhononG1 {
            try await PinnedModelDownloader.download(item, to: directory, progress: progress)
        } else {
            try await ModelHub.download(repo(model), to: installRoot, progressHandler: { value in progress(min(0.95, value.fractionCompleted * 0.95)) })
        }
        try ModelIntegrity.verify(item, at: directory)
        try Data(item.revision.utf8).write(to: directory.appendingPathComponent("localscribe-verified-revision"), options: .atomic)
        progress(1)
    }
    func prepare(_ model: SpeechModel) async throws {
        let probe = await PerformanceProbe.start()
        let cached = loadedModel == model && manager != nil
        do {
            guard await isInstalled(model) else { throw ModelInstallationError.missingModel }
            if !cached {
                let directory = try modelDirectory(model)
                try ModelIntegrity.verify(try entry(model), at: directory)
                await manager?.cleanup()
                manager = nil
                loadedModel = nil
                let configuration = MLModelConfiguration()
                // GPU work cannot run in the background on iOS. ANE is power efficient.
                configuration.computeUnits = .cpuAndNeuralEngine
                let models = try AsrModels.loadLocal(from: directory, version: version(model), configuration: configuration, encoderComputeUnits: .cpuAndNeuralEngine)
                let recognizer = AsrManager()
                try await recognizer.loadModels(models)
                manager = recognizer
                loadedModel = model
            }
            record(model, stage: cached ? .alreadyLoaded : .modelLoad, successful: true, resources: await probe.finish())
        } catch {
            record(model, stage: cached ? .alreadyLoaded : .modelLoad, successful: false, resources: await probe.finish())
            throw error
        }
    }
    private func record(_ model: SpeechModel, stage: EnginePerformanceReport.Stage, successful: Bool, resources: PerformanceReport) {
        reports.append(.init(id: UUID(), date: Date(), model: model, stage: stage, successful: successful, resources: resources, requestedBackend: "Core ML CPU + Neural Engine; GPU disabled"))
        reports = Array(reports.suffix(20))
    }
    func performanceReports() async -> [EnginePerformanceReport] { reports }
    func unload() async {
        await manager?.cleanup()
        manager = nil
        loadedModel = nil
    }
    func transcribe(samples: [Float]) async throws -> String {
        guard let manager else { throw ModelInstallationError.missingModel }
        guard !samples.isEmpty, samples.count <= 16_000 * 120, samples.allSatisfy(\.isFinite) else {
            throw ModelInstallationError.integrity("invalid audio")
        }
        guard let model = loadedModel else { throw ModelInstallationError.missingModel }
        let probe = await PerformanceProbe.start()
        do {
            var state = try TdtDecoderState()
            let text = try await manager.transcribe(samples, decoderState: &state).text
            record(model, stage: .transcription, successful: true, resources: await probe.finish(audioSeconds: Double(samples.count) / 16_000))
            return text
        } catch {
            record(model, stage: .transcription, successful: false, resources: await probe.finish(audioSeconds: Double(samples.count) / 16_000))
            throw error
        }
    }
}
#else
actor LocalModelEngine: PerformanceReportingEngine {
    init() throws {}
    func isInstalled(_ model: SpeechModel) async -> Bool { false }
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws { throw ModelInstallationError.noRuntime }
    func prepare(_ model: SpeechModel) async throws { throw ModelInstallationError.noRuntime }
    func transcribe(samples: [Float]) async throws -> String { throw ModelInstallationError.noRuntime }
    func unload() async {}
    func performanceReports() async -> [EnginePerformanceReport] { [] }
}
#endif
