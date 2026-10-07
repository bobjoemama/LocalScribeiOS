import SwiftUI
import AppKit
import Darwin
import UniformTypeIdentifiers

struct USBDevice: Decodable, Identifiable {
    let udid: String
    let name: String
    var id: String { udid }
    var displayName: String {
        // Enumeration already provides this identifier; do not query the device again.
        "\(name) (serial …\(udid.suffix(4)))"
    }
}

enum CompanionStatusTone {
    case neutral, working, active, warning, failed, complete
}

enum CompanionDiagnostic {
    // Never present arbitrary dependency stderr. These are exact messages from
    // our collector/trace reader, mapped to UI copy without identifiers or paths.
    static func safeMessage(_ raw: String) -> String? {
        guard raw.utf8.count <= 1024 else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let messages: [String: String] = [
            "Invalid pairing code. Copy a fresh code from the iPhone.": "Connection code is invalid. Copy a fresh connection code from LocalScribe on your iPhone.",
            "Phone authentication failed. Keep LocalScribe open and copy a fresh pairing code.": "Connection code was rejected. Keep LocalScribe open on your iPhone and copy a fresh connection code.",
            "The selected USB device is unavailable. Connect and trust it in Finder first.": "The selected iPhone is unavailable. Connect and trust it in Finder, then refresh.",
            "The selected USB device is unavailable.": "The selected iPhone is unavailable. Connect and trust it in Finder, then refresh.",
            "Phone connection ended. Start a new session in LocalScribe.": "Connection ended. Enable USB metrics in LocalScribe and copy a fresh connection code.",
            "No device measurements arrived. Check Developer Mode and Xcode device preparation, then reconnect.": "No measurements arrived. Check Developer Mode and Xcode device preparation, then reconnect.",
            "Custom usbmux sockets are disabled. Unset USBMUXD_SOCKET_ADDRESS.": "A custom USB connection is disabled. Use the standard local USB connection.",
            "TCP tunnel relay is disabled. Unset PYMOBILEDEVICE3_USERSPACE_TCP_RELAY.": "A network relay is disabled. Use a direct USB connection.",
            "Metrics connection failed. Check USB trust, Developer Mode, iOS 17.4 or later, and Xcode device preparation. No automatic pairing or setup was attempted.": "Metrics connection failed. Check USB trust, Developer Mode and Xcode device preparation. No automatic pairing or setup was attempted."
        ]
        if let message = messages[line] { return message }
        let invalidMetrics = ["Invalid metrics sequence.", "Invalid metrics fields.", "Invalid CPU core metrics.", "Invalid app memory metrics.", "Invalid utilization metrics.", "Invalid metrics values."]
        if invalidMetrics.contains(line) { return "Metrics response was invalid. Stop and reconnect with a fresh connection code." }
        let tracePrefix = "Import failed: "
        guard line.hasPrefix(tracePrefix) else { return nil }
        let traceLine = String(line.dropFirst(tracePrefix.count))
        let traceMessages = [
            "XML exceeds the 64 MiB import budget; export a shorter recording.",
            "DTD, entity declarations and non-UTF-8 XML are unsupported.",
            "XML has too many elements; export a shorter recording.",
            "Times must be finite.",
            "Choose a nonnegative start and positive finite duration.",
            "Invalid XML cell reference.",
            "Export row does not match its schema.",
            "Unsupported time engineering type.",
            "Invalid interval.",
            "No supported counter covers the entire selected window; choose a window within exported interval coverage.",
            "xctrace export exceeded its time or size budget.",
            "xctrace export failed; check the trace in Instruments locally.",
            "Select an existing .trace bundle or exported .xml file.",
            "Invalid run number in table of contents.",
            "Multiple recording runs found; export one chosen run to XML in Instruments.",
            "Too many supported tables; select a shorter trace.",
            "Combined exports exceed the 64 MiB import budget."
        ]
        if traceMessages.contains(traceLine) { return traceLine }
        for table in ["ane-hw-intervals", "metal-gpu-intervals"] {
            if traceLine == "\(table) lacks supported start/duration/state columns." {
                return "The trace is missing supported interval columns. Check the recording in Instruments."
            }
            if traceLine == "\(table) has an unrecognized state; do not infer activity from numeric state codes." {
                return "The trace contains an unsupported activity state. Check the recording in Instruments."
            }
        }
        // OSError/parse-error text can contain a user path or trace contents.
        return nil
    }
}

@MainActor
final class CompanionModel: ObservableObject {
    @Published var devices: [USBDevice] = []
    @Published var selected = ""
    @Published var code = ""
    @Published var status = "Connect your iPhone by USB, then refresh."
    @Published var busy = false
    @Published var collecting = false
    @Published var waiting = false
    @Published private(set) var diagnostic: String?
    @Published private(set) var statusTone: CompanionStatusTone = .neutral
    private var process: Process?
    private var generation = UUID()
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var buffer = Data()
    private var stdoutEnded = false
    private var stderrEnded = false
    private var diagnosticBuffer = Data()
    private var discardingDiagnosticLine = false
    private var graphicsUnavailable = false
    private var pendingExit: Int32?
    @Published var tracePath: URL?
    @Published var startSeconds = "0"
    @Published var durationSeconds = "30"
    private var traceOperation = false
    private var listing = false
    private var quitting = false
    private var quitCompletion: (() -> Void)?

    private let configuredPython: String?
    private let configuredCollector: String?
    init(pythonPath: String? = nil, collectorPath: String? = nil) {
        configuredPython = pythonPath
        configuredCollector = collectorPath
    }

    func refresh() { launch(list: true) }
    func start() { launch(list: false) }

    func chooseTrace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "trace") ?? .package, .xml]
        panel.begin { [weak self] response in
            if response == .OK { self?.tracePath = panel.url }
        }
    }
    func openInstruments() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/Instruments.app"))
    }
    func exportReport() {
        guard let tracePath, let start = Double(startSeconds), let duration = Double(durationSeconds),
              start.isFinite, duration.isFinite, start >= 0, duration > 0,
              (start * 1000).isFinite, (duration * 1000).isFinite else {
            status = "Choose a trace, a nonnegative start and a positive duration."
            statusTone = .warning
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LocalScribe-metrics-report.json"
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.launch(list: false, traceArguments: [tracePath.path, "--start-ms", String(start * 1000), "--duration-ms", String(duration * 1000), "--output", destination.path])
        }
    }
    private func launch(list: Bool, traceArguments: [String]? = nil) {
        guard process == nil, !quitting else { return }
        diagnostic = nil
        guard let python = configuredPython ?? (Bundle.main.object(forInfoDictionaryKey: "CollectorPython") as? String),
              let collector = (traceArguments == nil ? configuredCollector : nil) ?? (Bundle.main.object(forInfoDictionaryKey: traceArguments == nil ? "CollectorScript" : "TraceScript") as? String),
              FileManager.default.isExecutableFile(atPath: python),
              FileManager.default.fileExists(atPath: collector) else {
            status = "Collector is unavailable. Rebuild after preparing its local environment."
            statusTone = .failed
            return
        }
        if !list && traceArguments == nil && (selected.isEmpty || code.isEmpty || code.utf8.count > 2048 || code.contains("\n") || code.contains("\r")) {
            status = "Select a USB iPhone and paste a fresh connection code."
            statusTone = .warning
            return
        }
        let runID = UUID()
        generation = runID
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = [collector] + (traceArguments ?? (list ? ["--list-usb"] : ["--udid", selected]))
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1"]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        traceOperation = traceArguments != nil
        listing = list
        buffer.removeAll(keepingCapacity: false)
        stdoutEnded = false; stderrEnded = false; pendingExit = nil
        diagnosticBuffer.removeAll(keepingCapacity: false)
        discardingDiagnosticLine = false
        diagnostic = nil
        graphicsUnavailable = false
        process = child; input = stdin; output = stdout; errors = stderr
        busy = true; collecting = !list; waiting = true
        statusTone = .working
        status = traceOperation ? "Analyzing the selected trace window…" : (list ? "Looking for USB iPhones…" : "Connecting…")
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in
                guard let self, self.generation == runID else { return }
                self.receive(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in
                guard let self, self.generation == runID else { return }
                self.receiveDiagnostic(data)
            }
        }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor [weak self] in
                guard let self, self.generation == runID else { return }
                self.terminated(exitCode: child.terminationStatus)
            }
        }
        do {
            try child.run()
            // Only the child writes these streams. Keeping a parent writer open
            // prevents EOF even after the collector has exited.
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            try? stdin.fileHandleForReading.close()
            if !list && !traceOperation {
                let secret = code
                code = ""
                try stdin.fileHandleForWriting.write(contentsOf: Data((secret + "\n").utf8))
            }
            try stdin.fileHandleForWriting.close()
        } catch {
            code = ""
            status = "Could not start the collector. Check its local environment."
            statusTone = .failed
            if child.isRunning { stop() } else { finished(exitCode: -1) }
        }
    }

    private func receive(_ data: Data) {
        guard process != nil else { return }
        if data.isEmpty {
            stdoutEnded = true
            if stderrEnded, let pendingExit { finished(exitCode: pendingExit) }
            return
        }
        guard buffer.count + data.count <= 65536 else {
            status = "Collector returned an invalid response."
            diagnostic = "The collector response was invalid. Stop and reconnect with a fresh connection code."
            statusTone = .failed
            stop()
            return
        }
        buffer.append(data)
        if listing { return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard line.count <= 4096,
                  let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  event["type"] as? String == "status",
                  let state = event["state"] as? String else { continue }
            if ["collecting", "metricsUnavailable", "graphicsUnavailable", "stopped", "failed"].contains(state) { waiting = false }
            switch state {
            case "connecting":
                status = "Connected to iPhone. Preparing metrics…"
                statusTone = .working
            case "collecting":
                status = graphicsUnavailable ? "Sending CPU and memory. GPU metrics unavailable." : "Sending metrics to LocalScribe on your iPhone."
                statusTone = graphicsUnavailable ? .warning : .active
            case "metricsUnavailable":
                status = "Connected; phone did not report usable counters."
                statusTone = .warning
            case "graphicsUnavailable":
                graphicsUnavailable = true
                status = "Sending CPU and memory. GPU metrics unavailable."
                statusTone = .warning
            case "stopped":
                status = "Stopped."
                statusTone = .neutral
            case "failed":
                status = "Connection failed. Check USB trust, Developer Mode and Xcode preparation; copy a fresh connection code."
                statusTone = .failed
            default: break
            }
        }
    }

    private func receiveDiagnostic(_ data: Data) {
        guard process != nil else { return }
        if data.isEmpty {
            if !discardingDiagnosticLine { acceptDiagnosticLine() }
            diagnosticBuffer.removeAll(keepingCapacity: false)
            stderrEnded = true
            if stdoutEnded, let pendingExit { finished(exitCode: pendingExit) }
            return
        }
        // A dependency may write arbitrary or enormous lines. Keep at most
        // 1 KiB, discard an oversized line through its newline, and allow only
        // known messages. Never display or persist raw stderr.
        for byte in data {
            if byte == 10 {
                if !discardingDiagnosticLine { acceptDiagnosticLine() }
                diagnosticBuffer.removeAll(keepingCapacity: false)
                discardingDiagnosticLine = false
            } else if !discardingDiagnosticLine {
                if diagnosticBuffer.count < 1024 { diagnosticBuffer.append(byte) }
                else {
                    diagnosticBuffer.removeAll(keepingCapacity: false)
                    discardingDiagnosticLine = true
                }
            }
        }
    }

    private func acceptDiagnosticLine() {
        if let line = String(data: diagnosticBuffer, encoding: .utf8),
           let safe = CompanionDiagnostic.safeMessage(line) { diagnostic = safe }
    }

    private func terminated(exitCode: Int32) {
        pendingExit = exitCode
        if stdoutEnded && stderrEnded { finished(exitCode: exitCode); return }
        let runID = generation
        // Readability callbacks normally finish the drain immediately. A missed
        // EOF or inherited descriptor must never keep a dead child busy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.generation == runID, self.pendingExit != nil else { return }
            self.finished(exitCode: exitCode)
        }
    }

    private func finished(exitCode: Int32) {
        guard process != nil else { return }
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        if traceOperation {
            status = exitCode == 0 ? "Report saved. Import the JSON report in LocalScribe on your iPhone." : "Trace analysis failed. Check the trace in Instruments, its supported interval tables and the destination (reports never overwrite)."
            statusTone = exitCode == 0 ? .complete : .failed
        } else if listing {
            if exitCode == 0, let found = try? JSONDecoder().decode([USBDevice].self, from: buffer) {
                devices = found
                if !found.contains(where: { $0.udid == selected }) { selected = "" }
                status = found.isEmpty ? "No USB iPhone found. Connect and trust it in Finder, then refresh." : "Select your iPhone and paste its connection code."
                statusTone = found.isEmpty ? .warning : .neutral
            } else {
                status = "Could not list USB devices. Check the collector environment and USB connection."
                statusTone = .failed
            }
        } else if exitCode == 0 {
            status = "Stopped."
            statusTone = .neutral
        } else if !status.contains("failed") && !status.contains("invalid") {
            status = "Connection ended. Check USB and copy a fresh connection code."
            statusTone = .failed
        }
        for handle in [input?.fileHandleForWriting, output?.fileHandleForReading, errors?.fileHandleForReading] { try? handle?.close() }
        generation = UUID()
        process = nil; input = nil; output = nil; errors = nil
        buffer.removeAll(keepingCapacity: false)
        diagnosticBuffer.removeAll(keepingCapacity: false)
        busy = false; collecting = false; waiting = false
        if quitting { quitCompletion?(); quitCompletion = nil }
    }

    func stop() {
        guard let child = process else { return }
        guard child.isRunning else {
            finished(exitCode: pendingExit ?? child.terminationStatus)
            return
        }
        status = "Stopping…"
        statusTone = .working
        waiting = true
        try? input?.fileHandleForWriting.close()
        child.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak child] in
            guard let self, let child, self.process === child, child.isRunning else { return }
            _ = Darwin.kill(child.processIdentifier, SIGKILL)
        }
    }

    func prepareToQuit(_ completion: @escaping () -> Void) {
        quitting = true
        code = ""
        if process == nil { completion(); return }
        quitCompletion = completion
        stop()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: CompanionModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.busy else { return .terminateNow }
        model.prepareToQuit { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !METRICS_MODEL_TEST
private enum MetricsPalette {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        func color(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                    green: Double((value >> 8) & 255) / 255,
                    blue: Double(value & 255) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
    static let canvas = dynamic(0xF3F1ED, 0x141312)
    static let surface = dynamic(0xFFFFFF, 0x1E1C1A)
    static let surfaceInset = dynamic(0xECE9E3, 0x2A2724)
    static let ink = dynamic(0x1A1917, 0xF3F1ED)
    static let secondary = dynamic(0x6B6760, 0xA8A39A)
    static let onAccent = dynamic(0xFFFFFF, 0x141312)
    static let success = dynamic(0x2C794C, 0x5CC587)
    static let warning = dynamic(0x986200, 0xE8B04A)
    static let error = dynamic(0xB42318, 0xF2655B)

    static func status(_ tone: CompanionStatusTone) -> Color {
        switch tone {
        case .neutral: secondary
        case .working: ink
        case .active, .complete: success
        case .warning: warning
        case .failed: error
        }
    }
}

private struct MetricsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .foregroundStyle(enabled ? MetricsPalette.onAccent : MetricsPalette.secondary)
            .background(enabled ? MetricsPalette.ink : MetricsPalette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct CompanionStatusView: View {
    @ObservedObject var model: CompanionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(MetricsPalette.status(model.statusTone))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(MetricsPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let diagnostic = model.diagnostic {
                Text(diagnostic)
                    .font(.callout)
                    .foregroundStyle(MetricsPalette.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 15)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@main
struct MetricsCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = CompanionModel()
    var body: some Scene {
        Window("LocalScribe Metrics", id: "metrics") {
            TabView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Live metrics").font(.system(size: 20, weight: .semibold))
                    Text("Connect your iPhone by USB. In LocalScribe, open Settings → Performance → Developer profiling to copy a connection code.")
                        .font(.callout)
                        .foregroundStyle(MetricsPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("iPhone").font(.body.weight(.medium))
                        HStack(spacing: 10) {
                            Picker("iPhone", selection: $model.selected) {
                                Text("Select a USB iPhone").tag("")
                                ForEach(model.devices) { device in Text(device.displayName).tag(device.udid) }
                            }.labelsHidden().disabled(model.busy)
                            Button("Refresh") { model.refresh() }.disabled(model.busy)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connection code").font(.body.weight(.medium))
                        HStack(spacing: 10) {
                            SecureField("Connection code", text: $model.code)
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.busy)
                                .accessibilityLabel("Connection code")
                            Button("Paste") {
                                if let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 2048 {
                                    model.code = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }.disabled(model.busy)
                        }
                    }
                    HStack(spacing: 10) {
                        Button("Start") { model.start() }.buttonStyle(MetricsPrimaryButtonStyle())
                            .disabled(model.busy || model.selected.isEmpty || model.code.isEmpty)
                        Button("Stop") { model.stop() }.disabled(!model.busy)
                        if model.busy && model.waiting { ProgressView().controlSize(.small).padding(.leading, 4) }
                    }
                    CompanionStatusView(model: model)
                }
                .padding(28)
                .frame(width: 520, alignment: .leading)
                .background(MetricsPalette.canvas)
                .tabItem { Text("Live USB") }

                VStack(alignment: .leading, spacing: 20) {
                    Text("Trace report").font(.system(size: 20, weight: .semibold))
                    Text("Record ANE or GPU activity in Instruments, then choose the exact analysis window. Reports describe trace-wide activity.")
                        .font(.callout)
                        .foregroundStyle(MetricsPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Open Instruments") { model.openInstruments() }
                        Button("Choose trace…") { model.chooseTrace() }.disabled(model.busy)
                    }
                    Text(model.tracePath?.lastPathComponent ?? "No trace selected")
                        .font(.callout)
                        .foregroundStyle(model.tracePath == nil ? MetricsPalette.secondary : MetricsPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Start (seconds)").font(.body.weight(.medium))
                            TextField("Start (seconds)", text: $model.startSeconds).labelsHidden()
                                .monospacedDigit()
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Duration (seconds)").font(.body.weight(.medium))
                            TextField("Duration (seconds)", text: $model.durationSeconds).labelsHidden()
                                .monospacedDigit()
                        }
                    }.textFieldStyle(.roundedBorder).disabled(model.busy)
                    HStack(spacing: 10) {
                        Button("Save JSON report…") { model.exportReport() }.buttonStyle(MetricsPrimaryButtonStyle())
                            .disabled(model.busy || model.tracePath == nil)
                        Button("Stop") { model.stop() }.disabled(!model.busy)
                        if model.busy && model.waiting { ProgressView().controlSize(.small).padding(.leading, 4) }
                    }
                    CompanionStatusView(model: model)
                }
                .padding(28)
                .frame(width: 520, alignment: .leading)
                .background(MetricsPalette.canvas)
                .tabItem { Text("Trace report") }
            }
            .foregroundStyle(MetricsPalette.ink)
            .tint(MetricsPalette.ink)
            .background(MetricsPalette.canvas)
            .onAppear { delegate.model = model; model.refresh() }
        }.windowResizability(.contentSize)
    }
}
#endif
