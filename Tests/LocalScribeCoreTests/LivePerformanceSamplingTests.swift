import Testing
@testable import LocalScribeCore

@Test func liveCPUUsesMonotonicDeltasAndAllowsMulticoreWork() {
    var cpu = ProcessCPUSampler()
    #expect(cpu.sample(monotonicSeconds: 10, cpuSeconds: 4) == nil)
    #expect(cpu.sample(monotonicSeconds: 12, cpuSeconds: 9) == 250)
    #expect(cpu.sample(monotonicSeconds: 13, cpuSeconds: 9) == 0)
    cpu.reset()
    #expect(cpu.sample(monotonicSeconds: 100, cpuSeconds: 40) == nil)
}

@Test func liveCPUDiscardsUnavailableAndRegressedBaselines() {
    var cpu = ProcessCPUSampler()
    _ = cpu.sample(monotonicSeconds: 1, cpuSeconds: 1)
    #expect(cpu.sample(monotonicSeconds: 2, cpuSeconds: nil) == nil)
    #expect(cpu.sample(monotonicSeconds: 3, cpuSeconds: 3) == nil)
    #expect(cpu.sample(monotonicSeconds: 3, cpuSeconds: 4) == nil)
    #expect(cpu.sample(monotonicSeconds: 2, cpuSeconds: 2) == nil)
    #expect(cpu.sample(monotonicSeconds: 4, cpuSeconds: 1) == nil)
    #expect(cpu.sample(monotonicSeconds: 5, cpuSeconds: .infinity) == nil)
    #expect(cpu.sample(monotonicSeconds: 6, cpuSeconds: 2) == nil)
    #expect(cpu.sample(monotonicSeconds: 7, cpuSeconds: 3) == 100)
}

@Test func liveHistoryKeepsOnlyRecentSamplesAndResets() {
    var recent = RecentSamples<Int>(capacity: 3)
    for value in 0..<100 { recent.append(value) }
    #expect(recent.values == [97, 98, 99])
    recent.reset()
    #expect(recent.values.isEmpty)
    recent.append(100)
    #expect(recent.values == [100])
}
