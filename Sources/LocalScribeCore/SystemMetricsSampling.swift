/// Raw cumulative scheduler ticks for one logical CPU, read from the OS.
public struct SystemCPUTicks: Sendable, Equatable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

/// Each core is normalized to 0...100%; unavailable intervals remain nil.
public struct SystemCPUSampler: Sendable {
    private var baseline: [SystemCPUTicks]?
    public init() {}
    public mutating func reset() { baseline = nil }

    public mutating func sample(_ ticks: [SystemCPUTicks]?) -> [Double?]? {
        guard let ticks, !ticks.isEmpty else { reset(); return nil }
        let previous = baseline
        baseline = ticks
        guard let previous, previous.count == ticks.count else { return ticks.map { _ in nil } }
        return zip(previous, ticks).map { before, after in
            // Regression includes a counter wrap or reset; establish a new baseline.
            guard after.user >= before.user, after.system >= before.system,
                  after.idle >= before.idle, after.nice >= before.nice else { return nil }
            let busy = UInt64(after.user - before.user) + UInt64(after.system - before.system)
                + UInt64(after.nice - before.nice)
            let total = busy + UInt64(after.idle - before.idle)
            guard total > 0 else { return nil }
            return Double(busy) / Double(total) * 100
        }
    }
}

/// OS VM page counters converted using the host's measured page size.
/// Categories overlap: speculative pages are included in free, and purgeable pages
/// can be included in other queues. These are not memory-pressure percentages.
public struct SystemMemorySnapshot: Sendable, Equatable {
    public let pageSizeBytes: UInt64
    public let freeBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let purgeableBytes: UInt64
    public let speculativeBytes: UInt64

    public init(pageSizeBytes: UInt64, freeBytes: UInt64, activeBytes: UInt64,
                inactiveBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64,
                purgeableBytes: UInt64, speculativeBytes: UInt64) {
        self.pageSizeBytes = pageSizeBytes; self.freeBytes = freeBytes
        self.activeBytes = activeBytes; self.inactiveBytes = inactiveBytes
        self.wiredBytes = wiredBytes; self.compressedBytes = compressedBytes
        self.purgeableBytes = purgeableBytes; self.speculativeBytes = speculativeBytes
    }
}
