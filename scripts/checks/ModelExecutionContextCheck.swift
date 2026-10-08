import CoreML
import Foundation
import LocalScribeCore

// This records model constructor requests. No compiled model is loaded or run.
final class FixtureCoreMLModel: @unchecked Sendable {
    let name: String
    let units: MLComputeUnits
    let allowLowPrecisionAccumulationOnGPU: Bool
    private init(contentsOf url: URL, configuration: MLModelConfiguration) {
        name = url.lastPathComponent
        units = configuration.computeUnits
        allowLowPrecisionAccumulationOnGPU = configuration.allowLowPrecisionAccumulationOnGPU
    }
    static func load(contentsOf url: URL, configuration: MLModelConfiguration) async throws -> FixtureCoreMLModel {
        let shouldFail = await FixtureLoaderLedger.shared.begin(url.lastPathComponent)
        await Task.yield()
        await FixtureLoaderLedger.shared.finish()
        if shouldFail { throw FixtureLoaderFailure.requested }
        return FixtureCoreMLModel(contentsOf: url, configuration: configuration)
    }
}
struct AsrModels {
    let encoder: FixtureCoreMLModel
    let preprocessor: FixtureCoreMLModel
    let decoder: FixtureCoreMLModel
    let joint: FixtureCoreMLModel
    let ctcHead: FixtureCoreMLModel?
    let configuration: MLModelConfiguration
    let vocabulary: [Int: String]
    let version: AsrModelVersion
}
enum AsrModelVersion { case phonon2; var blankId: Int { 4 } }
enum AsrModelsError: Error {
    case loadingFailed(String), modelNotFound(String, URL)
}
actor FixtureProgressRecorder {
    private(set) var updates: [EnginePreparationProgress] = []
    func append(_ update: EnginePreparationProgress) { updates.append(update) }
}
enum ModelNames {
    enum ASR {
        static let vocabularyFile = "parakeet_vocab.json"
        static let encoderFile = "Encoder.mlmodelc"
        static let preprocessorFile = "Preprocessor.mlmodelc"
        static let decoderFile = "Decoder.mlmodelc"
        static let jointV3File = "JointDecisionv3.mlmodelc"
        static let ctcHeadFile = "CtcHead.mlmodelc"
    }
}
struct FixturePreparationTimer {
    var phases: [EnginePreparationPhaseTiming.Phase] = []
    mutating func begin(_ phase: EnginePreparationPhaseTiming.Phase) { phases.append(phase) }
}

@main struct ModelExecutionContextCheck {
    static func main() async throws {
        var count = 0
        func check(_ result: @autoclosure () -> Bool, _ label: String) {
            precondition(result(), label)
            count += 1
        }
        let cpuModels: [SpeechModel] = [.parakeetRealtimeEOU, .moonshineSmall]
        for model in SpeechModel.allCases {
            let foreground = LocalModelExecutionConfiguration(model: model, context: .foreground)
            let background = LocalModelExecutionConfiguration(model: model, context: .backgroundCapable)
            check(background.computeUnits == .cpuOnly, "background decoder/joint are CPU-only: \(model)")
            check(background.encoderComputeUnits == .cpuOnly, "background encoder is CPU-only: \(model)")
            check(background.supportsBackgroundInference, "background eligibility: \(model)")
            check(background.backend.contains("CPU only") && background.backend.contains("disabled"), "CPU reporting: \(model)")
            if cpuModels.contains(model) {
                check(foreground == background, "CPU runtime reuse across contexts: \(model)")
                check(foreground.supportsBackgroundInference, "CPU default eligibility: \(model)")
            } else {
                check(foreground != background, "accelerator runtime must not satisfy CPU request: \(model)")
                check(foreground.computeUnits == .cpuAndNeuralEngine, "foreground decoder/joint remain ANE eligible: \(model)")
                check(foreground.encoderComputeUnits == (model == .parakeetPhononLUT3 ? .cpuAndGPU : .cpuAndNeuralEngine), "foreground encoder preserved: \(model)")
                check(!foreground.supportsBackgroundInference, "accelerators remain foreground-only: \(model)")
                check(foreground.backend.contains("foreground inference only"), "foreground label: \(model)")
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"0":"one","1":"two","2":"three","3":"four"}"#.utf8)
            .write(to: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile))
        for name in [ModelNames.ASR.encoderFile, ModelNames.ASR.preprocessorFile, ModelNames.ASR.decoderFile, ModelNames.ASR.jointV3File] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        for model in [SpeechModel.parakeetPhonon, .parakeetPhononG4, .parakeetPhononG1, .parakeetPhononLUT3, .parakeetPhononLUT6] {
            for context in [ModelExecutionContext.foreground, .backgroundCapable] {
                let execution = LocalModelExecutionConfiguration(model: model, context: context)
                let config = MLModelConfiguration()
                config.computeUnits = execution.computeUnits
                config.allowLowPrecisionAccumulationOnGPU = true
                var timer = FixturePreparationTimer()
                let progress = FixtureProgressRecorder()
                let models = try await EngineContextFixture.loadPhonon(directory: directory, execution: execution, configuration: config, timer: &timer) {
                    await progress.append($0)
                }
                let cpu = context == .backgroundCapable
                check(models.preprocessor.units == .cpuOnly, "preprocessor always CPU-only")
                check(models.encoder.units == (cpu ? .cpuOnly : model == .parakeetPhononLUT3 ? .cpuAndGPU : .cpuAndNeuralEngine), "actual Phonon encoder constructor request")
                check(models.decoder.units == (cpu ? .cpuOnly : .cpuAndNeuralEngine), "actual Phonon decoder constructor request")
                check(models.joint.units == (cpu ? .cpuOnly : .cpuAndNeuralEngine), "actual Phonon joint constructor request")
                check(models.configuration.computeUnits == models.decoder.units, "container config matches Phonon components")
                check(models.encoder.name == "Encoder.mlmodelc", "same canonical installed encoder asset")
                check(timer.phases == [.vocabularyLoad, .encoderLoad, .preprocessorLoad, .decoderLoad, .jointLoad], "pinned component order retained")
                check(models.encoder.allowLowPrecisionAccumulationOnGPU && models.decoder.allowLowPrecisionAccumulationOnGPU, "pinned config flag propagated")
                check(models.ctcHead == nil, "absent optional CTC is not loaded")
                let updates = await progress.updates
                check(updates.map(\.completedComponents) == [0, 1, 1, 2, 2, 3, 3, 4, 4, 5], "progress counts actual completed components")
                check(updates.allSatisfy { $0.totalComponents == 5 }, "vocabulary plus four models reported")
            }
        }
        let probeReport = PerformanceReport(elapsedSeconds: 0, audioSeconds: nil, processCPUSeconds: nil,
            initialPhysicalFootprintBytes: nil, sampledPeakPhysicalFootprintBytes: nil, finalPhysicalFootprintBytes: nil,
            initialProcessLifetimePeakPhysicalFootprintBytes: nil, finalProcessLifetimePeakPhysicalFootprintBytes: nil,
            memorySampleCount: 0, memorySamplingIntervalSeconds: 0.05, initialThermalState: .unknown, finalThermalState: .unknown)
        let recorder = EngineContextFixture()
        let action = LocalModelExecutionConfiguration(model: .parakeetPhononLUT3, context: .backgroundCapable)
        for stage in [EnginePerformanceReport.Stage.modelLoad, .alreadyLoaded, .transcription] {
            for success in [true, false] {
                recorder.record(action, stage: stage, successful: success, resources: probeReport)
                check(recorder.reports.last?.requestedBackend == "Core ML CPU only; GPU and Neural Engine disabled", "all operation reports use supplied frozen CPU config")
                check(recorder.reports.last?.model == .parakeetPhononLUT3, "report preserves selected model")
                check(recorder.reports.last?.executionContext == .backgroundCapable, "report preserves actual normalized configuration context")
            }
        }
        let encodedReport = try JSONEncoder().encode(recorder.reports.last!)
        let decodedReport = try JSONDecoder().decode(EnginePerformanceReport.self, from: encodedReport)
        check(decodedReport.executionContext == .backgroundCapable, "execution context round-trips")
        var legacyReport = try JSONSerialization.jsonObject(with: encodedReport) as! [String: Any]
        legacyReport.removeValue(forKey: "executionContext")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyReport)
        let decodedLegacy = try JSONDecoder().decode(EnginePerformanceReport.self, from: legacyData)
        check(decodedLegacy.executionContext == nil, "legacy report without context decodes as unknown")
        count += try await PhononLoaderContractCheck.run(directory: directory)
        print("PASS: \(count) execution policy, async Phonon constructor/progress and reporting checks (no model loading/inference)")
    }
}
