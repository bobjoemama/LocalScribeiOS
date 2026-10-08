import Combine
import Darwin
import Foundation
import LocalScribeCore

enum LiveMemoryPressure: String, Sendable {
    case unknown, normal, warning, critical
}

struct LivePerformanceSnapshot: Identifiable, Sendable {
    var id: Date { timestamp }
    let timestamp: Date
    /// 100% means one fully occupied CPU core; multicore work may exceed 100%.
    let cpuPercent: Double?
    let systemCPUCoresPercent: [Double?]?
    let systemMemory: SystemMemorySnapshot?
    let physicalFootprintBytes: UInt64?
    /// Kernel high-water mark since app launch, not this display window.
    let lifetimePeakPhysicalFootprintBytes: UInt64?
    /// OS estimate of memory this process may allocate, not device free RAM or pressure.
    let availableMemoryBytes: UInt64?
    let devicePhysicalMemoryBytes: UInt64
    let activeProcessorCount: Int
    let processorCount: Int
    let thermalState: MetricThermalState
    let isLowPowerModeEnabled: Bool
    let memoryPressure: LiveMemoryPressure
}

/// Foreground, visible-screen telemetry only. The owner stops this on scene inactivity.
@MainActor
final class LivePerformanceMonitor: ObservableObject {
    @Published private(set) var snapshot: LivePerformanceSnapshot?
    @Published private(set) var history: [LivePerformanceSnapshot] = []
    private var recent = RecentSamples<LivePerformanceSnapshot>(capacity: 60)
    private var cpu = ProcessCPUSampler()
    private var systemCPU = SystemCPUSampler()
    private var samplingTask: Task<Void, Never>?
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private var pressure: LiveMemoryPressure = .unknown
    private var generation = 0

    func start() {
        guard samplingTask == nil else { return }
        generation += 1
        let currentGeneration = generation
        cpu.reset()
        systemCPU.reset()
        pressure = .unknown
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        // Dispatch executes this callback on its utility queue. Explicit Sendable
        // prevents inherited MainActor isolation before the actor hop below.
        source.setEventHandler { @Sendable [weak self, weak source] in
            guard let events = source?.data else { return }
            let level: LiveMemoryPressure = events.contains(.critical) ? .critical
                : events.contains(.warning) ? .warning : events.contains(.normal) ? .normal : .unknown
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.pressure = level
            }
        }
        pressureSource = source
        source.resume()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                let raw = await Task.detached(priority: .utility) { Self.readResources() }.value
                guard !Task.isCancelled, self?.generation == currentGeneration else { break }
                self?.publish(raw)
                do { try await Task.sleep(for: .seconds(1)) }
                catch { break }
            }
        }
    }

    func stop() {
        generation += 1
        samplingTask?.cancel()
        samplingTask = nil
        pressureSource?.cancel()
        pressureSource = nil
        cpu.reset()
        systemCPU.reset()
        recent.reset()
        snapshot = nil
        history = []
        pressure = .unknown
    }

    private func publish(_ raw: Resources) {
        let process = ProcessInfo.processInfo
        let value = LivePerformanceSnapshot(
            timestamp: raw.timestamp,
            cpuPercent: cpu.sample(monotonicSeconds: raw.monotonicSeconds, cpuSeconds: raw.cpuSeconds),
            systemCPUCoresPercent: systemCPU.sample(raw.systemCPUTicks), systemMemory: raw.systemMemory,
            physicalFootprintBytes: raw.footprint, lifetimePeakPhysicalFootprintBytes: raw.peak,
            availableMemoryBytes: raw.availableMemory, devicePhysicalMemoryBytes: process.physicalMemory,
            activeProcessorCount: process.activeProcessorCount, processorCount: process.processorCount,
            thermalState: MetricThermalState(process.thermalState),
            isLowPowerModeEnabled: process.isLowPowerModeEnabled, memoryPressure: pressure)
        recent.append(value)
        snapshot = value
        history = recent.values
    }

    private struct Resources: Sendable {
        let timestamp: Date
        let monotonicSeconds: Double
        let cpuSeconds: Double?
        let footprint: UInt64?
        let peak: UInt64?
        let availableMemory: UInt64?
        let systemCPUTicks: [SystemCPUTicks]?
        let systemMemory: SystemMemorySnapshot?
    }

    nonisolated private static func readResources() -> Resources {
        var usage = rusage()
        let cpu: Double? = getrusage(RUSAGE_SELF, &usage) == 0
            ? Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6 : nil
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let returnedBytes = Int(count) * MemoryLayout<integer_t>.size
        let footprintEnd = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint)! + MemoryLayout<mach_vm_size_t>.size
        let peakEnd = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak)! + MemoryLayout<Int64>.size
        let footprint = result == KERN_SUCCESS && returnedBytes >= footprintEnd ? info.phys_footprint : nil
        let peak = result == KERN_SUCCESS && returnedBytes >= peakEnd && info.ledger_phys_footprint_peak >= 0
            ? UInt64(info.ledger_phys_footprint_peak) : nil
        #if os(iOS)
        let available: UInt64? = UInt64(os_proc_available_memory())
        #else
        let available: UInt64? = nil
        #endif
        return Resources(timestamp: Date(), monotonicSeconds: ProcessInfo.processInfo.systemUptime,
                         cpuSeconds: cpu, footprint: footprint, peak: peak,
                         availableMemory: available, systemCPUTicks: SystemResourceReader.cpuTicks(),
                         systemMemory: SystemResourceReader.memory())
    }

    deinit {
        samplingTask?.cancel()
        pressureSource?.cancel()
    }
}
