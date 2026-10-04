import Foundation

public struct HistoryStore: Sendable {
    public let file: URL
    public init(file: URL) { self.file = file }
    public func load() throws -> [TranscriptEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([TranscriptEntry].self, from: Data(contentsOf: file))
    }
    public func save(_ entries: [TranscriptEntry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        var protectedFile = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedFile.setResourceValues(values)
    }
}

public struct DictionaryStore: Sendable {
    public let file: URL
    public init(file: URL) { self.file = file }
    public func load() throws -> [DictionaryRule] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([DictionaryRule].self, from: Data(contentsOf: file))
    }
    public func save(_ rules: [DictionaryRule]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(rules)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        var protectedFile = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedFile.setResourceValues(values)
    }
}

/// Audio callbacks may run off the main actor. Samples are retained only while explicitly capturing.
public final class CaptureBuffer: @unchecked Sendable {
    public static let sampleRate = 16_000
    public static let maximumSamples = sampleRate * 120
    private let lock = NSLock()
    private var samples: [Float] = []
    private var capturing = false
    private var generation: UInt = 0

    public init() {}
    public func begin() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        generation &+= 1
        capturing = true
    }
    /// Nil means idle. A generation prevents a late audio callback from entering a new recording.
    public var captureGeneration: UInt? {
        lock.lock(); defer { lock.unlock() }
        return capturing ? generation : nil
    }
    @discardableResult public func append(_ incoming: [Float], generation expected: UInt? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard capturing, expected == nil || expected == generation else { return false }
        let remaining = max(0, Self.maximumSamples - samples.count)
        samples.append(contentsOf: incoming.prefix(remaining))
        return samples.count == Self.maximumSamples
    }
    public func finish() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        capturing = false
        let result = samples
        samples = []
        return result
    }
    public func discard() { _ = finish() }
}
