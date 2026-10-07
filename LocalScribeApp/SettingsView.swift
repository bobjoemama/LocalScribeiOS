import SwiftUI
import UIKit
import LocalScribeCore
import AppIntents

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var notes: NotesController
    let openModels: () -> Void
    @State private var requestedRetention: Int?
    @State private var retentionError: String?
    @State private var updatingKeyboardSession = false
    @State private var keyboardSessionError: String?
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Choose model", action: openModels)
                    Toggle("Keep model loaded", isOn: $controller.keepModelLoaded).tint(.green)
                        .disabled(controller.phase != .idle || controller.keyboardSessionActive)
                    Toggle("Use built-in microphone", isOn: $controller.preferBuiltInMicrophone).tint(.green)
                        .disabled(controller.phase != .idle || controller.keyboardSessionActive)
                    Toggle("Haptic feedback", isOn: $controller.hapticFeedback).tint(.green)
                        .disabled(controller.phase != .idle || controller.keyboardSessionActive)
                } header: {
                    Text("Dictation").foregroundStyle(AppTheme.inkSecondary)
                } footer: {
                    Text("Preloads your Dictate model and keeps the last-used model ready between dictations and when you switch apps. Force quit releases it; iOS may reclaim memory, and turning this off releases it after dictation.").foregroundStyle(AppTheme.inkSecondary)
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    Toggle("Keep transcript history", isOn: $controller.saveHistory).tint(.green)
                    Picker("Auto-delete history", selection: Binding(get: { controller.historyRetentionDays }, set: { days in
                        guard days != controller.historyRetentionDays else { return }
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
                } header: {
                    Text("History").foregroundStyle(AppTheme.inkSecondary)
                } footer: {
                    Text("History is protected while locked and excluded from backups. Turning it off keeps existing entries.").foregroundStyle(AppTheme.inkSecondary)
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    if let expiry = controller.keyboardSessionExpiresAt {
                        LabeledContent("Microphone session") {
                            if controller.phase == .idle {
                                HStack(spacing: 4) {
                                    Text("Ends in").foregroundStyle(AppTheme.inkSecondary)
                                    Text(expiry, style: .timer).monospacedDigit().foregroundStyle(AppTheme.inkSecondary)
                                }
                            } else { Text("Recording").foregroundStyle(AppTheme.inkSecondary) }
                        }
                    }
                    Picker("Idle timeout", selection: $controller.keyboardIdleMinutes) {
                        ForEach([1, 5, 15, 30], id: \.self) { value in
                            Text(value == 1 ? "1 minute" : "\(value) minutes").tag(value)
                        }
                    }.disabled(controller.keyboardSessionActive)
                    Button(updatingKeyboardSession ? "Updating session…" : controller.keyboardSessionActive ? "End session" : "Enable microphone") {
                        guard !updatingKeyboardSession else { return }
                        let endingSession = controller.keyboardSessionActive
                        updatingKeyboardSession = true
                        keyboardSessionError = nil
                        Task {
                            defer { updatingKeyboardSession = false }
                            if endingSession { await controller.finishKeyboardSession() }
                            else { await controller.enableKeyboardSession() }
                            keyboardSessionError = controller.errorMessage
                        }
                    }.disabled(updatingKeyboardSession || controller.isBusy || controller.downloadingModel != nil || (controller.phase == .recording && !controller.keyboardSessionActive))
                    if let error = keyboardSessionError {
                        Text(error).font(.footnote).foregroundStyle(AppTheme.error)
                    }
                    NavigationLink("Setup instructions") { KeyboardSetupView() }
                } header: {
                    Text("Keyboard").foregroundStyle(AppTheme.inkSecondary)
                } footer: {
                    Text("The microphone stays on until you end the session or reach the idle timeout. Audio between dictations is discarded. Realtime recognizes speech in the background; GPU and Neural Engine models wait until LocalScribe is open.").foregroundStyle(AppTheme.inkSecondary)
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    BackgroundModelPicker(controller: controller)
                    NavigationLink("Setup") { ActionButtonSetupView(controller: controller) }
                } header: {
                    Text("Action Button").foregroundStyle(AppTheme.inkSecondary)
                } footer: {
                    Text("Shortcut recordings use this CPU model and need Live Activities. iOS may decline background microphone activation; open LocalScribe and record from Dictate if this happens.").foregroundStyle(AppTheme.inkSecondary)
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Appearance")
                } header: { Text("Appearance").foregroundStyle(AppTheme.inkSecondary) }
                .listRowBackground(AppTheme.surface)

                Section {
                    NavigationLink("Performance") { LivePerformanceView(controller: controller) }
                    NavigationLink("Accuracy") { PerformanceView(controller: controller) }
                } header: { Text("Performance").foregroundStyle(AppTheme.inkSecondary) }
                .listRowBackground(AppTheme.surface)

                Section {
                    NavigationLink("Saved data") { SavedDataView(controller: controller, notes: notes) }
                    NavigationLink("About & credits") { AboutView() }
                } footer: {
                    Text("Recognition runs on this iPhone. No account, analytics or cloud transcription. Audio is held in memory, then discarded.").foregroundStyle(AppTheme.inkSecondary)
                }
                .listRowBackground(AppTheme.surface)
            }
            .scribeForm()
            .navigationTitle("Settings")
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

private struct BackgroundModelPicker: View {
    @ObservedObject var controller: AppController
    var body: some View {
        Picker("Background model", selection: $controller.selectedBackgroundModel) {
            ForEach([SpeechModel.parakeetRealtimeEOU, .moonshineSmall], id: \.self) { model in
                Text(model.name).tag(model)
            }
        }.disabled(controller.phase != .idle || controller.keyboardSessionActive)
    }
}

private struct ActionButtonSetupView: View {
    @ObservedObject var controller: AppController
    var body: some View {
        Form {
            Section {
                BackgroundModelPicker(controller: controller)
            } footer: {
                Text("These CPU runtimes can transcribe while another app is open. This choice is separate from the model on Dictate.").foregroundStyle(AppTheme.inkSecondary)
            }
            .listRowBackground(AppTheme.surface)
            Section {
                Text("1. Open iPhone Settings → Action Button → Shortcut → Choose a Shortcut.")
                Text("2. Choose LocalScribe → Dictate and Copy.")
                Text("3. Hold once to record, release and speak, then hold again to stop and copy. Paste in your current app.")
                ShortcutsLink().shortcutsLinkStyle(.automatic)
            } header: {
                Text("Action Button").foregroundStyle(AppTheme.inkSecondary)
            } footer: {
                Text("Allow microphone access in LocalScribe once before using the shortcut. Releasing the button does not stop recording. iOS may decline background microphone activation; open LocalScribe and record from Dictate if this happens.").foregroundStyle(AppTheme.inkSecondary)
            }
            .listRowBackground(AppTheme.surface)
            Section {
                Text("The Dynamic Island shows a recording timer while the microphone is active.")
                Text("Touch and hold the Dynamic Island to see the live preview and Stop button. Transcript text is never shown on the Lock Screen.")
            } header: {
                Text("Live Activity").foregroundStyle(AppTheme.inkSecondary)
            } footer: {
                Text("Action Button recording requires Live Activities. Enable them in iPhone Settings → Apps → LocalScribe. You can still record directly in Dictate when they are off.").foregroundStyle(AppTheme.inkSecondary)
            }
            .listRowBackground(AppTheme.surface)
            Section {
                Text("GPU and Neural Engine models remain available on Dictate. Action Button recordings use the selected background model.")
                Text("There is no fixed recording duration. If recognition cannot keep up, recording stops and reports the problem instead of silently dropping audio.")
            } header: { Text("Local transcription").foregroundStyle(AppTheme.inkSecondary) }
            .listRowBackground(AppTheme.surface)
        }
        .scribeForm()
        .navigationTitle("Action Button").navigationBarTitleDisplayMode(.inline)
    }
}

private struct KeyboardSetupView: View {
    var body: some View {
        Form {
            Section {
                Text("1. Open iPhone Settings → General → Keyboard → Keyboards → Add New Keyboard, then choose LocalScribe.")
                Text("2. Allow Full Access for communication with the LocalScribe app. The keyboard does not use a network transcription service.")
                Text("3. Open LocalScribe and enable the keyboard microphone in Settings. The session ends after the idle timeout you choose in Settings.")
                Text("4. Switch to another app and select the LocalScribe keyboard to record and insert text.")
            } header: { Text("Setup").foregroundStyle(AppTheme.inkSecondary) }
            .listRowBackground(AppTheme.surface)
            Section {
                Text("iOS keyboards cannot access the microphone directly. LocalScribe must remain running with an explicitly enabled session. The orange microphone indicator stays on until the session ends.")
            } header: { Text("Microphone access").foregroundStyle(AppTheme.inkSecondary) }
            .listRowBackground(AppTheme.surface)
        }
        .scribeForm()
        .navigationTitle("Keyboard setup").navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor
func designPreviewActionButtonSetup(controller: AppController) -> some View {
    ActionButtonSetupView(controller: controller)
}

@MainActor
func designPreviewKeyboardSetup() -> some View { KeyboardSetupView() }
#endif
