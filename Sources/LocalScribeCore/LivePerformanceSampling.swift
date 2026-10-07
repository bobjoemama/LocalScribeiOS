/// Converts cumulative process CPU time to percent of one core using a monotonic clock.
public struct ProcessCPUSampler: Sendable {
    private var baseline: (time: Double, cpu: Double)?

    public init() {}

    public mutating func reset() { baseline = nil }

    public mutating func sample(monotonicSeconds: Double, cpuSeconds: Double?) -> Double? {
        guard monotonicSeconds.isFinite, let cpuSeconds, cpuSeconds.isFinite, cpuSeconds >= 0 else {
            reset()
            return nil
        }
        let previous = baseline
        baseline = (monotonicSeconds, cpuSeconds)
        guard let previous, monotonicSeconds > previous.time, cpuSeconds >= previous.cpu else { return nil }
        let percent = (cpuSeconds - previous.cpu) / (monotonicSeconds - previous.time) * 100
        return percent.isFinite ? percent : nil
    }
}

/// A fixed display window, independent of how long recording or the screen stays active.
public struct RecentSamples<Element: Sendable>: Sendable {
    public private(set) var values: [Element] = []
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public mutating func append(_ value: Element) {
        if values.count == capacity { values.removeFirst() }
        values.append(value)
    }

    public mutating func reset() { values.removeAll(keepingCapacity: true) }
}
