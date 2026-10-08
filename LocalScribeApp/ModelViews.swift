import SwiftUI
import LocalScribeCore

struct ModelsView: View {
    @ObservedObject var controller: AppController
    var showsDone = true
    @State private var detailModel: SpeechModel?
    @State private var startingDownload = false
    @Environment(\.dismiss) private var dismiss
    private var missingModels: [SpeechModel] { SpeechModel.allCases.filter { !controller.installedModels.contains($0) } }
    private var canChangeModels: Bool { controller.phase == .idle && controller.recordingModel == nil && !controller.keyboardSessionActive }
    private var canStartDownload: Bool { canChangeModels && controller.downloadingModel == nil && !startingDownload }

    var body: some View {
        NavigationStack {
            Form {
                downloadSection
                catalogSection("Streaming", models: SpeechModel.allCases.filter(SpeechModelPresentation.isStreaming),
                    explanation: "Live text updates incrementally as speech arrives. These models reuse recognition state.")
                catalogSection("Periodic text", models: SpeechModel.allCases.filter { !SpeechModelPresentation.isStreaming($0) },
                    explanation: "These models recognize overlapping audio windows. Preview starts after 5 seconds of audio, then updates every 3 seconds as processing catches up.")
                Section {
                    Text("The recording model provides both preview and final text. Installed models stay on this iPhone; downloads need internet.")
                        .font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                }
            }
            .scribeForm().navigationTitle("Models")
            .toolbar {
                if showsDone { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
            .sheet(item: $detailModel) { model in ModelDetailsView(model: model, controller: controller) }
        }
    }

    private var downloadSection: some View {
        Section {
            if let downloading = controller.downloadingModel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Downloading \(controller.downloadCompletedCount + 1) of \(controller.downloadTotalCount)")
                        .font(.body)
                    Text(downloading.name).font(.subheadline).foregroundStyle(AppTheme.inkSecondary)
                    if controller.downloadTotalCount > 1 {
                        Button(controller.downloadCancelled ? "Cancelling…" : "Cancel all downloads", role: .cancel) { controller.cancelDownload() }
                            .disabled(controller.downloadCancelled).frame(minHeight: 44)
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { downloadSummary; Spacer(minLength: 8); downloadAllButton }
                    VStack(alignment: .leading, spacing: 8) { downloadSummary; downloadAllButton }
                }
            }
        } footer: {
            if controller.downloadCancelled { Text("Download cancelled. Installed models are kept.") }
            else if let status = controller.modelStatus { Text(status) }
        }
    }

    private var downloadSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(missingModels.isEmpty ? "All models installed" : "Download all")
            if let bytes = SpeechModelPresentation.totalBytes(for: missingModels), !missingModels.isEmpty {
                Text(SpeechModelPresentation.formattedBytes(bytes) + " · \(missingModels.count) models")
                    .font(.footnote).foregroundStyle(AppTheme.inkSecondary)
            }
        }
    }

    private var downloadAllButton: some View {
        Button(startingDownload ? "Starting…" : "Download") { startDownload() }
            .buttonStyle(.borderless).frame(minHeight: 44)
            .disabled(missingModels.isEmpty || !canStartDownload)
            .accessibilityLabel("Download all missing models")
    }

    private func startDownload(_ model: SpeechModel? = nil) {
        guard canStartDownload else { return }
        startingDownload = true
        Task {
            defer { startingDownload = false }
            if let model { await controller.download(model) }
            else { await controller.downloadAllMissingModels() }
        }
    }

    private func catalogSection(_ title: String, models: [SpeechModel], explanation: String) -> some View {
        Section {
            ForEach(models) { model in modelRow(model) }
        } header: { Text(title) } footer: { Text(explanation) }
    }

    private func modelRow(_ model: SpeechModel) -> some View {
        let installed = controller.installedModels.contains(model)
        let selected = controller.selectedModel == model
        let loaded = controller.preparedModel == model
        let downloading = controller.downloadingModel == model
        let failed = controller.failedDownloadModel == model
        let measurement = ModelMeasurementPresentation.latestLoad(for: model, reports: controller.modelPreparationReports)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.name).foregroundStyle(AppTheme.ink).fixedSize(horizontal: false, vertical: true)
                    Text(SpeechModelPresentation.size(model) + " · " + (model.languages == "English" ? "English" : "25 languages") + (model == .parakeetRealtimeEOU ? " · no punctuation" : ""))
                        .font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    Text("Latest load · " + ModelMeasurementPresentation.loadTime(measurement))
                        .font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    Text("App peak RAM during load · " + ModelMeasurementPresentation.peakMemory(measurement))
                        .font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    if selected && installed {
                        Text("Action Button · " + SpeechModelPresentation.actionButtonState(controller))
                            .font(.footnote).foregroundStyle(controller.actionButtonModelReady ? AppTheme.success : AppTheme.inkSecondary)
                    }
                    else if loaded { Text("Loaded").font(.footnote).foregroundStyle(AppTheme.success) }
                    else if installed { Text("Installed").font(.footnote).foregroundStyle(AppTheme.inkSecondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { detailModel = model } label: { Image(systemName: "info.circle").frame(width: 44, height: 44) }
                    .buttonStyle(.borderless).accessibilityLabel("Details for \(model.name)")
            }
            if downloading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: controller.downloadProgress > 0 ? controller.downloadProgress : nil)
                        .accessibilityLabel("Downloading \(model.name)")
                    HStack(spacing: 12) {
                        Text(controller.downloadProgress > 0 ? "\(Int(controller.downloadProgress * 100))%" : "Preparing download…")
                            .font(.footnote).monospacedDigit().foregroundStyle(AppTheme.inkSecondary)
                        Spacer(minLength: 0)
                        Button(controller.downloadCancelled ? "Cancelling…" : controller.downloadTotalCount > 1 ? "Cancel all" : "Cancel", role: .cancel) {
                            controller.cancelDownload()
                        }.buttonStyle(.borderless).frame(minHeight: 44).disabled(controller.downloadCancelled)
                    }
                }
            } else if failed {
                Text(controller.errorMessage ?? "Download failed").font(.footnote).foregroundStyle(AppTheme.error)
                Button("Retry") { startDownload(model) }
                    .buttonStyle(.borderless).frame(minHeight: 44).disabled(!canStartDownload)
                    .accessibilityLabel("Retry downloading \(model.name)")
            } else if selected && installed {
                Label("Selected", systemImage: "checkmark").font(.footnote.weight(.medium)).foregroundStyle(AppTheme.ink)
            } else {
                Button(installed ? "Use" : "Download") {
                    if installed { controller.selectedModel = model }
                    else { startDownload(model) }
                }
                .buttonStyle(.borderless).frame(minHeight: 44)
                .disabled(!canStartDownload)
                .accessibilityLabel(installed ? "Use \(model.name)" : "Download \(model.name)")
            }
            if selected && installed { BackgroundModelPreparationControls(controller: controller) }
        }.padding(.vertical, 4).listRowBackground(AppTheme.surface)
    }
}

struct BackgroundModelPreparationControls: View {
    @ObservedObject var controller: AppController
    private var canPrepare: Bool {
        controller.phase == .idle && controller.recordingModel == nil && !controller.keyboardSessionActive
            && controller.downloadingModel == nil && controller.installedModels.contains(controller.selectedModel)
    }
    var body: some View {
        if canPrepare {
            VStack(alignment: .leading, spacing: 4) {
                if controller.backgroundModelPreparationActive {
                    if let status = controller.backgroundModelPreparationStatus {
                        Text(statusText(status)).font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    }
                    Button("Cancel loading") { controller.cancelSelectedModelPreparation() }
                        .buttonStyle(.borderless).frame(minHeight: 44)
                } else if !controller.actionButtonModelReady {
                    Button(controller.actionButtonModelLoading ? "Continue in Background" : "Load in Background") {
                        controller.prepareSelectedModelInBackground()
                    }.buttonStyle(.borderless).frame(minHeight: 44)
                }
            }
        }
    }
    private func statusText(_ status: BackgroundModelPreparation.Status) -> String {
        switch status {
        case .submitted: "Requesting background loading…"
        case .running: "Background loading allowed"
        case .foregroundOnly(let reason): "Foreground only · " + reason
        case .ready: "Ready"
        case .failed(let reason): "Loading failed · " + reason
        case .cancelled(let reason): "Loading cancelled · " + reason
        }
    }
}

private struct ModelDetailsView: View {
    let model: SpeechModel
    @ObservedObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Download files", value: SpeechModelPresentation.exactDownloadSize(model))
                    LabeledContent("Installed disk size", value: "Not measured")
                    LabeledContent("Installation", value: controller.installedModels.contains(model) ? "Installed" : "Not downloaded")
                    LabeledContent("Runtime", value: controller.preparedModel == model ? "Loaded" : "Not loaded")
                    if controller.preparedModel == model {
                        LabeledContent("Configured processors", value: SpeechModelPresentation.loadedProcessing(model, controller: controller))
                    }
                    if controller.selectedModel == model {
                        LabeledContent("Action Button state", value: SpeechModelPresentation.actionButtonState(controller))
                    }
                    LabeledContent("Languages", value: model.languages)
                    LabeledContent("Recognition", value: SpeechModelPresentation.isStreaming(model) ? "Streaming" : "Overlapping windows")
                    Text(SpeechModelPresentation.isStreaming(model)
                        ? "Updates text incrementally as speech arrives, reusing recognition state. The same model provides preview and final text."
                        : "First preview after 5 seconds of audio, then updates every 3 seconds as processing catches up. The same model provides preview and final text.")
                        .font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    LabeledContent("On-demand processing", value: SpeechModelPresentation.inAppProcessing(model))
                    Text(SpeechModelPresentation.backend(model)).font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    LabeledContent("Action Button", value: "CPU only · same model")
                    Text(model.detail).foregroundStyle(AppTheme.inkSecondary)
                } footer: {
                    Text("Keep model loaded prepares the same files for CPU-only Dictate and Action Button use. With it off, cold in-app loads use the processing path above. Performance shows the loaded configuration. Recognition speed depends on the model; iOS controls background execution and microphone activation.")
                }
                ModelLoadMeasurementView(report: ModelMeasurementPresentation.latestLoad(for: model, reports: controller.modelPreparationReports))
                if model.languages != "English" {
                    Section("Supported languages") {
                        Text("Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Swedish, Ukrainian.")
                    }
                }
                Section { NavigationLink("Credits & licenses") { AboutView() } }
            }
            .scribeForm().navigationTitle(model.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct ModelLoadMeasurementView: View {
    let report: ModelPreparationReport?
    var body: some View {
        Section {
            LabeledContent("Load time", value: ModelMeasurementPresentation.loadTime(report))
            LabeledContent("App peak RAM during load", value: ModelMeasurementPresentation.peakMemory(report))
            if let measurement = report {
                let operation = measurement.report
                LabeledContent("Result", value: operation.successful ? "Completed" : "Failed")
                LabeledContent("Measured", value: operation.date.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Device", value: measurement.hardwareIdentifier ?? "Not recorded")
                LabeledContent("iOS version", value: measurement.operatingSystemVersion ?? "Not recorded")
                LabeledContent("App version", value: measurement.appVersion ?? "Not recorded")
                LabeledContent("Execution configuration", value: ModelMeasurementPresentation.contextName(operation.executionContext))
                DisclosureGroup("Requested processors") {
                    Text(operation.requestedBackend).font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                }
                if let phases = operation.preparationPhases, !phases.isEmpty {
                    PreparationPhaseMeasurements(phases: phases)
                }
            }
        } header: { Text("Latest load measurement") } footer: {
            Text("RAM is the sampled peak for the whole app, including its interface and loading work. Brief spikes may be missed. Download file totals exclude compiled caches; installed disk usage is not measured.")
        }
    }
}

struct PreparationPhaseMeasurements: View {
    let phases: [EnginePreparationPhaseTiming]
    var body: some View {
        DisclosureGroup("Loading phases") {
            ForEach(Array(phases.enumerated()), id: \.offset) { _, timing in
                LabeledContent(ModelMeasurementPresentation.phaseName(timing.phase)) {
                    Text(ModelMeasurementPresentation.duration(timing.elapsedSeconds) + (timing.completed ? "" : " · stopped"))
                        .foregroundStyle(AppTheme.inkSecondary)
                }
            }
        }
    }
}

enum ModelMeasurementPresentation {
    static func latestLoad(for model: SpeechModel, reports: [ModelPreparationReport]) -> ModelPreparationReport? {
        reports.filter { $0.report.model == model }.max { $0.report.date < $1.report.date }
    }
    static func duration(_ seconds: Double) -> String { String(format: "%.2f s", seconds) }
    static func loadTime(_ report: ModelPreparationReport?) -> String {
        guard let report else { return "Not measured" }
        return duration(report.report.resources.elapsedSeconds) + (report.report.successful ? "" : " · failed")
    }
    static func peakMemory(_ report: ModelPreparationReport?) -> String {
        guard let peak = report?.report.resources.sampledPeakPhysicalFootprintBytes else { return "Not measured" }
        return String(format: "%.1f MiB", Double(peak) / 1_048_576)
    }
    static func phaseName(_ phase: EnginePreparationPhaseTiming.Phase) -> String {
        switch phase {
        case .previousModelRelease: "Previous model release"
        case .installationCheck: "Installation check"
        case .integrityVerification: "File verification"
        case .localCoreMLLoad: "Core ML loading"
        case .nativeCPULoad: "CPU runtime loading"
        case .vocabularyLoad: "Vocabulary loading"
        case .preprocessorLoad: "Preprocessor loading"
        case .encoderLoad: "Encoder loading"
        case .decoderLoad: "Decoder loading"
        case .jointLoad: "Joint loading"
        case .recognizerInitialization: "Recognizer setup"
        }
    }
    static func contextName(_ context: ModelExecutionContext?) -> String {
        switch context {
        case .foreground: "Foreground defaults"
        case .backgroundCapable: "CPU only"
        case nil: "Not recorded"
        }
    }
}

/// Presentation follows the current adapters and pinned catalog. These labels
/// describe requested compute paths, not measured GPU/Neural Engine occupancy.
enum SpeechModelPresentation {
    static func isStreaming(_ model: SpeechModel) -> Bool { model == .parakeetRealtimeEOU || model == .moonshineSmall }
    static func mode(_ model: SpeechModel) -> String { isStreaming(model) ? "Streaming · live text" : "Periodic text · first 5 s, then every 3 s" }
    @MainActor static func actionButtonState(_ controller: AppController) -> String {
        if controller.actionButtonModelReady { return "Ready" }
        if controller.actionButtonModelLoading { return "Loading…" }
        return "Not loaded"
    }
    static func inAppProcessing(_ model: SpeechModel) -> String {
        if isStreaming(model) { return "CPU only" }
        return model == .parakeetPhononLUT3 ? "CPU + GPU / Neural Engine" : "CPU + Neural Engine"
    }
    @MainActor static func loadedProcessing(_ model: SpeechModel, controller: AppController) -> String {
        guard controller.preparedModel == model, let context = controller.preparedExecutionContext else { return "Unavailable" }
        return context == .backgroundCapable ? "CPU only" : inAppProcessing(model)
    }
    static func backend(_ model: SpeechModel) -> String {
        if model == .moonshineSmall { return "Moonshine native ONNX Runtime · CPU only. GPU and Neural Engine disabled." }
        if model == .parakeetPhononLUT3 { return "Core ML encoder · CPU + GPU requested. Other components · CPU + Neural Engine requested." }
        if model == .parakeetRealtimeEOU { return "Core ML · CPU only. GPU and Neural Engine disabled." }
        return "Core ML · CPU + Neural Engine requested. GPU disabled."
    }

    private static let catalogBytes: [String: Int64] = {
        guard let manifest = try? ModelIntegrityManifest.bundled() else { return [:] }
        return Dictionary(manifest.models.map { ($0.id, $0.totalBytes) }, uniquingKeysWith: { first, _ in first })
    }()

    static func size(_ model: SpeechModel) -> String { bytes(model).map(formattedBytes) ?? model.downloadSize }
    static func exactDownloadSize(_ model: SpeechModel) -> String {
        bytes(model).map { formattedBytes($0) + " · " + $0.formatted() + " bytes" } ?? "Not measured"
    }
    static func formattedBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    static func totalBytes(for models: [SpeechModel]) -> Int64? {
        var total: Int64 = 0
        for model in models {
            guard let size = bytes(model) else { return nil }
            total += size
        }
        return total
    }
    private static func bytes(_ model: SpeechModel) -> Int64? {
        let id: String = switch model {
        case .parakeetUltra: "ultra"
        case .parakeetPhonon: "phonon2"
        case .parakeetPhononG4: "phonon2-g4"
        case .parakeetPhononG1: "phonon2-g1"
        case .parakeetPhononLUT6: "phonon2-lut6"
        case .parakeetPhononLUT3: "phonon2-lut3"
        case .moonshineSmall: "moonshine-small"
        case .parakeetRedux: "redux"
        case .parakeetRealtimeEOU: "parakeet-eou-320ms"
        }
        return catalogBytes[id]
    }
}
