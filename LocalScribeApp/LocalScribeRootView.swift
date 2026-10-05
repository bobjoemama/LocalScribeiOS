import SwiftUI
import AppIntents
import UIKit
import LocalScribeCore

struct LocalScribeRootView: View {
    @ObservedObject var controller: AppController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    @State private var tab = 0

    init(controller: AppController) {
        _controller = ObservedObject(wrappedValue: controller)
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let names = ["dictate", "history", "models", "settings"]
        if let index = arguments.firstIndex(of: "--preview-tab"), index + 1 < arguments.count {
            _tab = State(initialValue: names.firstIndex(of: arguments[index + 1]) ?? 0)
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
            DictateView(controller: controller, openModels: { tab = 2 })
                .tabItem { Label("Dictate", systemImage: "mic") }.tag(0)
            HistoryView(controller: controller)
                .tabItem { Label("History", systemImage: "clock") }.tag(1)
            ModelsView(controller: controller)
                .tabItem { Label("Models", systemImage: "cpu") }.tag(2)
            SettingsView(controller: controller)
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
        }
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
            if phase == .active { controller.setForeground(true) }
            if phase == .background { controller.setForeground(false) }
        }
        .onAppear { if controller.actionButtonRecording { tab = 0 } }
        .onChange(of: controller.actionButtonRecording) { _, recording in
            if recording { tab = 0 }
        }
        .onOpenURL { url in
            if url.scheme == "localscribe", url.host == "dictation" { tab = 0 }
        }
    }
}

private struct DictateView: View {
    @ObservedObject var controller: AppController
    let openModels: () -> Void
    @State private var copied = false
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
                Divider()
                transcriptWorkspace
            }
            .background(Color(uiColor: .systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { recordingControls }
            .navigationTitle("Dictate").navigationBarTitleDisplayMode(.inline)
            .toolbar {
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

private struct HistoryView: View {
    @ObservedObject var controller: AppController
    @State private var search = ""
    @State private var selected: TranscriptEntry?
    private var entries: [TranscriptEntry] {
        controller.history.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    Button { selected = entry } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.text).foregroundStyle(.primary).lineLimit(3)
                            Text(entry.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            Text(duration(entry.duration)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                if !entries.isEmpty {
                    Section {
                        Text("Stored on this iPhone and excluded from device backups.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No transcripts" : "No results", systemImage: search.isEmpty ? "clock" : "magnifyingglass", description: Text(search.isEmpty ? "Finished dictations appear here when history is enabled." : "Try another word or phrase."))
                }
            }
            .searchable(text: $search, prompt: "Search transcripts")
            .navigationTitle("History")
            .sheet(item: $selected) { entry in
                HistoryEditor(entry: entry) { text in controller.updateHistory(id: entry.id, text: text) }
            }
        }
    }
}

private struct HistoryEditor: View {
    let entry: TranscriptEntry
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var copied = false
    init(entry: TranscriptEntry, save: @escaping (String) -> Void) {
        self.entry = entry; self.save = save; _draft = State(initialValue: entry.text)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft).font(.body).frame(minHeight: 260)
                        .accessibilityLabel("Edit saved transcript")
                    Button { UIPasteboard.general.string = draft; copied = true } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    ShareLink(item: draft) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                Section {
                    LabeledContent("Recorded") {
                        Text(entry.createdAt, format: .dateTime.month().day().year().hour().minute())
                    }
                    LabeledContent("Duration", value: duration(entry.duration))
                    LabeledContent("Model", value: entry.model.name)
                }
            }
            .navigationTitle("Transcript").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(draft); dismiss() } }
            }
            .onChange(of: draft) { _, _ in copied = false }
        }
    }
}

private struct ModelsView: View {
    @ObservedObject var controller: AppController
    @State private var detailModel: SpeechModel?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(SpeechModel.allCases) { model in
                        modelRow(model)
                    }
                } footer: {
                    Text("Download once to transcribe offline. Model downloads need internet.")
                }
            }.navigationTitle("Models")
                .sheet(item: $detailModel) { model in ModelDetailsView(model: model) }
        }
    }

    private func modelRow(_ model: SpeechModel) -> some View {
        let installed = controller.installedModels.contains(model)
        let selected = controller.selectedModel == model && installed
        let downloading = controller.downloadingModel == model
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.name)
                Text(model.downloadSize + " · " + (model.languages == "English" ? "English" : "25 languages"))
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
            } else if selected {
                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Selected")
            } else {
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
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Keep transcript history", isOn: $controller.saveHistory)
                    NavigationLink("Dictionary") { DictionaryView(controller: controller) }
                } footer: {
                    Text("History is protected while locked and excluded from backups. Turning it off keeps existing entries.")
                }
                Section {
                    if let expiry = controller.keyboardSessionExpiresAt {
                        LabeledContent("Idle timeout") {
                            if controller.phase == .idle { Text(expiry, style: .timer).monospacedDigit() }
                            else { Text("5 minutes") }
                        }
                    }
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
                    Text("The microphone stays on until you end the session or stop dictating for 5 minutes. Audio between dictations is discarded. Realtime recognizes speech in the background; Neural Engine models wait until LocalScribe is open.")
                }
                Section {
                    NavigationLink("Action Button & shortcuts") { ActionButtonSetupView() }
                }
                Section {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                Section {
                    NavigationLink("Performance & accuracy") { PerformanceView(controller: controller) }
                    NavigationLink("About & credits") { AboutView() }
                } footer: {
                    Text("Recognition runs on this iPhone. No account, analytics, or cloud transcription. Recordings are held in memory, then discarded.")
                }
            }.navigationTitle("Settings")
        }
    }
}

private struct ActionButtonSetupView: View {
    var body: some View {
        Form {
            Section {
                Text("1. Open iPhone Settings → Action Button → Shortcut → Choose a Shortcut.")
                Text("2. Choose LocalScribe → Dictate and Copy.")
                Text("3. Hold once to open LocalScribe and record. Release and speak, then hold again to stop and copy.")
                ShortcutsLink().shortcutsLinkStyle(.automatic)
            } header: {
                Text("Action Button")
            } footer: {
                Text("Releasing the button does not stop recording. LocalScribe opens when you start or stop; paste the finished text in any app.")
            }
            Section {
                Text("The Dynamic Island shows a recording timer while the microphone is active.")
                Text("Touch and hold the Dynamic Island to see the live preview and Stop button. Stopping opens LocalScribe to finish and copy. Transcript text is never shown on the Lock Screen.")
            } header: {
                Text("Live Activity")
            } footer: {
                Text("Action Button recording requires Live Activities. Enable them in iPhone Settings → Apps → LocalScribe. You can still record directly in Dictate when they are off.")
            }
            Section("Local transcription") {
                Text("Realtime runs on the CPU and continues recognition during background recording while iOS permits audio capture. Models that use the Neural Engine pause recognition until you return to LocalScribe.")
                Text("There is no fixed recording limit. If recognition cannot keep up and the audio queue fills, recording stops and reports the missing audio. Open LocalScribe to finish and copy.")
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
                Text("3. Open LocalScribe and enable the keyboard microphone in Settings. The session ends after 5 minutes without dictation.")
                Text("4. Switch to another app and select the LocalScribe keyboard to record and insert text.")
            }
            Section("Microphone access") {
                Text("iOS keyboards cannot access the microphone directly. LocalScribe must remain running with an explicitly enabled session. The orange microphone indicator stays on until the session ends.")
            }
        }.navigationTitle("Keyboard setup").navigationBarTitleDisplayMode(.inline)
    }
}

private struct DictionaryView: View {
    @ObservedObject var controller: AppController
    @State private var heard = ""
    @State private var replacement = ""
    @State private var editingID: UUID?
    var body: some View {
        Form {
            Section {
                TextField("Recognized phrase", text: $heard).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Replacement", text: $replacement).autocorrectionDisabled()
                Button(editingID == nil ? "Add" : "Save") {
                    let phrase = heard.trimmingCharacters(in: .whitespacesAndNewlines)
                    let text = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let id = editingID, let index = controller.dictionary.firstIndex(where: { $0.id == id }) {
                        controller.dictionary[index] = DictionaryRule(id: id, heard: phrase, replacement: text)
                    } else if let index = controller.dictionary.firstIndex(where: { $0.heard.compare(phrase, options: .caseInsensitive) == .orderedSame }) {
                        controller.dictionary[index].replacement = text
                    } else { controller.dictionary.append(DictionaryRule(heard: phrase, replacement: text)) }
                    heard = ""; replacement = ""; editingID = nil
                }.disabled(heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if editingID != nil { Button("Cancel edit") { heard = ""; replacement = ""; editingID = nil } }
            } header: {
                Text(editingID == nil ? "Add correction" : "Edit correction")
            } footer: {
                Text("Replaces matching whole phrases after transcription. Capitalization is ignored.")
            }
            if !controller.dictionary.isEmpty {
                Section("Saved corrections") {
                    ForEach(controller.dictionary) { rule in
                        Button { heard = rule.heard; replacement = rule.replacement; editingID = rule.id } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.heard).foregroundStyle(.primary)
                                Text(rule.replacement).foregroundStyle(.secondary)
                            }
                        }.accessibilityLabel("Edit correction: \(rule.heard), replaced with \(rule.replacement)")
                    }
                }
            }
        }.navigationTitle("Dictionary").navigationBarTitleDisplayMode(.inline)
    }
}

private func duration(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
