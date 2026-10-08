import SwiftUI
import LocalScribeCore

struct ModelsView: View {
    @ObservedObject var controller: AppController
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $detailModel) { model in ModelDetailsView(model: model) }
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.name).foregroundStyle(AppTheme.ink).fixedSize(horizontal: false, vertical: true)
                    Text(SpeechModelPresentation.size(model) + " · " + (model.languages == "English" ? "English" : "25 languages") + (model == .parakeetRealtimeEOU ? " · no punctuation" : ""))
                        .font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    if loaded { Text("Loaded").font(.footnote).foregroundStyle(AppTheme.success) }
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
        }.padding(.vertical, 4).listRowBackground(AppTheme.surface)
    }
}

private struct ModelDetailsView: View {
    let model: SpeechModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Download size", value: SpeechModelPresentation.size(model))
                    LabeledContent("Languages", value: model.languages)
                    LabeledContent("Recognition", value: SpeechModelPresentation.isStreaming(model) ? "Streaming" : "Overlapping windows")
                    Text(SpeechModelPresentation.isStreaming(model)
                        ? "Updates text incrementally as speech arrives, reusing recognition state. The same model provides preview and final text."
                        : "First preview after 5 seconds of audio, then updates every 3 seconds as processing catches up. The same model provides preview and final text.")
                        .font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    LabeledContent("Default in-app processing", value: SpeechModelPresentation.inAppProcessing(model))
                    Text(SpeechModelPresentation.backend(model)).font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    LabeledContent("Action Button", value: "CPU only · same model")
                    Text(model.detail).foregroundStyle(AppTheme.inkSecondary)
                } footer: {
                    Text("Action Button uses the same model files with CPU-only processing and may prepare them separately. Preparation and recognition speed depend on the model. iOS controls background execution and microphone activation.")
                }
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

/// Presentation follows the current adapters and pinned catalog. These labels
/// describe requested compute paths, not measured GPU/Neural Engine occupancy.
enum SpeechModelPresentation {
    static func isStreaming(_ model: SpeechModel) -> Bool { model == .parakeetRealtimeEOU || model == .moonshineSmall }
    static func mode(_ model: SpeechModel) -> String { isStreaming(model) ? "Streaming · live text" : "Periodic text · first 5 s, then every 3 s" }
    static func inAppProcessing(_ model: SpeechModel) -> String {
        if isStreaming(model) { return "CPU only" }
        return model == .parakeetPhononLUT3 ? "CPU + GPU / Neural Engine" : "CPU + Neural Engine"
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
