import SwiftUI
import UIKit
import AVFAudio
import LocalScribeCore

struct DictateView: View {
    @ObservedObject var controller: AppController
    let openModels: () -> Void
    let saveNote: (String) -> Void
    @State private var copied = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var showingPerformance = false
    @State private var microphoneDenied = false
    @State private var recoverableError: String?
    @State private var levels: [Float] = []
    @FocusState private var editing: Bool
    @Environment(\.scenePhase) private var scenePhase
    private var ready: Bool { controller.installedModels.contains(controller.selectedModel) }
    private var recording: Bool { controller.phase == .recording }
    private var active: Bool { controller.phase != .idle }
    private var displayedModel: SpeechModel { controller.recordingModel ?? controller.selectedModel }
    private var textToCopy: String { recording || controller.phase == .transcribing ? controller.partialText : controller.transcript }
    private var canSelectModel: Bool {
        controller.phase == .idle && controller.recordingModel == nil && controller.downloadingModel == nil && !controller.keyboardSessionActive
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modelMenu.padding(.horizontal, 20).padding(.vertical, 12)
                if microphoneDenied { microphoneBanner }
                else if let recoverableError { errorBanner(recoverableError) }
                transcriptWorkspace
                LivePerformanceStrip(open: { showingPerformance = true })
                    .padding(.horizontal, 20).padding(.vertical, 8)
            }
            .background(AppTheme.canvas).foregroundStyle(AppTheme.ink)
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
                        Button { editing = false; controller.saveTranscriptEdits(); saveNote(controller.transcript) } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel("Save as note")
                    }
                }
                if editing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { editing = false; controller.saveTranscriptEdits() }
                    }
                }
            }
            .onAppear { refreshMicrophonePermission() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refreshMicrophonePermission() } }
            .onChange(of: editing) { _, focused in if !focused, controller.phase == .idle { controller.saveTranscriptEdits() } }
            .onChange(of: controller.transcript) { _, _ in clearCopyFeedback() }
            .onChange(of: controller.partialText) { _, _ in clearCopyFeedback() }
            .onChange(of: controller.phase) { _, phase in
                refreshMicrophonePermission()
                if phase != .idle { editing = false }
                if phase == .recording { levels = []; recoverableError = nil }
                else if phase == .idle { levels = [] }
            }
            .onChange(of: controller.errorMessage) { _, error in
                if let error { recoverableError = error; refreshMicrophonePermission() }
            }
            .onChange(of: controller.level) { _, level in
                guard recording else { return }
                levels.append(min(1, max(0, level)))
                if levels.count > 24 { levels.removeFirst(levels.count - 24) }
            }
            .onDisappear { clearCopyFeedback() }
        }
    }

    private var modelMenu: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { modelChip; modelCaption }
            VStack(alignment: .leading, spacing: 8) { modelChip; modelCaption }
        }
    }

    private var modelChip: some View {
        Menu {
            Picker("Model", selection: $controller.selectedModel) {
                ForEach(SpeechModel.allCases) { model in
                    Text(controller.installedModels.contains(model) ? model.name : model.name + " · not downloaded")
                        .tag(model).disabled(!controller.installedModels.contains(model))
                }
            }.pickerStyle(.inline)
            Divider()
            Button("Manage models", action: openModels)
        } label: {
            HStack(spacing: 10) {
                Text(displayedModel.name).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.caption.weight(.medium))
            }
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(AppTheme.surfaceInset, in: Capsule())
            .overlay { Capsule().stroke(AppTheme.controlBorder, lineWidth: 1) }
            .foregroundStyle(AppTheme.ink)
        }
        .disabled(!canSelectModel)
        .accessibilityLabel("Choose model")
        .accessibilityValue(displayedModel.name + ", " + modelModeState)
    }

    private var modelCaption: some View {
        Text(modelModeState).font(.footnote).foregroundStyle(AppTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
    }

    private var modelModeState: String {
        let mode = SpeechModelPresentation.mode(displayedModel)
        if displayedModel == controller.selectedModel {
            return mode + " · Action Button " + SpeechModelPresentation.actionButtonState(controller)
        }
        return mode + (controller.preparedModel == displayedModel ? " · loaded" : "")
    }

    @ViewBuilder private var transcriptWorkspace: some View {
        if active {
            LiveDictationTranscript(text: controller.phase == .preparing ? "" : controller.partialText,
                emptyMessage: controller.phase == .preparing ? "Preparing microphone…" : recording ? "Listening…" : "Finishing transcription…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !controller.transcript.isEmpty {
            TextEditor(text: $controller.transcript).font(.body).lineSpacing(4).focused($editing)
                .scrollContentBackground(.hidden).padding(.horizontal, 16).padding(.top, 12)
                .scrollDismissesKeyboard(.interactively)
                .accessibilityLabel("Editable transcript")
        } else {
            ScrollView {
                Text(ready ? "Tap Record to begin." : "Choose a downloaded model to begin.")
                    .font(.body).foregroundStyle(AppTheme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var microphoneBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Microphone access is off", systemImage: "mic.slash").font(.subheadline.weight(.medium))
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }.frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .foregroundStyle(AppTheme.error).background(AppTheme.errorSoft, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle").font(.subheadline)
                Spacer(minLength: 0)
                Button { recoverableError = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Dismiss error")
            }
            if !textToCopy.isEmpty { Text("Captured text remains available.").font(.footnote) }
        }
        .padding(12).foregroundStyle(AppTheme.error)
        .background(AppTheme.errorSoft, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recording {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { recordingTime; waveform }
                    VStack(alignment: .leading, spacing: 8) { recordingTime; waveform }
                }
            }
            if let status = controller.modelStatus { modelLoadingStatus(status) }
            else if controller.phase == .preparing { modelLoadingStatus("Preparing microphone…") }
            primaryAction
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { transcriptActions; Spacer(minLength: 0); discardAction }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) { transcriptActions }
                    discardAction
                }
            }
            if let expiry = controller.keyboardSessionExpiresAt {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { keyboardSessionStatus(expiry); Spacer(minLength: 0); endKeyboardSession }
                    VStack(alignment: .leading, spacing: 8) { keyboardSessionStatus(expiry); endKeyboardSession }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar).overlay(alignment: .top) { Rectangle().fill(AppTheme.separator).frame(height: 1) }
    }

    @ViewBuilder private var discardAction: some View {
        if recording || controller.phase == .transcribing {
            Button(controller.phase == .transcribing ? "Discard" : "Cancel recording", role: .destructive) {
                Task { await controller.cancelRecording() }
            }.font(.footnote).frame(minHeight: 44)
        }
    }

    private var recordingTime: some View {
        HStack(spacing: 6) {
            Circle().fill(AppTheme.recording).frame(width: 6, height: 6).accessibilityHidden(true)
            Text("Recording \(duration(controller.elapsed))").font(.footnote).monospacedDigit()
        }
    }

    private var waveform: some View {
        DictationWaveform(levels: levels, currentLevel: controller.level).frame(minWidth: 80, maxWidth: .infinity).frame(height: 24)
    }

    private func keyboardSessionStatus(_ expiry: Date) -> some View {
        HStack(spacing: 4) {
            Text(keyboardMicrophoneStatus)
            if controller.phase == .idle { Text(expiry, style: .timer).monospacedDigit() }
        }.font(.footnote).foregroundStyle(AppTheme.inkSecondary)
    }

    private var keyboardMicrophoneStatus: String {
        switch controller.phase {
        case .idle: "Keyboard microphone on · ends in"
        case .preparing: "Keyboard microphone on · starting"
        case .recording: "Keyboard microphone on · recording"
        case .transcribing: "Keyboard microphone on · transcribing"
        }
    }

    private var endKeyboardSession: some View {
        Button("End") { Task { await controller.finishKeyboardSession() } }
            .font(.footnote).buttonStyle(.bordered).disabled(controller.isBusy).frame(minHeight: 44)
    }

    private func modelLoadingStatus(_ status: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(status).font(.footnote).foregroundStyle(AppTheme.inkSecondary)
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private var primaryAction: some View {
        if controller.phase == .transcribing {
            Button {} label: {
                HStack(spacing: 10) { ProgressView(); Text("Finishing…") }.frame(maxWidth: .infinity).padding(.vertical, 4)
            }.buttonStyle(.borderedProminent).tint(AppTheme.accent).controlSize(.large).disabled(true)
        } else {
            let stopping = recording || controller.phase == .preparing
            let starting = controller.phase == .idle && controller.recordingModel != nil
            Button {
                editing = false
                if controller.phase == .idle { controller.saveTranscriptEdits() }
                recoverableError = nil
                if controller.phase == .preparing { Task { await controller.cancelPreparation() } }
                else if recording { Task { await controller.stopRecording() } }
                else if !ready { openModels() }
                else { Task { await controller.startRecording() } }
            } label: {
                Label(stopping ? "Stop" : starting ? "Starting…" : ready ? "Record" : "Choose model", systemImage: stopping ? "stop.fill" : starting ? "hourglass" : ready ? "mic.fill" : "arrow.down.circle")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                    .foregroundStyle(stopping ? AppTheme.onRecording : AppTheme.onAccent)
            }
            .buttonStyle(.borderedProminent).tint(stopping ? AppTheme.recording : AppTheme.accent).controlSize(.large)
            .disabled(!stopping && (controller.downloadingModel != nil || starting))
            .accessibilityLabel(stopping ? "Stop recording" : starting ? "Starting recording" : ready ? "Record" : "Choose model")
        }
    }

    @ViewBuilder private var transcriptActions: some View {
        Button {
            if !active { controller.saveTranscriptEdits() }
            UIPasteboard.general.string = textToCopy
            copyFeedbackTask?.cancel()
            copied = true
            copyFeedbackTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(2)); copied = false }
                catch { }
            }
        } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
            .buttonStyle(.bordered).controlSize(.regular).frame(minHeight: 44).disabled(textToCopy.isEmpty)
        ShareLink(item: textToCopy) { Label("Share", systemImage: "square.and.arrow.up") }
            .buttonStyle(.bordered).controlSize(.regular).frame(minHeight: 44).disabled(textToCopy.isEmpty)
    }

    private func clearCopyFeedback() { copyFeedbackTask?.cancel(); copied = false }
    private func refreshMicrophonePermission() { microphoneDenied = AVAudioApplication.shared.recordPermission == .denied }
}

/// Keep a single replacing transcript. Following stops on a real user scroll;
/// new recognizer snapshots never pull someone away from earlier speech.
private struct LiveDictationTranscript: View {
    let text: String
    let emptyMessage: String
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var followingLatest = true
    @State private var atBottom = true

    var body: some View {
        ScrollView {
            Group {
                if text.isEmpty { Text(emptyMessage).foregroundStyle(AppTheme.inkSecondary) }
                else { Text(emphasizedText).textSelection(.enabled) }
            }
            .font(.body).lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .accessibilityLabel("Live transcript").accessibilityValue(text.isEmpty ? emptyMessage : text)
            .accessibilityAddTraits(.updatesFrequently)
        }
        .scrollPosition($scrollPosition).defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // Round to display pixels rather than inventing a scroll-distance limit.
            ceil(geometry.visibleRect.maxY) >= floor(geometry.contentSize.height)
        } action: { _, bottom in
            atBottom = bottom
            if scrollPosition.isPositionedByUser { followingLatest = bottom }
        }
        .onChange(of: scrollPosition.isPositionedByUser) { _, userPosition in
            if userPosition { followingLatest = atBottom }
        }
        .onChange(of: text) { _, _ in if followingLatest { scrollPosition.scrollTo(edge: .bottom) } }
        .overlay(alignment: .bottomTrailing) {
            if !followingLatest {
                Button { followingLatest = true; scrollPosition.scrollTo(edge: .bottom) } label: {
                    Label("Latest", systemImage: "arrow.down").font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .background(AppTheme.surfaceRaised, in: Capsule())
                        .overlay { Capsule().stroke(AppTheme.controlBorder, lineWidth: 1) }
                }.buttonStyle(.plain).padding(16).accessibilityHint("Returns to the newest recognized text")
            }
        }
    }

    private var emphasizedText: AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = AppTheme.ink
        if let boundary = LiveTranscriptEmphasis.latestBoundary(in: text),
           let attributedBoundary = AttributedString.Index(boundary, within: result) {
            result[..<attributedBoundary].foregroundColor = AppTheme.inkSecondary
        }
        return result
    }
}

/// The shared tail may normalize whitespace; map its tokens back into the
/// original snapshot so line breaks and the recognizer's exact text survive.
enum LiveTranscriptEmphasis {
    static func latestBoundary(in text: String) -> String.Index? {
        let tail = DictationTranscriptTail.make(from: text)
        guard !tail.isEmpty else { return nil }
        if let range = text.range(of: tail, options: .backwards),
           text[range.upperBound...].allSatisfy(\.isWhitespace) { return range.lowerBound }
        let sourceWords = text.split(whereSeparator: \.isWhitespace)
        let tailWords = tail.split(whereSeparator: \.isWhitespace)
        guard sourceWords.count >= tailWords.count, let first = sourceWords.suffix(tailWords.count).first else { return nil }
        let suffix = Array(sourceWords.suffix(tailWords.count))
        guard zip(suffix.dropFirst(), tailWords.dropFirst()).allSatisfy({ $0.0 == $0.1 }),
              let firstTail = tailWords.first, first.hasSuffix(firstTail) else { return nil }
        return text.index(first.endIndex, offsetBy: -firstTail.count)
    }
}

private struct DictationWaveform: View {
    let levels: [Float]
    let currentLevel: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                ProgressView(value: Double(min(1, max(0, currentLevel)))).tint(AppTheme.recording)
            } else {
                Canvas { context, size in
                    let samples = Array(repeating: Float(0), count: max(0, 24 - levels.count)) + Array(levels.suffix(24))
                    let step = size.width / 24
                    let width = max(1, step * 0.5)
                    for (index, sample) in samples.enumerated() {
                        let height = max(2, CGFloat(sample) * size.height)
                        let rect = CGRect(x: CGFloat(index) * step + (step - width) / 2,
                            y: (size.height - height) / 2, width: width, height: height)
                        context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(AppTheme.recording))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(min(1, max(0, currentLevel)) * 100)) percent")
    }
}

private func duration(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
