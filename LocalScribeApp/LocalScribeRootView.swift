import SwiftUI
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
    }
}

private struct DictateView: View {
    @ObservedObject var controller: AppController
    let openModels: () -> Void
    @State private var copied = false
    @FocusState private var editing: Bool
    private var ready: Bool { controller.installedModels.contains(controller.selectedModel) }
    private var recording: Bool { controller.phase == .recording }
    private var status: String {
        switch controller.phase {
        case .idle: ready ? "Ready" : "No model installed"
        case .preparing: "Preparing…"
        case .recording: "Recording"
        case .transcribing: "Transcribing…"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Status", value: status)
                    LabeledContent("Model", value: controller.selectedModel.name)
                    if recording {
                        LabeledContent("Duration", value: duration(controller.elapsed))
                        ProgressView(value: Double(controller.level))
                            .accessibilityLabel("Microphone level")
                            .accessibilityValue("\(Int(controller.level * 100)) percent")
                    }
                    if controller.isBusy {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(status).foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            editing = false
                            controller.saveTranscriptEdits()
                            if !ready { openModels() }
                            else { Task { if recording { await controller.stopRecording() } else { await controller.startRecording() } } }
                        } label: {
                            Label(recording ? "Stop" : ready ? "Record" : "Choose model", systemImage: recording ? "stop.fill" : ready ? "mic.fill" : "arrow.down.circle")
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(controller.downloadingModel != nil)
                        .accessibilityLabel(recording ? "Stop recording and transcribe" : ready ? "Record" : "Choose model")
                    }
                } footer: {
                    Text("Transcription starts after you stop. Record up to 2 minutes. Audio stays on this iPhone and is not saved.")
                }
                if !controller.transcript.isEmpty {
                    Section("Transcript") {
                        TextEditor(text: $controller.transcript)
                            .font(.body).frame(minHeight: 220).focused($editing)
                            .accessibilityLabel("Editable transcript")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 24) { transcriptActions }
                            VStack(alignment: .leading, spacing: 16) { transcriptActions }
                        }.buttonStyle(.borderless)
                    }
                }
                if let expiry = controller.keyboardSessionExpiresAt {
                    Section("Keyboard microphone") {
                        LabeledContent("Time remaining") { Text(expiry, style: .timer).monospacedDigit() }
                        Button("End session") { Task { await controller.finishKeyboardSession() } }
                            .disabled(controller.isBusy)
                    }
                }
            }
            .navigationTitle("Dictate")
            .toolbar {
                if editing { ToolbarItem(placement: .keyboard) { Button("Done") { editing = false; controller.saveTranscriptEdits() } } }
            }
            .onChange(of: editing) { _, focused in if !focused { controller.saveTranscriptEdits() } }
        }
    }

    @ViewBuilder private var transcriptActions: some View {
        Button {
            controller.saveTranscriptEdits()
            UIPasteboard.general.string = controller.transcript
            copied = true
            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
        } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
        ShareLink(item: controller.transcript) { Label("Share", systemImage: "square.and.arrow.up") }
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
                        LabeledContent("Time remaining") { Text(expiry, style: .timer).monospacedDigit() }
                    }
                    Button(controller.keyboardSessionActive ? "End session" : "Enable for 5 minutes") {
                        Task {
                            if controller.keyboardSessionActive { await controller.finishKeyboardSession() }
                            else { await controller.enableKeyboardSession() }
                        }
                    }.disabled(controller.isBusy || controller.downloadingModel != nil || (controller.phase == .recording && !controller.keyboardSessionActive))
                    NavigationLink("Setup instructions") { KeyboardSetupView() }
                } header: {
                    Text("Keyboard microphone")
                } footer: {
                    Text("The microphone stays on during the session. Audio between dictations is discarded. At expiry, recording stops and captured speech finishes processing.")
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

private struct KeyboardSetupView: View {
    var body: some View {
        Form {
            Section("Setup") {
                Text("1. Open iPhone Settings → General → Keyboard → Keyboards → Add New Keyboard, then choose LocalScribe.")
                Text("2. Allow Full Access for communication with the LocalScribe app. The keyboard does not use a network transcription service.")
                Text("3. Open LocalScribe and enable a 5-minute microphone session in Settings.")
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
