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

@Test func systemCPUUsesPerCoreIntervalTicks() {
    var sampler = SystemCPUSampler()
    let baseline = [SystemCPUTicks(user: 10, system: 20, idle: 60, nice: 10),
                    SystemCPUTicks(user: 0, system: 0, idle: 10, nice: 0)]
    #expect(sampler.sample(baseline)! == [nil, nil])
    #expect(sampler.sample([SystemCPUTicks(user: 30, system: 30, idle: 110, nice: 30),
                            SystemCPUTicks(user: 10, system: 0, idle: 10, nice: 0)])! == [50, 100])
    #expect(sampler.sample([SystemCPUTicks(user: 30, system: 30, idle: 110, nice: 30),
                            SystemCPUTicks(user: 10, system: 0, idle: 20, nice: 0)])! == [nil, 0])
}

@Test func systemCPUResetsOnUnavailableWrapAndTopologyChange() {
    var sampler = SystemCPUSampler()
    let tick = SystemCPUTicks(user: 100, system: 10, idle: 100, nice: 0)
    _ = sampler.sample([tick])
    #expect(sampler.sample(nil) == nil)
    #expect(sampler.sample([tick])! == [nil])
    let reset = SystemCPUTicks(user: 0, system: 0, idle: 0, nice: 0)
    #expect(sampler.sample([reset])! == [nil])
    #expect(sampler.sample([tick, tick])! == [nil, nil])
    sampler.reset()
    #expect(sampler.sample([tick, tick])! == [nil, nil])
    #expect(sampler.sample([]) == nil)
}
