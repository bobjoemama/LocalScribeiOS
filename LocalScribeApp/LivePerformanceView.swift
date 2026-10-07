import Charts
import LocalScribeCore
import SwiftUI

struct LivePerformanceStrip: View {
    @EnvironmentObject private var monitor: LivePerformanceMonitor
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    metric("CPU", value: LiveMetricFormat.cpu(monitor.snapshot?.cpuPercent))
                    metric("Memory", value: LiveMetricFormat.memory(monitor.snapshot?.physicalFootprintBytes))
                    Spacer(minLength: 0)
                    pressure
                    Image(systemName: "chevron.right").font(.caption2)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        metric("CPU", value: LiveMetricFormat.cpu(monitor.snapshot?.cpuPercent))
                        Spacer()
                        metric("Memory", value: LiveMetricFormat.memory(monitor.snapshot?.physicalFootprintBytes))
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    pressure
                }
            }
            .font(.caption).monospacedDigit()
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Performance. CPU \(LiveMetricFormat.cpu(monitor.snapshot?.cpuPercent)), memory \(LiveMetricFormat.memory(monitor.snapshot?.physicalFootprintBytes)). Memory pressure \(LiveMetricFormat.pressure(monitor.snapshot?.memoryPressure)).")
        .accessibilityHint("Shows live resource usage and recent graphs")
    }

    private func metric(_ label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
    }

    private var pressure: some View {
        HStack(spacing: 4) {
            Circle().fill(LiveMetricFormat.pressureColor(monitor.snapshot?.memoryPressure)).frame(width: 5, height: 5)
            Text("Pressure: " + LiveMetricFormat.pressure(monitor.snapshot?.memoryPressure)).foregroundStyle(.secondary)
        }
    }
}

struct LivePerformanceView: View {
    @EnvironmentObject private var monitor: LivePerformanceMonitor
    @ObservedObject var controller: AppController

    private var state: String {
        if let loading = controller.modelStatus { return loading }
        switch controller.phase {
        case .idle: return "Idle"
        case .preparing: return "Preparing"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: state)
                LabeledContent("Loaded model", value: controller.preparedModel?.name ?? "None")
            } footer: {
                Text("Updates every second while LocalScribe is open, including when idle.")
            }
            Section {
                LabeledContent("App memory", value: LiveMetricFormat.memory(monitor.snapshot?.physicalFootprintBytes))
                historyChart(memory: true)
                LabeledContent("Peak since launch", value: LiveMetricFormat.memory(monitor.snapshot?.lifetimePeakPhysicalFootprintBytes))
                LabeledContent("App headroom", value: LiveMetricFormat.memory(monitor.snapshot?.availableMemoryBytes))
                LabeledContent("Memory pressure") {
                    Text(LiveMetricFormat.pressure(monitor.snapshot?.memoryPressure))
                        .foregroundStyle(LiveMetricFormat.pressureColor(monitor.snapshot?.memoryPressure))
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("Headroom is iOS’s current allowance for this app, not free device RAM. Pressure shows the last system event; “Not reported” means no event has arrived.")
            }
            Section {
                LabeledContent("App CPU", value: LiveMetricFormat.cpu(monitor.snapshot?.cpuPercent))
                historyChart(memory: false)
                LabeledContent("Core equivalents", value: monitor.snapshot?.cpuPercent.map { String(format: "%.2f", $0 / 100) } ?? "—")
                LabeledContent("Available CPU cores", value: monitor.snapshot.map { "\($0.activeProcessorCount) of \($0.processorCount)" } ?? "—")
            } header: {
                Text("CPU")
            } footer: {
                Text("100% is one core’s worth of work. Multicore usage can exceed 100%. This measures CPU time, not which physical cores run each task.")
            }
            Section {
                LabeledContent("GPU usage", value: "Not available")
                LabeledContent("GPU cores in use", value: "Not available")
                LabeledContent("Neural Engine usage", value: "Not available")
                if let model = controller.preparedModel {
                    LabeledContent("Runtime configuration", value: runtime(model))
                }
            } header: {
                Text("GPU & Neural Engine")
            } footer: {
                Text("iOS does not expose live utilization for these speech runtimes. The configured processors are not a measurement of their activity.")
            }
            Section("Device") {
                LabeledContent("Physical memory", value: LiveMetricFormat.memory(monitor.snapshot?.devicePhysicalMemoryBytes))
                LabeledContent("Thermal state", value: monitor.snapshot?.thermalState.rawValue.capitalized ?? "—")
                LabeledContent("Low Power Mode", value: monitor.snapshot.map { $0.isLowPowerModeEnabled ? "On" : "Off" } ?? "—")
            }
            Section {
                NavigationLink("Accuracy & completed operations") { PerformanceView(controller: controller) }
            } footer: {
                Text("Usage covers the whole app, including its interface and loaded runtime. Charts show up to 60 recent samples and reset after leaving the foreground.")
            }
        }
        .navigationTitle("Performance").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if controller.phase == .recording {
                HStack {
                    Label("Recording", systemImage: "mic.fill").foregroundStyle(.red)
                    Spacer()
                    Button("Stop") {
                        Task {
                            if controller.actionButtonRecording { await controller.stopActionButtonRecording() }
                            else { await controller.stopRecording() }
                        }
                    }.buttonStyle(.borderedProminent).tint(.red)
                }
                .padding().background(.regularMaterial)
            }
        }
    }

    private func runtime(_ model: SpeechModel) -> String {
        switch model {
        case .moonshineSmall, .parakeetRealtimeEOU: "CPU"
        case .parakeetPhononLUT3: "CPU, GPU encoder, Neural Engine"
        default: "CPU & Neural Engine"
        }
    }

    @ViewBuilder private func historyChart(memory: Bool) -> some View {
        let points = monitor.history.compactMap { sample -> MetricPoint? in
            let value = memory ? sample.physicalFootprintBytes.map { Double($0) / 1_048_576 } : sample.cpuPercent
            return value.map { MetricPoint(time: sample.timestamp, value: $0) }
        }
        if points.count > 1 {
            Chart(points) { point in
                LineMark(x: .value("Time", point.time), y: .value(memory ? "MiB" : "CPU %", point.value))
                    .foregroundStyle(memory ? Color.purple : Color.blue)
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .frame(height: 90)
            .accessibilityLabel(memory ? "Recent app memory in mebibytes" : "Recent app CPU percent, one core equals 100 percent")
        }
    }
}

private struct MetricPoint: Identifiable {
    var id: Date { time }
    let time: Date
    let value: Double
}

enum LiveMetricFormat {
    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        if bytes >= 1_073_741_824 { return String(format: "%.2f GiB", Double(bytes) / 1_073_741_824) }
        return String(format: "%.1f MiB", Double(bytes) / 1_048_576)
    }
    static func cpu(_ percent: Double?) -> String { percent.map { String(format: "%.1f%%", $0) } ?? "—" }
    static func pressure(_ value: LiveMemoryPressure?) -> String {
        switch value {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        case .unknown, nil: "Not reported"
        }
    }
    static func pressureColor(_ value: LiveMemoryPressure?) -> Color {
        switch value {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        case .unknown, nil: .secondary
        }
    }
}
