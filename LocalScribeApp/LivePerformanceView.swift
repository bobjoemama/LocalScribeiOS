import Charts
import LocalScribeCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LivePerformanceStrip: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var monitor: LivePerformanceMonitor
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            metric("CPU", value: LiveMetricFormat.cpu(monitor.snapshot?.cpuPercent))
                            metric("Memory", value: LiveMetricFormat.memory(monitor.snapshot?.physicalFootprintBytes))
                            pressure
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                } else {
                    compactMetrics
                }
            }
            .font(.footnote).monospacedDigit()
            .padding(.vertical, 12)
            .foregroundStyle(AppTheme.ink)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Performance. CPU \(LiveMetricFormat.cpu(monitor.snapshot?.cpuPercent)), memory \(LiveMetricFormat.memory(monitor.snapshot?.physicalFootprintBytes)), allocation headroom \(LiveMetricFormat.memory(monitor.snapshot?.availableMemoryBytes)). Memory-pressure alerts: \(LiveMetricFormat.pressure(monitor.snapshot?.memoryPressure)).")
        .accessibilityHint("Shows live resource usage and recent graphs")
    }

    private var compactMetrics: some View {
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
    }


    private func metric(_ label: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                Text(label).foregroundStyle(AppTheme.inkSecondary).fixedSize()
                Text(value).fontWeight(.medium).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(AppTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                Text(value).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pressure: some View {
        HStack(spacing: 4) {
            if monitor.snapshot?.memoryPressure == .warning || monitor.snapshot?.memoryPressure == .critical {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LiveMetricFormat.pressureColor(monitor.snapshot?.memoryPressure))
                Text(LiveMetricFormat.pressure(monitor.snapshot?.memoryPressure)).foregroundStyle(LiveMetricFormat.pressureColor(monitor.snapshot?.memoryPressure)).fixedSize(horizontal: false, vertical: true)
            } else {
                metric("Headroom", value: LiveMetricFormat.memory(monitor.snapshot?.availableMemoryBytes))
            }
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
                LabeledContent("Status") {
                    Text(state).foregroundStyle(AppTheme.inkSecondary)
                }
                LabeledContent("Loaded model") {
                    Text(controller.preparedModel?.name ?? "None").foregroundStyle(AppTheme.inkSecondary)
                }
            } footer: {
                Text("Updates every second while LocalScribe is open, including when idle.").foregroundStyle(AppTheme.inkSecondary)
            }.listRowBackground(AppTheme.surface)
            Section {
                LabeledContent("App memory") {
                    Text(LiveMetricFormat.memory(monitor.snapshot?.physicalFootprintBytes)).foregroundStyle(AppTheme.inkSecondary)
                }
                historyChart(memory: true)
                LabeledContent("Peak since launch") {
                    Text(LiveMetricFormat.memory(monitor.snapshot?.lifetimePeakPhysicalFootprintBytes)).foregroundStyle(AppTheme.inkSecondary)
                }
                LabeledContent("App headroom") {
                    Text(LiveMetricFormat.memory(monitor.snapshot?.availableMemoryBytes)).foregroundStyle(AppTheme.inkSecondary)
                }
                LabeledContent("Memory-pressure alerts") {
                    Text(LiveMetricFormat.pressure(monitor.snapshot?.memoryPressure))
                        .foregroundStyle(LiveMetricFormat.pressureColor(monitor.snapshot?.memoryPressure))
                }
            } header: {
                Text("Memory").foregroundStyle(AppTheme.inkSecondary)
            } footer: {
                Text("Headroom is iOS’s current allocation allowance for this app. Pressure alerts show the last event received from iOS. No alerts received does not establish normal system pressure.").foregroundStyle(AppTheme.inkSecondary)
            }.listRowBackground(AppTheme.surface)
            Section {
                LabeledContent("App CPU") {
                    Text(LiveMetricFormat.cpu(monitor.snapshot?.cpuPercent)).foregroundStyle(AppTheme.inkSecondary)
                }
                historyChart(memory: false)
                LabeledContent("Core equivalents") {
                    Text(monitor.snapshot?.cpuPercent.map { String(format: "%.2f", $0 / 100) } ?? "—").foregroundStyle(AppTheme.inkSecondary)
                }
                LabeledContent("Available CPU cores") {
                    Text(monitor.snapshot.map { "\($0.activeProcessorCount) of \($0.processorCount)" } ?? "—").foregroundStyle(AppTheme.inkSecondary)
                }
                if let cores = monitor.snapshot?.systemCPUCoresPercent {
                    DisclosureGroup("System CPU per core") {
                        ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                            HStack {
                                Text("Core \(index + 1)")
                                if let value { ProgressView(value: value, total: 100).tint(AppTheme.chartCPU) }
                                Spacer(minLength: 12)
                                Text(LiveMetricFormat.cpu(value)).monospacedDigit().foregroundStyle(AppTheme.inkSecondary)
                            }
                        }
                    }
                }
            } header: {
                Text("CPU").foregroundStyle(AppTheme.inkSecondary)
            } footer: {
                Text("100% is one core’s worth of work. Multicore usage can exceed 100%. This measures CPU time, not which physical cores run each task.").foregroundStyle(AppTheme.inkSecondary)
            }.listRowBackground(AppTheme.surface)
            if hasGPUCounters { gpuCounters }
            if let memory = monitor.snapshot?.systemMemory {
                Section {
                    DisclosureGroup("System memory") {
                        LabeledContent("Free pages") {
                            Text(LiveMetricFormat.memory(memory.freeBytes)).foregroundStyle(AppTheme.inkSecondary)
                        }
                        LabeledContent("Active") {
                            Text(LiveMetricFormat.memory(memory.activeBytes)).foregroundStyle(AppTheme.inkSecondary)
                        }
                        LabeledContent("Inactive") {
                            Text(LiveMetricFormat.memory(memory.inactiveBytes)).foregroundStyle(AppTheme.inkSecondary)
                        }
                        LabeledContent("Wired") {
                            Text(LiveMetricFormat.memory(memory.wiredBytes)).foregroundStyle(AppTheme.inkSecondary)
                        }
                        LabeledContent("Compressed") {
                            Text(LiveMetricFormat.memory(memory.compressedBytes)).foregroundStyle(AppTheme.inkSecondary)
                        }
                        LabeledContent("Purgeable") {
                            Text(LiveMetricFormat.memory(memory.purgeableBytes)).foregroundStyle(AppTheme.inkSecondary)
                        }
                        LabeledContent("Speculative") {
                            Text(LiveMetricFormat.memory(memory.speculativeBytes)).foregroundStyle(AppTheme.inkSecondary)
                        }
                    }
                } footer: {
                    Text("OS page counters cover the device. Categories overlap and do not measure memory pressure.").foregroundStyle(AppTheme.inkSecondary)
                }.listRowBackground(AppTheme.surface)
            }
            Section {
                LabeledContent("Physical memory") {
                    Text(LiveMetricFormat.memory(monitor.snapshot?.devicePhysicalMemoryBytes)).foregroundStyle(AppTheme.inkSecondary)
                }
                LabeledContent("Thermal state") {
                    Text(monitor.snapshot?.thermalState.rawValue.capitalized ?? "—").foregroundStyle(AppTheme.inkSecondary)
                }
                LabeledContent("Low Power Mode") {
                    Text(monitor.snapshot.map { $0.isLowPowerModeEnabled ? "On" : "Off" } ?? "—").foregroundStyle(AppTheme.inkSecondary)
                }
                if let model = controller.preparedModel {
                    LabeledContent("Configured processors") {
                        Text(runtime(model)).foregroundStyle(AppTheme.inkSecondary)
                    }
                }
            } header: {
                Text("Device").foregroundStyle(AppTheme.inkSecondary)
            } footer: {
                Text("Configured processors describe the prepared runtime’s processing path, not measured processor usage.").foregroundStyle(AppTheme.inkSecondary)
            }.listRowBackground(AppTheme.surface)
            Section {
                NavigationLink("Accuracy") { PerformanceView(controller: controller) }
                NavigationLink("Developer profiling") { developerProfiling }
            } footer: {
                Text("Usage covers the whole app, including its interface and loaded runtime. Charts show up to 60 recent samples and reset after leaving the foreground.").foregroundStyle(AppTheme.inkSecondary)
            }.listRowBackground(AppTheme.surface)
        }
        .scribeForm()
        .monospacedDigit()
        .navigationTitle("Performance").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if controller.phase == .preparing || controller.phase == .recording {
                HStack {
                    Circle().fill(AppTheme.recording).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(controller.phase == .preparing ? "Starting…" : "Recording \(recordingDuration)")
                        .font(.subheadline).monospacedDigit()
                    Spacer()
                    Button("Stop") {
                        Task {
                            if controller.phase == .preparing { await controller.cancelPreparation() }
                            else if controller.actionButtonRecording { await controller.stopActionButtonRecording() }
                            else { await controller.stopRecording() }
                        }
                    }.buttonStyle(.borderedProminent).controlSize(.large).tint(AppTheme.recording)
                        .foregroundStyle(AppTheme.onRecording).frame(minHeight: 44)
                }
                .padding().background(.regularMaterial)
            }
        }
    }

    private var developerProfiling: some View {
        Form {
            if hasGPUCounters { gpuCounters }
            developerConnection
            profilingSection
        }
        .scribeForm()
        .monospacedDigit()
        .navigationTitle("Developer profiling").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showingReportImporter, allowedContentTypes: [.json]) { result in
            do { try profilingReports.load(result.get()) }
            catch { reportError = "This is not a supported Instruments metrics report. Export it with LocalScribe Metrics on your Mac." }
        }
        .alert("Report could not be opened", isPresented: Binding(get: { reportError != nil }, set: { if !$0 { reportError = nil } })) {
            Button("OK") { reportError = nil }
        } message: { Text(reportError ?? "") }
    }

    private var gpuCounters: some View {
        Section {
            if let value = developerMetrics.latestSample?.gpuDevicePercent {
                LabeledContent("GPU usage") {
                    Text(LiveMetricFormat.cpu(value)).foregroundStyle(AppTheme.inkSecondary)
                }
            }
            if let value = developerMetrics.latestSample?.gpuRendererPercent {
                LabeledContent("Renderer") {
                    Text(LiveMetricFormat.cpu(value)).foregroundStyle(AppTheme.inkSecondary)
                }
            }
            if let value = developerMetrics.latestSample?.gpuTilerPercent {
                LabeledContent("Tiler") {
                    Text(LiveMetricFormat.cpu(value)).foregroundStyle(AppTheme.inkSecondary)
                }
            }
            if let value = developerMetrics.latestSample?.displayFPS {
                LabeledContent("Display frame rate") {
                    Text(String(format: "%.0f fps", value)).foregroundStyle(AppTheme.inkSecondary)
                }
            }
        } header: {
            Text("System GPU").foregroundStyle(AppTheme.inkSecondary)
        } footer: {
            Text("Device-wide, via Mac. These counters cover the device, not just LocalScribe. iOS does not expose occupied GPU cores or live Neural Engine utilization to this app.").foregroundStyle(AppTheme.inkSecondary)
        }.listRowBackground(AppTheme.surface)
    }

    private var hasGPUCounters: Bool {
        guard let sample = developerMetrics.latestSample else { return false }
        return sample.gpuDevicePercent != nil || sample.gpuRendererPercent != nil
            || sample.gpuTilerPercent != nil || sample.displayFPS != nil
    }

    private var developerConnection: some View {
        Section {
            LabeledContent("Mac connection") {
                HStack(spacing: 6) {
                    Circle().fill(connectionColor).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(developerMetrics.status.rawValue.capitalized).foregroundStyle(AppTheme.inkSecondary)
                }
            }
            if developerMetrics.status == .stopped || developerMetrics.status == .failed {
                Button("Enable USB metrics") { developerMetrics.start(); codeCopied = false }
            } else {
                if let code = developerMetrics.pairingCode {
                    Button(codeCopied ? "Copied · clipboard expires in 2 min" : "Copy connection code") {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": code]], options: [
                            .expirationDate: Date().addingTimeInterval(120)
                        ])
                        codeCopied = true
                    }
                }
                Button("End Mac connection", role: .destructive) { developerMetrics.stop(); codeCopied = false }
            }
        } footer: {
            Text("Optional GPU measurements require a Mac. CPU, memory and thermal readings work on this phone alone. To connect, use USB, open LocalScribe Metrics on your Mac and enter the connection code. Leaving this app ends the connection.").foregroundStyle(AppTheme.inkSecondary)
        }.listRowBackground(AppTheme.surface)
    }

    private var profilingSection: some View {
        Section {
            Button("Import Instruments report") { showingReportImporter = true }
            if let report = profilingReports.report {
                LabeledContent("Recording window") {
                    Text(String(format: "%.1f–%.1f s", report.windowStartMs / 1000, (report.windowStartMs + report.durationMs) / 1000)).foregroundStyle(AppTheme.inkSecondary)
                }
                if let ane = report.ane {
                    LabeledContent("Neural Engine active time") {
                        Text(String(format: "%.1f ms", ane.activeMs)).foregroundStyle(AppTheme.inkSecondary)
                    }
                    LabeledContent("Neural Engine duty cycle") {
                        Text(LiveMetricFormat.cpu(ane.dutyCyclePercent)).foregroundStyle(AppTheme.inkSecondary)
                    }
                }
                if let gpu = report.gpu {
                    LabeledContent("GPU active time") {
                        Text(String(format: "%.1f ms", gpu.activeMs)).foregroundStyle(AppTheme.inkSecondary)
                    }
                    LabeledContent("GPU duty cycle") {
                        Text(LiveMetricFormat.cpu(gpu.dutyCyclePercent)).foregroundStyle(AppTheme.inkSecondary)
                    }
                }
                Button("Remove report", role: .destructive) { profilingReports.clear() }
            }
        } header: { Text("Instruments report").foregroundStyle(AppTheme.inkSecondary) } footer: {
            Text("Export a report from the Mac’s LocalScribe Metrics app, then choose its JSON file here. Results cover the chosen trace window and are kept in this app session. Duty cycle measures time active, not processor-capacity utilization or live app-specific activity.").foregroundStyle(AppTheme.inkSecondary)
        }.listRowBackground(AppTheme.surface)
    }

    private var recordingDuration: String {
        let seconds = Int(max(0, controller.elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var connectionColor: Color {
        switch developerMetrics.status {
        case .connected: AppTheme.success
        case .starting, .waiting, .stale: AppTheme.warning
        case .failed: AppTheme.error
        case .stopped: AppTheme.inkSecondary
        }
    }

    private func runtime(_ model: SpeechModel) -> String {
        guard let context = controller.preparedExecutionContext else { return "Unavailable" }
        if context == .backgroundCapable { return "CPU only" }
        switch model {
        case .moonshineSmall, .parakeetRealtimeEOU: return "CPU only"
        case .parakeetPhononLUT3: return "CPU, GPU encoder, Neural Engine"
        default: return "CPU & Neural Engine"
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
                    .foregroundStyle(memory ? AppTheme.chartMemory : AppTheme.chartCPU)
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(AppTheme.separatorStrong)
                    AxisTick().foregroundStyle(AppTheme.separatorStrong)
                    AxisValueLabel().foregroundStyle(AppTheme.inkSecondary)
                }
            }
            .chartPlotStyle { plot in
                plot.background(AppTheme.surfaceInset)
            }
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
        case .normal: "Normal event"
        case .warning: "Warning event"
        case .critical: "Critical event"
        case .unknown, nil: "No alerts received"
        }
    }
    static func pressureColor(_ value: LiveMemoryPressure?) -> Color {
        switch value {
        case .normal: AppTheme.success
        case .warning: AppTheme.warning
        case .critical: AppTheme.error
        case .unknown, nil: AppTheme.inkSecondary
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
extension LivePerformanceView {
    func designPreviewDeveloperProfiling() -> some View { developerProfiling }
}
#endif
