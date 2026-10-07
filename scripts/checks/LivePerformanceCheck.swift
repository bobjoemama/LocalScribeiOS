import Foundation

@main
struct LivePerformanceCheck {
    @MainActor
    static func waitForSamples(_ monitor: LivePerformanceMonitor, count: Int) async throws {
        for _ in 0..<150 {
            if monitor.history.count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Live telemetry did not deliver expected samples")
    }

    @MainActor
    static func main() async throws {
        var monitor: LivePerformanceMonitor? = LivePerformanceMonitor()
        weak var released = monitor
        monitor!.start()
        monitor!.start()
        try await waitForSamples(monitor!, count: 1)
        precondition(monitor!.snapshot!.cpuPercent == nil, "First CPU sample must establish baseline")
        precondition(monitor!.snapshot!.physicalFootprintBytes != nil, "Real Mach footprint must be readable")
        precondition(monitor!.snapshot!.devicePhysicalMemoryBytes > 0)
        try await waitForSamples(monitor!, count: 2)
        precondition(monitor!.snapshot!.cpuPercent != nil, "Second CPU sample must use process delta")
        monitor!.stop()
        monitor!.stop()
        precondition(monitor!.snapshot == nil && monitor!.history.isEmpty)
        try await Task.sleep(for: .milliseconds(1150))
        precondition(monitor!.snapshot == nil && monitor!.history.isEmpty, "Stopped telemetry must stay stopped")
        monitor!.start()
        try await waitForSamples(monitor!, count: 1)
        precondition(monitor!.snapshot!.cpuPercent == nil, "Resume must establish a fresh CPU baseline")
        monitor = nil
        try await Task.sleep(for: .milliseconds(50))
        precondition(released == nil, "Sampling task must not retain its owner during sleep")
        print("Live telemetry real-process start, sampling, stop, resume and owner release checks passed")
    }
}
