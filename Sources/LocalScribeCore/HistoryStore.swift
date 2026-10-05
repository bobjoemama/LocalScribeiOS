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

public struct CaptureBufferSnapshot: Equatable, Sendable {
    public let generation: UInt?
    public let bufferedSamples: Int
    public let receivedSamples: Int64
    public let drainedSamples: Int64
    public let overflowSamples: Int64
    public let discardedSamples: Int64
    public let processingFailureCount: Int
}

/// Audio callbacks may run off the main actor. This is a bounded FIFO, not a session limit:
/// the consumer drains chunks during recording, then finishes with the remaining tail.
public final class CaptureBuffer: @unchecked Sendable {
    public static let sampleRate = 16_000
    public static let maximumSamples = sampleRate * 120
    private let lock = NSLock()
    private var samples: [Float] = []
    private var readOffset = 0
    private var capturing = false
    private var generation: UInt = 0
    private let capacitySamples: Int
    private var receivedSamples: Int64 = 0
    private var drainedSamples: Int64 = 0
    private var overflowSamples: Int64 = 0
    private var discardedSamples: Int64 = 0
    private var processingFailureCount = 0

    public init(capacitySamples: Int = CaptureBuffer.maximumSamples) {
        precondition(capacitySamples > 0 && capacitySamples <= Self.maximumSamples)
        self.capacitySamples = capacitySamples
    }
    public func begin() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        readOffset = 0
        receivedSamples = 0
        drainedSamples = 0
        overflowSamples = 0
        discardedSamples = 0
        processingFailureCount = 0
        generation &+= 1
        capturing = true
    }
    /// Nil means idle. A generation prevents a late audio callback from entering a new recording.
    public var captureGeneration: UInt? {
        lock.lock(); defer { lock.unlock() }
        return capturing ? generation : nil
    }
    public var snapshot: CaptureBufferSnapshot {
        lock.lock(); defer { lock.unlock() }
        return CaptureBufferSnapshot(generation: capturing ? generation : nil,
                                     bufferedSamples: samples.count - readOffset,
                                     receivedSamples: receivedSamples, drainedSamples: drainedSamples,
                                     overflowSamples: overflowSamples, discardedSamples: discardedSamples,
                                     processingFailureCount: processingFailureCount)
    }
    /// Preserve failures through stop even if a UI callback hasn't run yet. A generation
    /// fence prevents a late converter failure from contaminating the next utterance.
    @discardableResult public func markProcessingFailure(generation expected: UInt? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard capturing, expected == nil || expected == generation else { return false }
        processingFailureCount += 1
        return true
    }
    /// Returns true when the pending FIFO is full. Actual loss is separately observable
    /// through overflowSamples, including loss in the callback that filled the buffer.
    @discardableResult public func append(_ incoming: [Float], generation expected: UInt? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard capturing, expected == nil || expected == generation else { return false }
        let remaining = max(0, capacitySamples - (samples.count - readOffset))
        let accepted = min(remaining, incoming.count)
        // Release consumed storage before appending would exceed the physical bound.
        if readOffset > 0 && samples.count + accepted > capacitySamples {
            samples.removeFirst(readOffset)
            readOffset = 0
        }
        samples.append(contentsOf: incoming.prefix(accepted))
        receivedSamples += Int64(incoming.count)
        overflowSamples += Int64(incoming.count - accepted)
        return samples.count - readOffset == capacitySamples
    }
    /// Consumes a FIFO chunk without changing the recording generation. Requiring a
    /// minimum avoids tiny decoder calls; stop/finish always returns the final short tail.
    public func drain(minimumSamples: Int = 0, maximumSamples: Int = CaptureBuffer.sampleRate * 8, generation expected: UInt? = nil) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard capturing, expected == nil || expected == generation,
              maximumSamples > 0, minimumSamples >= 0, minimumSamples <= maximumSamples else { return [] }
        let buffered = samples.count - readOffset
        guard buffered >= minimumSamples else { return [] }
        let count = min(buffered, maximumSamples)
        guard count > 0 else { return [] }
        let result = Array(samples[readOffset..<(readOffset + count)])
        readOffset += count
        drainedSamples += Int64(count)
        if readOffset == samples.count {
            samples.removeAll(keepingCapacity: true)
            readOffset = 0
        }
        return result
    }
    public func finish() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        capturing = false
        let result = Array(samples.dropFirst(readOffset))
        drainedSamples += Int64(result.count)
        samples = []
        readOffset = 0
        return result
    }
    public func discard() {
        lock.lock(); defer { lock.unlock() }
        capturing = false
        discardedSamples += Int64(samples.count - readOffset)
        samples = []
        readOffset = 0
    }
}
