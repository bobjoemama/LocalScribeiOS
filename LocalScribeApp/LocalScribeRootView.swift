import SwiftUI
import AppIntents
import UIKit
import LocalScribeCore

struct LocalScribeRootView: View {
    @ObservedObject var controller: AppController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    @State private var tab = 0
    @State private var showingModels = false
    @StateObject private var performance = LivePerformanceMonitor()
    @StateObject private var developerMetrics = DeveloperMetricsReceiver()
    @StateObject private var profilingReports = ProfilingReportStore()
    @State private var showingSavedData = false
    @State private var createdNote: CreatedNoteRequest?
    @State private var libraryPath: [LibraryDestination] = []
    @ObservedObject var notes: NotesController

    init(controller: AppController, notes: NotesController) {
        _controller = ObservedObject(wrappedValue: controller)
        _notes = ObservedObject(wrappedValue: notes)
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let names = ["dictate", "history", "library", "settings"]
        if let index = arguments.firstIndex(of: "--preview-tab"), index + 1 < arguments.count {
            _tab = State(initialValue: names.firstIndex(of: arguments[index + 1]) ?? 0)
        }
        if let index = arguments.firstIndex(of: "--preview-library"), index + 1 < arguments.count {
            let destination: LibraryDestination? = switch arguments[index + 1] {
            case "dictionary": .dictionary
            case "snippets": .snippets
            case "notes": .notes
            default: nil
            }
            if let destination { _tab = State(initialValue: 2); _libraryPath = State(initialValue: [destination]) }
        }
        #endif
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            DictateView(controller: controller, openModels: { showingModels = true }, saveNote: { text in createdNote = CreatedNoteRequest(id: notes.create(text: text)) })
                .tabItem { Label("Dictate", systemImage: "mic") }.tag(0)
            NativeHistoryView(controller: controller, openSavedData: { showingSavedData = true })
                .tabItem { Label("History", systemImage: "clock") }.tag(1)
            LibraryView(controller: controller, notes: notes, path: $libraryPath, openSavedData: { showingSavedData = true })
                .tabItem { Label("Library", systemImage: "books.vertical") }.tag(2)
            SettingsView(controller: controller, notes: notes, openModels: { showingModels = true })
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
        }
        .sheet(isPresented: $showingModels) { ModelsView(controller: controller) }
        .sheet(isPresented: $showingSavedData) {
            NavigationStack {
                SavedDataView(controller: controller, notes: notes)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingSavedData = false } } }
            }
        }
        .sheet(item: $createdNote) { request in
            NavigationStack {
                NotesView(controller: notes, dictation: controller, initialNoteID: request.id)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { createdNote = nil } } }
            }
        }
        .environmentObject(performance)
        .environmentObject(developerMetrics)
        .environmentObject(profilingReports)
        .preferredColorScheme(colorScheme)
        .alert("LocalScribe", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.setForeground(true); startPerformance() }
            else { performance.stop(); developerMetrics.stop() }
            if phase == .background { controller.setForeground(false) }
        }
        .onAppear {
            if controller.actionButtonRecording { tab = 0 }
            if scenePhase == .active { startPerformance() }
        }
        .onDisappear { performance.stop(); developerMetrics.stop() }
        .onChange(of: controller.actionButtonRecording) { _, recording in
            if recording { tab = 0 }
        }
        .onOpenURL { url in
            guard url.scheme == "localscribe" else { return }
            switch url.host {
            case "dictation": tab = 0
            case "models": showingModels = true
            case "dictionary": tab = 2; libraryPath = [.dictionary]
            case "snippets": tab = 2; libraryPath = [.snippets]
            case "notes": tab = 2; libraryPath = [.notes]
            case "history": tab = 1
            case "settings": tab = 3
            default: break
            }
        }
    }
    private func startPerformance() {
        let args = ProcessInfo.processInfo.arguments
        guard !args.contains("--benchmark-models"), !args.contains("--verify-dictation") else { return }
        performance.start()
    }

}

private struct CreatedNoteRequest: Identifiable { let id: UUID }

private struct DictateView: View {
    @ObservedObject var controller: AppController
    let openModels: () -> Void
    let saveNote: (String) -> Void
    @State private var copied = false
    @State private var showingPerformance = false
    @FocusState private var editing: Bool
    private var ready: Bool { controller.installedModels.contains(controller.selectedModel) }
    private var recording: Bool { controller.phase == .recording }
    private var active: Bool { recording || controller.phase == .transcribing }
    private var textToCopy: String { active ? controller.partialText : controller.transcript }
    private var canSelectModel: Bool {
        controller.phase == .idle && controller.downloadingModel == nil && !controller.keyboardSessionActive
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if active { livePreview }
                VStack(alignment: .leading, spacing: 4) {
                    modelMenu
                    if controller.phase == .idle, let modelStatus = controller.modelStatus {
                        modelLoadingStatus(modelStatus).padding(.bottom, 4)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 8)
                LivePerformanceStrip(open: { showingPerformance = true })
                    .padding(.horizontal, 20).padding(.bottom, 8)
                Divider()
                transcriptWorkspace
            }
            .background(Color(uiColor: .systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { recordingControls }
            .navigationTitle("Dictate").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingPerformance) {
                NavigationStack {
                    LivePerformanceView(controller: controller)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingPerformance = false } } }
                }
            }
            .toolbar {
                if !active, !controller.transcript.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { saveNote(controller.transcript) } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel("Save transcript as a note")
                    }
                }
                if editing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { editing = false; controller.saveTranscriptEdits() }
                    }
                }
            }
            .onChange(of: editing) { _, focused in if !focused { controller.saveTranscriptEdits() } }
            .onChange(of: controller.transcript) { _, _ in copied = false }
            .onChange(of: controller.partialText) { _, _ in copied = false }
        }
    }

    private var modelMenu: some View {
        Menu {
            Picker("Model", selection: $controller.selectedModel) {
                ForEach(SpeechModel.allCases) { model in
                    Text(controller.installedModels.contains(model) ? model.name : model.name + " (not downloaded)")
                        .tag(model).disabled(!controller.installedModels.contains(model))
                }
            }.pickerStyle(.inline)
            Divider()
            Button("Manage models", action: openModels)
        } label: {
            HStack(spacing: 8) {
                Text(controller.selectedModel.name).font(.subheadline)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
                Spacer(minLength: 0)
            }.frame(minHeight: 44)
        }
        .disabled(!canSelectModel)
        .accessibilityLabel("Speech model")
        .accessibilityValue(controller.selectedModel.name)
    }

    @ViewBuilder private var transcriptWorkspace: some View {
        if active {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !controller.partialText.isEmpty {
                            Text(controller.partialText).font(.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                                .accessibilityLabel("Live transcript")
                                .accessibilityValue(controller.partialText)
                        } else {
                            Text(recording ? "Listening…" : "Finishing transcription…")
                                .font(.body).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        }
                        Color.clear.frame(height: 1).id("live-transcript-end")
                    }
                }
                .onChange(of: controller.partialText) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("live-transcript-end", anchor: .bottom)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !controller.transcript.isEmpty {
            TextEditor(text: $controller.transcript).font(.body).focused($editing)
                .scrollContentBackground(.hidden).padding(.horizontal, 16).padding(.top, 12)
                .accessibilityLabel("Editable transcript")
        } else {
            ScrollView {
                Text(ready ? "Tap Record to begin." : "Choose a downloaded model to begin.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The in-app preview sits immediately below the top bar. Outside this app,
    /// the same bounded text is presented by the system's expanded Live Activity.
    private var livePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(recording ? "Recording" : "Transcribing", systemImage: recording ? "mic.fill" : "waveform")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(recording ? Color.red : Color.secondary)
                Spacer()
                Text(duration(controller.elapsed)).font(.caption.monospacedDigit())
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(controller.partialText.isEmpty ? (recording ? "Listening…" : "Finishing transcription…") : DictationTranscriptTail.make(from: controller.partialText))
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("preview-end")
                    }
                }
                .frame(maxHeight: 120)
                .onChange(of: controller.partialText) { _, _ in
                    proxy.scrollTo("preview-end", anchor: .bottom)
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live dictation preview")
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recording {
                HStack(spacing: 16) {
                    Text("Recording \(duration(controller.elapsed))").font(.footnote).monospacedDigit()
                    ProgressView(value: Double(controller.level))
                        .accessibilityLabel("Microphone level")
                        .accessibilityValue("\(Int(controller.level * 100)) percent")
                }
            }
            if controller.phase != .idle, let modelStatus = controller.modelStatus {
                modelLoadingStatus(modelStatus)
            } else if controller.phase == .preparing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing microphone…").font(.footnote).foregroundStyle(.secondary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { primaryAction; transcriptActions }
                VStack(alignment: .leading, spacing: 12) {
                    primaryAction
                    HStack(spacing: 20) { transcriptActions }
                }
            }
            if let expiry = controller.keyboardSessionExpiresAt {
                HStack {
                    Text(controller.phase == .idle ? "Keyboard idle timeout" : "Keyboard microphone enabled")
                        .font(.caption).foregroundStyle(.secondary)
                    if controller.phase == .idle {
                        Text(expiry, style: .timer).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("End") { Task { await controller.finishKeyboardSession() } }
                        .font(.caption).disabled(controller.isBusy)
                }
            }
            if recording {
                Button("Cancel recording", role: .destructive) { Task { await controller.cancelRecording() } }
                    .font(.footnote)
            }
            Text("Audio stays on this iPhone and is not saved.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(.bar).overlay(alignment: .top) { Divider() }
    }

    private func modelLoadingStatus(_ status: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(status).font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var primaryAction: some View {
        if controller.phase == .preparing {
            Button("Cancel") { Task { await controller.cancelPreparation() } }
                .buttonStyle(.bordered).controlSize(.large)
        } else if controller.phase == .transcribing {
            HStack(spacing: 10) {
                ProgressView()
                Text("Finishing…").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button {
                editing = false
                controller.saveTranscriptEdits()
                if !ready { openModels() }
                else { Task { if recording { await controller.stopRecording() } else { await controller.startRecording() } } }
            } label: {
                Label(recording ? "Stop" : ready ? "Record" : "Choose model", systemImage: recording ? "stop.fill" : ready ? "mic.fill" : "arrow.down.circle")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(controller.downloadingModel != nil)
            .accessibilityLabel(recording ? "Stop recording and finish transcription" : ready ? "Record" : "Choose model")
        }
    }

    @ViewBuilder private var transcriptActions: some View {
        Button {
            if !active { controller.saveTranscriptEdits() }
            UIPasteboard.general.string = textToCopy
            copied = true
            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
        } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
            .buttonStyle(.bordered).controlSize(.large).disabled(textToCopy.isEmpty)
        ShareLink(item: textToCopy) { Label("Share", systemImage: "square.and.arrow.up") }
            .buttonStyle(.bordered).controlSize(.large).disabled(textToCopy.isEmpty)
    }
}

private struct ModelsView: View {
    @ObservedObject var controller: AppController
    @State private var detailModel: SpeechModel?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if controller.downloadingModel != nil {
                        Text("Downloading model \(controller.downloadCompletedCount + 1) of \(controller.downloadTotalCount)")
                            .foregroundStyle(.secondary)
                        Button(controller.downloadCancelled ? "Cancelling…" : "Cancel download", role: .cancel) { controller.cancelDownload() }
                            .disabled(controller.downloadCancelled)
                    } else {
                        Button("Download all missing models") { Task { await controller.downloadAllMissingModels() } }
                            .disabled(controller.installedModels.count == SpeechModel.allCases.count || controller.phase != .idle || controller.keyboardSessionActive)
                        if controller.downloadCancelled { Text("Download cancelled. Installed models are kept.").foregroundStyle(.secondary) }
                        if let failed = controller.failedDownloadModel {
                            Button("Retry \(failed.name)") { Task { await controller.download(failed) } }
                                .disabled(controller.phase != .idle || controller.keyboardSessionActive)
                        }
                    }
                    if let error = controller.errorMessage { Text(error).foregroundStyle(.red) }
                    if let status = controller.modelStatus { Text(status).foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(SpeechModel.allCases) { model in
                        modelRow(model)
                    }
                } footer: {
                    Text("Models stay installed for offline use. Only the selected model is loaded for dictation. Downloads need internet.")
                }
            }.navigationTitle("Models")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(item: $detailModel) { model in ModelDetailsView(model: model) }
        }
    }

    private func modelRow(_ model: SpeechModel) -> some View {
        let installed = controller.installedModels.contains(model)
        let selected = controller.selectedModel == model
        let downloading = controller.downloadingModel == model
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.name)
                Text(model.downloadSize + " · " + (model.languages == "English" ? "English" : "25 languages"))
                    .font(.caption).foregroundStyle(.secondary)
                Text([installed ? "Installed" : "Not installed", selected ? "Selected" : nil, controller.preparedModel == model ? "Loaded" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if downloading {
                    if controller.downloadProgress > 0 {
                        ProgressView(value: controller.downloadProgress)
                            .accessibilityLabel("Downloading \(model.name)")
                        Text("\(Int(controller.downloadProgress * 100))%").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Preparing download…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if downloading {
                ProgressView().accessibilityLabel("Download in progress")
            } else if !selected || !installed {
                Button {
                    if installed { controller.selectedModel = model }
                    else { Task { await controller.download(model) } }
                } label: {
                    Text(installed ? "Use" : "Download").frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .disabled(controller.phase != .idle || controller.downloadingModel != nil || controller.keyboardSessionActive)
                .accessibilityLabel(installed ? "Use \(model.name)" : "Download \(model.name)")
            }
            Button { detailModel = model } label: { Image(systemName: "info.circle").frame(width: 44, height: 44) }
                .buttonStyle(.borderless).accessibilityLabel("Details for \(model.name)")
        }.padding(.vertical, 4)
    }
}

private struct ModelDetailsView: View {
    let model: SpeechModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Download size", value: model.downloadSize)
                    LabeledContent("Languages", value: model.languages)
                    Text(model.detail).foregroundStyle(.secondary)
                }
                if model.languages != "English" {
                    Section("Supported languages") {
                        Text("Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Swedish, Ukrainian.")
                    }
                }
                Section {
                    NavigationLink("Credits & licenses") { AboutView() }
                }
            }
            .navigationTitle(model.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var notes: NotesController
    let openModels: () -> Void
    @State private var requestedRetention: Int?
    @State private var retentionError: String?
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        NavigationStack {
            Form {
                Section { Button("Choose model", action: openModels) }
                Section {
                    Toggle("Keep transcript history", isOn: $controller.saveHistory)
                    Picker("Auto-delete history", selection: Binding(get: { controller.historyRetentionDays }, set: { days in
                        if days == 0 {
                            do { try controller.setHistoryRetention(days: 0) } catch { retentionError = error.localizedDescription }
                        } else { requestedRetention = days }
                    })) {
                        Text("Never").tag(0)
                        Text("Before today").tag(1)
                        Text("After 7 days").tag(7)
                        Text("After 30 days").tag(30)
                    }.disabled(!controller.canEditHistory)
                    NavigationLink("Usage") { HistoryUsageView(controller: controller) }
                } footer: {
                    Text("History is protected while locked and excluded from backups. Turning it off keeps existing entries.")
                }
                Section {
                    if let expiry = controller.keyboardSessionExpiresAt {
                        LabeledContent("Idle timeout") {
                            if controller.phase == .idle { Text(expiry, style: .timer).monospacedDigit() }
                            else { Text(controller.keyboardIdleMinutes == 1 ? "1 minute" : "\(controller.keyboardIdleMinutes) minutes") }
                        }
                    }
                    Picker("Idle timeout", selection: $controller.keyboardIdleMinutes) {
                        ForEach([1, 5, 15, 30], id: \.self) { value in Text(value == 1 ? "1 minute" : "\(value) minutes").tag(value) }
                    }.disabled(controller.keyboardSessionActive)
                    Button(controller.keyboardSessionActive ? "End session" : "Enable microphone") {
                        Task {
                            if controller.keyboardSessionActive { await controller.finishKeyboardSession() }
                            else { await controller.enableKeyboardSession() }
                        }
                    }.disabled(controller.isBusy || controller.downloadingModel != nil || (controller.phase == .recording && !controller.keyboardSessionActive))
                    NavigationLink("Setup instructions") { KeyboardSetupView() }
                } header: {
                    Text("Keyboard microphone")
                } footer: {
                    Text("The microphone stays on until you end the session or reach the selected idle timeout. Audio between dictations is discarded. Realtime recognizes speech in the background; GPU and Neural Engine models wait until LocalScribe is open.")
                }
                Section("Recording") {
                    Toggle("Use built-in microphone", isOn: $controller.preferBuiltInMicrophone)
                        .disabled(controller.phase != .idle || controller.keyboardSessionActive)
                    Toggle("Haptic feedback", isOn: $controller.hapticFeedback)
                        .disabled(controller.phase != .idle || controller.keyboardSessionActive)
                }
                Section {
                    NavigationLink("Action Button & shortcuts") { ActionButtonSetupView(controller: controller) }
                }
                Section {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                Section {
                    NavigationLink("Saved data") { SavedDataView(controller: controller, notes: notes) }
                    NavigationLink("Performance") { LivePerformanceView(controller: controller) }
                    NavigationLink("About & credits") { AboutView() }
                } footer: {
                    Text("Recognition runs on this iPhone. No account, analytics, or cloud transcription. Recordings are held in memory, then discarded.")
                }
            }.navigationTitle("Settings")
            .alert("Change history retention?", isPresented: Binding(get: { requestedRetention != nil }, set: { if !$0 { requestedRetention = nil } })) {
                Button("Cancel", role: .cancel) { requestedRetention = nil }
                Button("Apply", role: .destructive) {
                    if let days = requestedRetention {
                        do { try controller.setHistoryRetention(days: days) } catch { retentionError = error.localizedDescription }
                    }
                    requestedRetention = nil
                }
            } message: {
                Text("Deletes \(controller.historyRemovalCount(for: requestedRetention ?? 0)) older transcripts now and automatically removes older entries later. Dates use calendar days. This cannot be undone.")
            }
            .alert("History could not be changed", isPresented: Binding(get: { retentionError != nil }, set: { if !$0 { retentionError = nil } })) {
                Button("OK") { retentionError = nil }
            } message: { Text(retentionError ?? "") }
        }
    }
}

private struct ActionButtonSetupView: View {
    @ObservedObject var controller: AppController
    var body: some View {
        Form {
            Section {
                Picker("Background model", selection: $controller.selectedBackgroundModel) {
                    ForEach([SpeechModel.parakeetRealtimeEOU, .moonshineSmall], id: \.self) { model in
                        Text(model.name).tag(model)
                    }
                }.disabled(controller.phase != .idle || controller.keyboardSessionActive)
            } footer: {
                Text("These CPU runtimes can transcribe while another app is open. This choice is separate from the model on Dictate.")
            }
            Section {
                Text("1. Open iPhone Settings → Action Button → Shortcut → Choose a Shortcut.")
                Text("2. Choose LocalScribe → Dictate and Copy.")
                Text("3. Hold once to record, release and speak, then hold again to stop and copy. Paste in your current app.")
                ShortcutsLink().shortcutsLinkStyle(.automatic)
            } header: {
                Text("Action Button")
            } footer: {
                Text("Allow microphone access in LocalScribe once before using the shortcut. Releasing the button does not stop recording.")
            }
            Section {
                Text("The Dynamic Island shows a recording timer while the microphone is active.")
                Text("Touch and hold the Dynamic Island to see the live preview and Stop button. Transcript text is never shown on the Lock Screen.")
            } header: {
                Text("Live Activity")
            } footer: {
                Text("Action Button recording requires Live Activities. Enable them in iPhone Settings → Apps → LocalScribe. You can still record directly in Dictate when they are off.")
            }
            Section("Local transcription") {
                Text("GPU and Neural Engine models remain available on Dictate. Action Button recordings use the selected background model.")
                Text("There is no fixed recording duration. If recognition cannot keep up, recording stops and reports the problem instead of silently dropping audio.")
            }
        }.navigationTitle("Action Button").navigationBarTitleDisplayMode(.inline)
    }
}

private struct KeyboardSetupView: View {
    var body: some View {
        Form {
            Section("Setup") {
                Text("1. Open iPhone Settings → General → Keyboard → Keyboards → Add New Keyboard, then choose LocalScribe.")
                Text("2. Allow Full Access for communication with the LocalScribe app. The keyboard does not use a network transcription service.")
                Text("3. Open LocalScribe and enable the keyboard microphone in Settings. The session ends after the idle timeout you choose in Settings.")
                Text("4. Switch to another app and select the LocalScribe keyboard to record and insert text.")
            }
            Section("Microphone access") {
                Text("iOS keyboards cannot access the microphone directly. LocalScribe must remain running with an explicitly enabled session. The orange microphone indicator stays on until the session ends.")
            }
        }.navigationTitle("Keyboard setup").navigationBarTitleDisplayMode(.inline)
    }
}

private enum LibraryDestination: Hashable { case dictionary, snippets, notes }

private struct LibraryView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var notes: NotesController
    @Binding var path: [LibraryDestination]
    let openSavedData: () -> Void
    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink(value: LibraryDestination.dictionary) { Label("Dictionary", systemImage: "textformat.abc") }
                NavigationLink(value: LibraryDestination.snippets) { Label("Snippets", systemImage: "text.badge.plus") }
                NavigationLink(value: LibraryDestination.notes) { Label("Notes", systemImage: "note.text") }
            }.navigationTitle("Library")
            .navigationDestination(for: LibraryDestination.self) { destination in
                switch destination {
                case .dictionary: DictionaryView(controller: controller, openSavedData: openSavedData)
                case .snippets: SnippetsView(controller: controller, openSavedData: openSavedData)
                case .notes: NotesView(controller: notes, dictation: controller)
                }
            }
        }
    }
}

private func duration(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
