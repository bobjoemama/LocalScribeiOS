import Foundation

/// Samples contain numeric developer telemetry; no process identity or raw diagnostics.
public struct DeveloperMetricSample: Codable, Sendable, Equatable {
  public let type: String
  public let version: Int
  public let sequence: UInt64
  public let gpuDevicePercent: Double?
  public let gpuRendererPercent: Double?
  public let gpuTilerPercent: Double?
  public let displayFPS: Double?
  public let systemCPUPercent: Double?
  public let systemCPUCoresPercent: [Double?]?
  public let appCPUPercent: Double?
  public let appMemoryBytes: UInt64?
}

public enum DeveloperMetricsProtocolError: Error {
  case invalidMessage, oversizedLine, invalidSequence
}

/// NDJSON records are capped at 64 KiB including their newline, enough for bounded numeric metadata.
public struct DeveloperMetricsLineBuffer: Sendable {
  public static let maximumLineBytes = 65_536
  private var pending = Data()
  public init() {}
  public mutating func append(_ data: Data) throws -> [Data] {
    var lines: [Data] = []
    for byte in data {
      guard pending.count < Self.maximumLineBytes - 1 else {
        if byte != 10 { throw DeveloperMetricsProtocolError.oversizedLine }
        lines.append(pending)
        pending.removeAll(keepingCapacity: true)
        continue
      }
      if byte == 10 {
        lines.append(pending)
        pending.removeAll(keepingCapacity: true)
      } else {
        pending.append(byte)
      }
    }
    return lines
  }
}

public enum DeveloperMetricsProtocol {
  public static let version = 1
  /// Ten seconds tolerates jitter in the companion's one-second polling interval.
  public static let staleInterval: TimeInterval = 10
  private static let sampleKeys: Set<String> = [
    "type", "version", "sequence", "gpuDevicePercent", "gpuRendererPercent", "gpuTilerPercent",
    "displayFPS", "systemCPUPercent", "systemCPUCoresPercent", "appCPUPercent", "appMemoryBytes",
  ]

  private static func object(_ data: Data, keys: Set<String>) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(value.keys).isSubset(of: keys)
    else { throw DeveloperMetricsProtocolError.invalidMessage }
    return value
  }
  public static func authenticationToken(_ data: Data) throws -> String {
    let value = try object(data, keys: ["type", "token"])
    guard value["type"] as? String == "authenticate", let token = value["token"] as? String,
      token.utf8.count == 43
    else { throw DeveloperMetricsProtocolError.invalidMessage }
    return token
  }
  public static func sample(_ data: Data, after sequence: UInt64?) throws -> DeveloperMetricSample {
    _ = try object(data, keys: sampleKeys)
    let sample = try JSONDecoder().decode(DeveloperMetricSample.self, from: data)
    guard sample.type == "sample", sample.version == version else {
      throw DeveloperMetricsProtocolError.invalidMessage
    }
    if let sequence, sample.sequence <= sequence {
      throw DeveloperMetricsProtocolError.invalidSequence
    }
    func valid(_ value: Double?, maximum: Double? = nil) -> Bool {
      guard let value else { return true }
      return value.isFinite && value >= 0 && (maximum == nil || value <= maximum!)
    }
    guard
      [
        sample.gpuDevicePercent, sample.gpuRendererPercent, sample.gpuTilerPercent,
        sample.systemCPUPercent,
      ].allSatisfy({ valid($0, maximum: 100) }),
      valid(sample.displayFPS), valid(sample.appCPUPercent),
      sample.systemCPUCoresPercent.map({
        $0.count <= 256 && $0.allSatisfy { valid($0, maximum: 100) }
      }) ?? true
    else { throw DeveloperMetricsProtocolError.invalidMessage }
    return sample
  }
}
