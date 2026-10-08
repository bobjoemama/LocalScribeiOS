import Dispatch
import Foundation

// The check script substitutes a real user-data source for pressure-source creation
// and adds a completion signal after the production callback. The SDK's actual
// setEventHandler, production actor hop and generation checks remain unchanged.
@MainActor enum FixturePressureFactory {
    static var latest: (any DispatchSourceUserDataAdd)?
    nonisolated private static let delivered = DispatchSemaphore(value: 0)
    static func makeSource(queue: DispatchQueue) -> any DispatchSourceUserDataAdd {
        let source = DispatchSource.makeUserDataAddSource(queue: queue)
        latest = source
        return source
    }
    nonisolated static func didDeliver() { delivered.signal() }
    // Keep MainActor occupied until the real utility callback queues its UI task.
    static func emitAndWait(_ source: any DispatchSourceUserDataAdd, _ events: DispatchSource.MemoryPressureEvent) {
        source.add(data: events.rawValue)
        guard delivered.wait(timeout: .now() + 5) == .success else {
            print("FAIL: pressure handler did not run")
            exit(2)
        }
    }
}
@main struct LiveMemoryPressureCheck {
    @MainActor static func waitFor(_ monitor: LivePerformanceMonitor, pressure: LiveMemoryPressure) async throws {
        for _ in 0..<150 {
            if monitor.snapshot?.memoryPressure == pressure { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Expected pressure \(pressure), got \(String(describing: monitor.snapshot?.memoryPressure))")
    }
    @MainActor static func main() async throws {
        let monitor = LivePerformanceMonitor()
        monitor.start()
        let first = FixturePressureFactory.latest!
        // This first real off-main callback aborts with the old production handler.
        FixturePressureFactory.emitAndWait(first, .normal)
        if CommandLine.arguments.contains("--negative-control") {
            print("Original pressure handler survived its off-main event")
            monitor.stop()
            return
        }
        try await waitFor(monitor, pressure: .normal)
        FixturePressureFactory.emitAndWait(first, .warning)
        try await waitFor(monitor, pressure: .warning)
        FixturePressureFactory.emitAndWait(first, .critical)
        try await waitFor(monitor, pressure: .critical)
        FixturePressureFactory.emitAndWait(first, [.normal, .warning])
        try await waitFor(monitor, pressure: .warning)
        FixturePressureFactory.emitAndWait(first, [.normal, .warning, .critical])
        try await waitFor(monitor, pressure: .critical)

        FixturePressureFactory.emitAndWait(first, .warning)
        monitor.stop()
        for _ in 0..<10 { await Task.yield() }
        precondition(monitor.snapshot == nil && monitor.history.isEmpty, "Queued pressure cannot restart stopped telemetry")
        monitor.start()
        let second = FixturePressureFactory.latest!
        FixturePressureFactory.emitAndWait(second, .critical)
        monitor.stop()
        monitor.start()
        try await waitFor(monitor, pressure: .unknown)
        precondition(monitor.history.allSatisfy { $0.memoryPressure == .unknown }, "Retired generation cannot contaminate restart")
        FixturePressureFactory.emitAndWait(FixturePressureFactory.latest!, .normal)
        try await waitFor(monitor, pressure: .normal)
        monitor.stop()
        print("PASS: production pressure handler on real utility Dispatch source; normal/warning/critical, priority, stopped and restarted generation checks")
    }
}
