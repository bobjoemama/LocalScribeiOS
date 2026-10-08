import Foundation
import LocalScribeCore

@main struct ModelPerformanceStoreCheck {
    enum Failure: Error { case check(String) }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ModelPerformanceStoreCheck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ModelPerformance/load-reports.json")
        let store = ModelPerformanceStore(file: file)
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw Failure.check(message) }
            checks += 1
        }
        let provenance = ModelMeasurementProvenance(hardwareIdentifier: "fixture-machine", operatingSystemVersion: "fixture-OS", appVersion: "fixture-build")
        func report(model: SpeechModel = .parakeetPhonon, context: ModelExecutionContext? = .backgroundCapable,
                    date: Double = 1, success: Bool = true, stage: EnginePerformanceReport.Stage = .modelLoad,
                    elapsed: Double = 12, samples: Int = 2, interval: Double = 0.05) -> EnginePerformanceReport {
            .init(id: UUID(), date: Date(timeIntervalSinceReferenceDate: date), model: model, stage: stage,
                  successful: success, resources: .init(elapsedSeconds: elapsed, audioSeconds: nil, processCPUSeconds: nil,
                    initialPhysicalFootprintBytes: nil, sampledPeakPhysicalFootprintBytes: nil, finalPhysicalFootprintBytes: nil,
                    initialProcessLifetimePeakPhysicalFootprintBytes: nil, finalProcessLifetimePeakPhysicalFootprintBytes: nil,
                    memorySampleCount: samples, memorySamplingIntervalSeconds: interval,
                    initialThermalState: .unknown, finalThermalState: .unknown), requestedBackend: "fixture backend",
                  preparationPhases: [.init(phase: .encoderLoad, elapsedSeconds: elapsed, completed: success)], executionContext: context)
        }
        let missing = try await store.load()
        try check(missing.isEmpty, "Missing measurement file is an unmeasured catalog")
        let ignored = try await store.merge([report(stage: .transcription), report(stage: .alreadyLoaded)], provenance: provenance)
        try check(ignored.isEmpty && !FileManager.default.fileExists(atPath: file.path), "Only model loads persist; empty/reuse snapshots create no file")
        let cpu = report(date: 2)
        let foreground = report(context: .foreground, date: 1)
        let first = try await store.merge([cpu, foreground], provenance: provenance)
        try check(first.count == 2 && first[0].id == cpu.id, "Actual foreground and CPU contexts remain distinct and date ordered")
        try check(first[0].hardwareIdentifier == provenance.hardwareIdentifier && first[0].operatingSystemVersion == provenance.operatingSystemVersion
                  && first[0].appVersion == provenance.appVersion, "Measurement provenance belongs to the process that produced it")
        try check(first[0].resources.sampledPeakPhysicalFootprintBytes == nil && first[0].resources.processCPUSeconds == nil,
                  "Unavailable resource counters remain unavailable rather than becoming zero")
        let recreated = ModelPerformanceStore(file: file)
        let restored = try await recreated.load()
        try check(restored.map(\.id) == first.map(\.id) && restored[0].preparationPhases?.first?.phase == .encoderLoad,
                  "A recreated store restores load identity, contexts and phase timings")
        let failed = report(date: 3, success: false)
        let afterFailure = try await store.merge([failed, cpu, foreground], provenance: provenance)
        try check(afterFailure.count == 2 && afterFailure[0].id == failed.id && !afterFailure[0].successful
                  && afterFailure[0].preparationPhases?.first?.completed == false,
                  "The latest failed attempt replaces an older success in the same context without pretending completion")
        let otherProvenance = ModelMeasurementProvenance(hardwareIdentifier: "other", operatingSystemVersion: "other", appVersion: "other")
        let duplicate = try await store.merge([failed], provenance: otherProvenance)
        try check(duplicate[0].hardwareIdentifier == provenance.hardwareIdentifier, "Repeated engine snapshots never relabel provenance")
        let bytesBeforeInvalid = try Data(contentsOf: file)
        for invalid in [report(elapsed: .nan), report(elapsed: -.infinity), report(samples: -1), report(interval: 0)] {
            do { _ = try await store.merge([invalid], provenance: provenance); throw Failure.check("Invalid resources were accepted") }
            catch is ModelPerformanceStore.Failure { checks += 1 }
            try check(try Data(contentsOf: file) == bytesBeforeInvalid, "Invalid summaries preserve the previous saved bytes")
        }
        var allModels: [EnginePerformanceReport] = []
        for model in SpeechModel.allCases {
            allModels.append(report(model: model, context: ModelExecutionContext.foreground.normalized(for: model), date: 10))
            allModels.append(report(model: model, context: ModelExecutionContext.backgroundCapable.normalized(for: model), date: 11))
            allModels.append(report(model: model, context: nil, date: 9))
        }
        let bounded = try await store.merge(allModels, provenance: provenance)
        try check(bounded.count <= SpeechModel.allCases.count * 2 && Set(bounded.map(\.model)).count == SpeechModel.allCases.count,
                  "Stored summaries cover all catalog models and remain bounded by two contexts per model")
        let unknown = report(model: .moonshineSmall, context: nil, date: 12)
        let withUnknown = try await store.merge([unknown], provenance: provenance)
        try check(withUnknown.first?.executionContext == nil && withUnknown.first?.requestedBackend == "fixture backend",
                  "Legacy missing context remains unknown; backend text is not interpreted")
        let json = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        try check(!json.contains("transcript") && !json.contains("deviceName") && !json.contains("serialNumber") && !json.contains("UDID"),
                  "The stored schema contains no speech or personal device identity")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "Host measurement files have owner-only permissions")
        let excluded = try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        try check(excluded == true, "Model measurements are excluded from backups")
        let corrupted = Data("{invalid measurement JSON".utf8)
        try corrupted.write(to: file)
        do { _ = try await store.merge([report(date: 20)], provenance: provenance); throw Failure.check("Corrupt saved data was overwritten") }
        catch is DecodingError { checks += 1 }
        try check(try Data(contentsOf: file) == corrupted, "Corrupt existing measurements are preserved for recovery")
        print("PASS: \(checks) model measurement store checks")
    }
}
