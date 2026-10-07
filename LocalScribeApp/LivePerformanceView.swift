import Charts
import LocalScribeCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LivePerformanceStrip: View {
    @EnvironmentObject private var monitor: LivePerformanceMonitor
    @EnvironmentObject private var developerMetrics: DeveloperMetricsReceiver
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
    @EnvironmentObject private var developerMetrics: DeveloperMetricsReceiver
    @ObservedObject var controller: AppController
    @EnvironmentObject private var profilingReports: ProfilingReportStore
    @State private var showingReportImporter = false
    @State private var reportError: String?
    @State private var codeCopied = false

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
                if let cores = monitor.snapshot?.systemCPUCoresPercent {
                    DisclosureGroup("System CPU per core") {
                        ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                            HStack {
                                Text("Core \(index + 1)")
                                if let value { ProgressView(value: value, total: 100).tint(.blue) }
                                Spacer(minLength: 12)
                                Text(LiveMetricFormat.cpu(value)).monospacedDigit()
                            }
                        }
                    }
                }
            } header: {
                Text("CPU")
            } footer: {
                Text("100% is one core’s worth of work. Multicore usage can exceed 100%. This measures CPU time, not which physical cores run each task.")
            }
            Section {
                LabeledContent("System GPU usage", value: developerValue(developerMetrics.latestSample?.gpuDevicePercent))
                LabeledContent("GPU renderer", value: developerValue(developerMetrics.latestSample?.gpuRendererPercent))
                LabeledContent("GPU tiler", value: developerValue(developerMetrics.latestSample?.gpuTilerPercent))
                LabeledContent("Display frame rate", value: developerMetrics.latestSample?.displayFPS.map { String(format: "%.0f fps", $0) } ?? "Not reported")
                LabeledContent("GPU cores in use", value: "Not available")
                LabeledContent("Live Neural Engine usage", value: "Profile with Instruments")
                if let model = controller.preparedModel {
                    LabeledContent("Runtime configuration", value: runtime(model))
                }
            } header: {
                Text("GPU & Neural Engine")
            } footer: {
                Text("GPU counters come from the paired Mac’s developer connection and describe the device. Missing counters stay unreported. Runtime configuration does not measure processor activity.")
            }
            developerConnection
            profilingSection
            if let memory = monitor.snapshot?.systemMemory {
                Section {
                    DisclosureGroup("System memory") {
                        LabeledContent("Free pages", value: LiveMetricFormat.memory(memory.freeBytes))
                        LabeledContent("Active", value: LiveMetricFormat.memory(memory.activeBytes))
                        LabeledContent("Inactive", value: LiveMetricFormat.memory(memory.inactiveBytes))
                        LabeledContent("Wired", value: LiveMetricFormat.memory(memory.wiredBytes))
                        LabeledContent("Compressed", value: LiveMetricFormat.memory(memory.compressedBytes))
                        LabeledContent("Purgeable", value: LiveMetricFormat.memory(memory.purgeableBytes))
                        LabeledContent("Speculative", value: LiveMetricFormat.memory(memory.speculativeBytes))
                    }
                } footer: {
                    Text("OS page counters cover the device. Categories overlap and do not measure memory pressure.")
                }
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
        .fileImporter(isPresented: $showingReportImporter, allowedContentTypes: [.json]) { result in
            do { try profilingReports.load(result.get()) }
            catch { reportError = "This is not a supported Instruments metrics report. Export it with LocalScribe Metrics on your Mac." }
        }
        .alert("Report could not be opened", isPresented: Binding(get: { reportError != nil }, set: { if !$0 { reportError = nil } })) {
            Button("OK") { reportError = nil }
        } message: { Text(reportError ?? "") }
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

    private func developerValue(_ value: Double?) -> String {
        guard let value else { return developerMetrics.status == .stopped ? "Connect to Mac" : "Not reported" }
        return LiveMetricFormat.cpu(value)
    }

    private var developerConnection: some View {
        Section {
            LabeledContent("Mac connection", value: developerMetrics.status.rawValue.capitalized)
            if developerMetrics.status == .stopped || developerMetrics.status == .failed {
                Button("Enable USB metrics") { developerMetrics.start(); codeCopied = false }
            } else {
                if let code = developerMetrics.pairingCode {
                    Button(codeCopied ? "Connection code copied" : "Copy connection code") {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": code]], options: [
                            .expirationDate: Date().addingTimeInterval(120)
                        ])
                        codeCopied = true
                    }
                }
                Button("End Mac connection", role: .destructive) { developerMetrics.stop(); codeCopied = false }
            }
        } footer: {
            Text("Connect the iPhone by USB, open LocalScribe Metrics on your Mac, paste the connection code and select Start. Keep this app open. The connection ends when you leave the foreground.")
        }
    }

    private var profilingSection: some View {
        Section {
            Button("Import Instruments report") { showingReportImporter = true }
            if let report = profilingReports.report {
                LabeledContent("Recording window", value: String(format: "%.1f–%.1f s", report.windowStartMs / 1000, (report.windowStartMs + report.durationMs) / 1000))
                if let ane = report.ane {
                    LabeledContent("Neural Engine active time", value: String(format: "%.1f ms", ane.activeMs))
                    LabeledContent("Neural Engine duty cycle", value: LiveMetricFormat.cpu(ane.dutyCyclePercent))
                }
                if let gpu = report.gpu {
                    LabeledContent("GPU active time", value: String(format: "%.1f ms", gpu.activeMs))
                    LabeledContent("GPU duty cycle", value: LiveMetricFormat.cpu(gpu.dutyCyclePercent))
                }
                Button("Remove report", role: .destructive) { profilingReports.clear() }
            }
        } header: { Text("Instruments report") } footer: {
            Text("Export a report from the Mac’s LocalScribe Metrics app, then choose its JSON file here. Results cover the chosen trace window and are kept in this app session. Duty cycle measures time active, not processor-capacity utilization or live app-specific activity.")
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
