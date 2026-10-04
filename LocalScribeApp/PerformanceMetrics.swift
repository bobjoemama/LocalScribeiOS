import Darwin
import Foundation

enum MetricThermalState: String, Codable, Sendable {
    case nominal, fair, serious, critical, unknown

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

/// All resource values cover this app process, including UI and probe overhead.
/// They do not measure GPU/ANE utilization, system memory pressure, or energy.
struct PerformanceReport: Codable, Sendable {
    let elapsedSeconds: Double
    let audioSeconds: Double?
    let processCPUSeconds: Double?
    let initialPhysicalFootprintBytes: UInt64?
    /// Maximum successful sample, including start/end; brief spikes may be missed.
    let sampledPeakPhysicalFootprintBytes: UInt64?
    let finalPhysicalFootprintBytes: UInt64?
    /// Kernel high-water marks since process launch, not peaks for this operation.
    let initialProcessLifetimePeakPhysicalFootprintBytes: UInt64?
    let finalProcessLifetimePeakPhysicalFootprintBytes: UInt64?
    let memorySampleCount: Int
    let memorySamplingIntervalSeconds: Double
    let initialThermalState: MetricThermalState
    let finalThermalState: MetricThermalState

    /// Recognition elapsed time divided by audio duration; lower is faster.
    var realTimeFactor: Double? {
        guard let audioSeconds, audioSeconds > 0 else { return nil }
        return elapsedSeconds / audioSeconds
    }
    /// CPU seconds / elapsed seconds. 1 means one core continuously active.
    /// This can exceed 1; it is not a percentage of total device CPU capacity.
    var averageActiveCPUCores: Double? {
        guard let processCPUSeconds, elapsedSeconds > 0 else { return nil }
        return processCPUSeconds / elapsedSeconds
    }
}

/// Sampling is off the UI actor, fixed at 50 ms, and retains only summary values.
/// Finish on every success/error path to cancel the sampler promptly.
actor PerformanceProbe {
    private static let samplingInterval: Duration = .milliseconds(50)
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private let initialCPU: Double?
    private let initialMemory: MemorySnapshot?
    private let initialThermal: MetricThermalState
    private var sampledPeak: UInt64?
    private var sampleCount: Int
    private var samplingTask: Task<Void, Never>?
    private var completedReport: PerformanceReport?

    private init() {
        started = clock.now
        initialCPU = Self.cpuSeconds()
        initialMemory = Self.memorySnapshot()
        initialThermal = MetricThermalState(ProcessInfo.processInfo.thermalState)
        sampledPeak = initialMemory?.physicalFootprint
        sampleCount = initialMemory == nil ? 0 : 1
    }

    static func start() async -> PerformanceProbe {
        let probe = PerformanceProbe()
        await probe.beginSampling()
        return probe
    }

    private func beginSampling() {
        samplingTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.samplingInterval) }
                catch { break }
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await self.sampleMemory()
            }
        }
    }

    private func sampleMemory() {
        guard completedReport == nil, let memory = Self.memorySnapshot() else { return }
        record(memory)
    }

    private func record(_ memory: MemorySnapshot) {
        sampledPeak = max(sampledPeak ?? 0, memory.physicalFootprint)
        sampleCount += 1
    }

    func finish(audioSeconds: Double? = nil) -> PerformanceReport {
        if let completedReport { return completedReport }
        samplingTask?.cancel()
        samplingTask = nil
        let elapsed = started.duration(to: clock.now).components
        let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let finalCPU = Self.cpuSeconds()
        let finalMemory = Self.memorySnapshot()
        if let finalMemory { record(finalMemory) }
        let cpu: Double? = if let finalCPU, let initialCPU {
            max(0, finalCPU - initialCPU)
        } else { nil }
        let validAudio = audioSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let report = PerformanceReport(
            elapsedSeconds: max(0, elapsedSeconds), audioSeconds: validAudio,
            processCPUSeconds: cpu,
            initialPhysicalFootprintBytes: initialMemory?.physicalFootprint,
            sampledPeakPhysicalFootprintBytes: sampledPeak,
            finalPhysicalFootprintBytes: finalMemory?.physicalFootprint,
            initialProcessLifetimePeakPhysicalFootprintBytes: initialMemory?.lifetimePeak,
            finalProcessLifetimePeakPhysicalFootprintBytes: finalMemory?.lifetimePeak,
            memorySampleCount: sampleCount, memorySamplingIntervalSeconds: 0.05,
            initialThermalState: initialThermal,
            finalThermalState: MetricThermalState(ProcessInfo.processInfo.thermalState))
        completedReport = report
        return report
    }

    deinit { samplingTask?.cancel() }

    private struct MemorySnapshot {
        let physicalFootprint: UInt64
        let lifetimePeak: UInt64?
    }

    private static func memorySnapshot() -> MemorySnapshot? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let returnedBytes = Int(count) * MemoryLayout<integer_t>.size
        let footprintEnd = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint)! + MemoryLayout<mach_vm_size_t>.size
        guard returnedBytes >= footprintEnd else { return nil }
        let peakEnd = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak)! + MemoryLayout<Int64>.size
        let peak = returnedBytes >= peakEnd && info.ledger_phys_footprint_peak >= 0
            ? UInt64(info.ledger_phys_footprint_peak) : nil
        return MemorySnapshot(physicalFootprint: info.phys_footprint, lifetimePeak: peak)
    }

    private static func cpuSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }
}
