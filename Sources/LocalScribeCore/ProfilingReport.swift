import Foundation

public struct ProfilingReport: Codable, Sendable, Equatable {
    public struct Activity: Codable, Sendable, Equatable {
        public let activeMs: Double
        public let dutyCyclePercent: Double
    }
    public let schemaVersion: Int
    public let provenance: String
    public let durationMs: Double
    public let windowStartMs: Double
    public let ane: Activity?
    public let gpu: Activity?
    public let countersUnavailable: [String]
    public let sourceSchemas: [String]
    public let scope: String

    public static func decode(_ data: Data) throws -> ProfilingReport {
        guard data.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "provenance", "durationMs", "windowStartMs", "ane", "gpu", "countersUnavailable", "sourceSchemas", "scope"])
        else { throw ReportError.invalid }
        for key in ["ane", "gpu"] {
            if let value = object[key] as? [String: Any], Set(value.keys) != Set(["activeMs", "dutyCyclePercent"]) { throw ReportError.invalid }
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, value.provenance == "trace-based (offline)",
              value.scope == "trace-wide; not attributed to LocalScribe",
              value.durationMs.isFinite, value.durationMs > 0,
              value.windowStartMs.isFinite, value.windowStartMs >= 0,
              (value.durationMs + value.windowStartMs).isFinite,
              !value.sourceSchemas.isEmpty,
              value.sourceSchemas.allSatisfy({ ["ane-hw-intervals", "metal-gpu-intervals"].contains($0) }),
              value.countersUnavailable.count <= 32, value.countersUnavailable.allSatisfy({ $0.utf8.count <= 256 }),
              value.ane != nil || value.gpu != nil
        else { throw ReportError.invalid }
        for activity in [value.ane, value.gpu].compactMap({ $0 }) {
            let expected = activity.activeMs / value.durationMs * 100
            guard activity.activeMs.isFinite, activity.activeMs >= 0, activity.activeMs <= value.durationMs,
                  activity.dutyCyclePercent.isFinite, (0...100).contains(activity.dutyCyclePercent),
                  abs(expected - activity.dutyCyclePercent) < 0.001 else { throw ReportError.invalid }
        }
        return value
    }
    public enum ReportError: Error { case invalid }
}
