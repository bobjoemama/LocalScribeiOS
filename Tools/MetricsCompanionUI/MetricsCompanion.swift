import SwiftUI
import AppKit
import Darwin
import UniformTypeIdentifiers

struct USBDevice: Decodable, Identifiable {
    let udid: String
    let name: String
    var id: String { udid }
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
    private var process: Process?
    private var generation = UUID()
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var buffer = Data()
    private var stdoutEnded = false
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
        guard let python = configuredPython ?? (Bundle.main.object(forInfoDictionaryKey: "CollectorPython") as? String),
              let collector = (traceArguments == nil ? configuredCollector : nil) ?? (Bundle.main.object(forInfoDictionaryKey: traceArguments == nil ? "CollectorScript" : "TraceScript") as? String),
              FileManager.default.isExecutableFile(atPath: python),
              FileManager.default.fileExists(atPath: collector) else {
            status = "Collector is unavailable. Rebuild after preparing its local environment."
            return
        }
        if !list && traceArguments == nil && (selected.isEmpty || code.isEmpty || code.utf8.count > 2048 || code.contains("\n") || code.contains("\r")) {
            status = "Select a USB iPhone and paste a fresh connection code."
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
        stdoutEnded = false; pendingExit = nil
        process = child; input = stdin; output = stdout; errors = stderr
        busy = true; collecting = !list; waiting = true
        status = traceOperation ? "Analyzing the selected trace window…" : (list ? "Looking for USB iPhones…" : "Connecting…")
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in
                guard let self, self.generation == runID else { return }
                self.receive(data)
            }
        }
        // Drain without displaying or retaining dependency diagnostics or secrets.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
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
            if child.isRunning { stop() } else { finished(exitCode: -1) }
        }
    }

    private func receive(_ data: Data) {
        guard process != nil else { return }
        if data.isEmpty {
            stdoutEnded = true
            if let pendingExit { finished(exitCode: pendingExit) }
            return
        }
        guard buffer.count + data.count <= 65536 else {
            status = "Collector returned an invalid response."
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
            case "connecting": status = "Connected to iPhone. Preparing metrics…"
            case "collecting": status = "Sending metrics to LocalScribe on your iPhone."
            case "metricsUnavailable": status = "Connected; phone did not report usable counters."
            case "graphicsUnavailable": status = "Sending CPU and memory. GPU metrics unavailable."
            case "stopped": status = "Stopped."
            case "failed": status = "Connection failed. Check USB trust, Developer Mode and Xcode preparation; copy a fresh code."
            default: break
            }
        }
    }

    private func terminated(exitCode: Int32) {
        pendingExit = exitCode
        if stdoutEnded { finished(exitCode: exitCode); return }
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
        } else if listing {
            if exitCode == 0, let found = try? JSONDecoder().decode([USBDevice].self, from: buffer) {
                devices = found
                if !found.contains(where: { $0.udid == selected }) { selected = "" }
                status = found.isEmpty ? "No USB iPhone found. Connect and trust it in Finder, then refresh." : "Select your iPhone and paste its connection code."
            } else { status = "Could not list USB devices. Check the collector environment and USB connection." }
        } else if exitCode == 0 { status = "Stopped." }
        else if !status.contains("failed") && !status.contains("invalid") { status = "Connection ended. Check USB and copy a fresh connection code." }
        for handle in [input?.fileHandleForWriting, output?.fileHandleForReading, errors?.fileHandleForReading] { try? handle?.close() }
        generation = UUID()
        process = nil; input = nil; output = nil; errors = nil
        buffer.removeAll(keepingCapacity: false)
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
@main
struct MetricsCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = CompanionModel()
    var body: some Scene {
        Window("LocalScribe Metrics", id: "metrics") {
            TabView {
            VStack(alignment: .leading, spacing: 18) {
                Text("LocalScribe Metrics").font(.title2.bold())
                Text("Connect your iPhone by USB and open LocalScribe’s metrics screen.").foregroundStyle(.secondary)
                HStack {
                    Picker("iPhone", selection: $model.selected) {
                        Text("Select a USB iPhone").tag("")
                        ForEach(model.devices) { device in Text(device.name).tag(device.udid) }
                    }.disabled(model.busy)
                    Button("Refresh") { model.refresh() }.disabled(model.busy)
                }
                HStack {
                    SecureField("Connection code", text: $model.code).textFieldStyle(.roundedBorder).disabled(model.busy)
                    Button("Paste") {
                        if let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 2048 {
                            model.code = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }.disabled(model.busy)
                }
                HStack {
                    Button("Start") { model.start() }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || model.selected.isEmpty || model.code.isEmpty)
                    Button("Stop") { model.stop() }.disabled(!model.busy)
                    if model.busy && model.waiting { ProgressView().controlSize(.small) }
                    else if model.busy { Text("Active").font(.caption).foregroundStyle(.secondary) }
                }
                Text(model.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24).frame(width: 490, alignment: .leading)
            .tabItem { Text("Live USB") }
            VStack(alignment: .leading, spacing: 18) {
                Text("Trace report").font(.title2.bold())
                Text("Record ANE or GPU activity in Instruments, then select a trace and the exact analysis window. Reports describe trace-wide activity.").foregroundStyle(.secondary)
                HStack {
                    Button("Open Instruments") { model.openInstruments() }
                    Button("Choose trace…") { model.chooseTrace() }.disabled(model.busy)
                }
                Text(model.tracePath?.lastPathComponent ?? "No trace selected").lineLimit(1)
                HStack {
                    TextField("Start (seconds)", text: $model.startSeconds)
                    TextField("Duration (seconds)", text: $model.durationSeconds)
                }.textFieldStyle(.roundedBorder).disabled(model.busy)
                HStack {
                    Button("Save JSON report…") { model.exportReport() }.disabled(model.busy || model.tracePath == nil)
                    Button("Stop") { model.stop() }.disabled(!model.busy)
                }
                Text(model.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(24).frame(width: 490, alignment: .leading)
                .tabItem { Text("Trace report") }
            }
            .onAppear { delegate.model = model; model.refresh() }
        }.windowResizability(.contentSize)
    }
}

#endif
