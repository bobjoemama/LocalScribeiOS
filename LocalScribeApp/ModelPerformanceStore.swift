import Foundation
import LocalScribeCore
#if canImport(Darwin)
import Darwin
#endif

struct ModelPreparationReport: Codable, Identifiable, Sendable {
    let report: EnginePerformanceReport
    let hardwareIdentifier: String?
    let operatingSystemVersion: String?
    let appVersion: String?

    var id: UUID { report.id }
    var model: SpeechModel { report.model }
    var date: Date { report.date }
    var successful: Bool { report.successful }
    var requestedBackend: String { report.requestedBackend }
    var executionContext: ModelExecutionContext? { report.executionContext }
    var resources: PerformanceReport { report.resources }
    var preparationPhases: [EnginePreparationPhaseTiming]? { report.preparationPhases }
}

struct ModelMeasurementProvenance: Sendable {
    let hardwareIdentifier: String?
    let operatingSystemVersion: String?
    let appVersion: String?

    static func current() -> Self {
        var hardware: String?
        #if canImport(Darwin)
        var length = 0
        if sysctlbyname("hw.machine", nil, &length, nil, 0) == 0, length > 0 {
            var bytes = [CChar](repeating: 0, count: length)
            if sysctlbyname("hw.machine", &bytes, &length, nil, 0) == 0 {
                hardware = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let app = version.map { version in build.map { "\(version) (\($0))" } ?? version }
        return .init(hardwareIdentifier: hardware,
                     operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                     appVersion: app)
    }
}

/// Device-local summaries only: no audio, transcript or personal device identity.
/// File work runs on this actor, away from the interface actor.
actor ModelPerformanceStore {
    enum Failure: LocalizedError {
        case invalidReport, unsupportedSchema
        var errorDescription: String? {
            switch self {
            case .invalidReport: "Saved model measurements contain invalid values."
            case .unsupportedSchema: "Saved model measurements use an unsupported format."
            }
        }
    }
    private struct Snapshot: Codable {
        var schemaVersion = 1
        let reports: [ModelPreparationReport]
    }
    let file: URL

    init(file: URL) { self.file = file }

    func load() throws -> [ModelPreparationReport] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        guard snapshot.schemaVersion == 1 else { throw Failure.unsupportedSchema }
        guard snapshot.reports.allSatisfy(Self.valid) else { throw Failure.invalidReport }
        return Self.latest(snapshot.reports)
    }

    func merge(_ reports: [EnginePerformanceReport], provenance: ModelMeasurementProvenance) throws -> [ModelPreparationReport] {
        let existing = try load()
        let additions = reports.filter { $0.stage == .modelLoad }.map {
            ModelPreparationReport(report: $0, hardwareIdentifier: provenance.hardwareIdentifier,
                                   operatingSystemVersion: provenance.operatingSystemVersion,
                                   appVersion: provenance.appVersion)
        }
        guard additions.allSatisfy(Self.valid) else { throw Failure.invalidReport }
        // Repeated engine snapshots must not relabel an older measurement with
        // the provenance of a later process or overwrite a newer result.
        let existingIDs = Set(existing.map(\.id))
        let merged = Self.latest(existing + additions.filter { !existingIDs.contains($0.id) })
        guard merged.map(\.id) != existing.map(\.id) else { return existing }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var excludedDirectory = directory
        try excludedDirectory.setResourceValues(excluded)
        let data = try JSONEncoder().encode(Snapshot(reports: merged))
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #endif
        var excludedFile = file
        try excludedFile.setResourceValues(excluded)
        return merged
    }

    private static func latest(_ reports: [ModelPreparationReport]) -> [ModelPreparationReport] {
        var keys = Set<String>()
        var counts: [SpeechModel: Int] = [:]
        return reports.sorted { $0.date > $1.date }.filter { report in
            // Known contexts use their actual enum. Older reports remain
            // explicitly unknown; backend text is only an identity, never parsed.
            let context = report.executionContext?.rawValue ?? "unknown:\(report.requestedBackend)"
            let key = "\(report.model.rawValue):\(context)"
            guard !keys.contains(key), counts[report.model, default: 0] < 2 else { return false }
            keys.insert(key)
            counts[report.model, default: 0] += 1
            return true
        }
    }

    private static func valid(_ stored: ModelPreparationReport) -> Bool {
        let report = stored.report
        let resources = report.resources
        func nonnegative(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= 0 } ?? true }
        guard report.stage == .modelLoad, report.date.timeIntervalSinceReferenceDate.isFinite,
              !report.requestedBackend.isEmpty, nonnegative(resources.elapsedSeconds),
              nonnegative(resources.processCPUSeconds), resources.memorySampleCount >= 0,
              resources.memorySamplingIntervalSeconds.isFinite, resources.memorySamplingIntervalSeconds > 0,
              resources.audioSeconds.map({ $0.isFinite && $0 > 0 }) ?? true,
              report.preparationPhases?.allSatisfy({ $0.elapsedSeconds.isFinite && $0.elapsedSeconds >= 0 }) ?? true else { return false }
        return true
    }
}
