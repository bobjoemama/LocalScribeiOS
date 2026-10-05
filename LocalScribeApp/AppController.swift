import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif
import LocalScribeCore

@MainActor
final class AppController: ObservableObject {
    @Published private(set) var performanceReports: [EnginePerformanceReport] = []
    @Published private(set) var phase: DictationPhase = .idle
    @Published var transcript = ""
    @Published private(set) var rawTranscript = ""
    @Published private(set) var partialText = ""
    @Published private(set) var modelStatus: String?
    @Published private(set) var history: [TranscriptEntry] = []
    @Published var errorMessage: String?
    @Published private(set) var installedModels: Set<SpeechModel> = []
    @Published private(set) var downloadingModel: SpeechModel?
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var keyboardSessionExpiresAt: Date?
    @Published private(set) var actionButtonRecording = false
    @Published var selectedModel: SpeechModel {
        didSet {
            defaults.set(selectedModel.rawValue, forKey: "selectedModel")
            guard oldValue != selectedModel, phase == .idle, !keyboardSessionActive else { return }
            releaseRuntime()
            prewarmSelectedModel()
        }
    }
    @Published var saveHistory: Bool {
        didSet { defaults.set(saveHistory, forKey: "saveHistory") }
    }
    @Published var dictionary: [DictionaryRule] {
        didSet {
            guard dictionaryWritable else {
                errorMessage = "Your existing dictionary could not be opened. It is preserved; new corrections cannot be saved until the storage issue is resolved."
                return
            }
            do { try dictionaryStore.save(dictionary) }
            catch { errorMessage = "Could not save your dictionary: \(error.localizedDescription)" }
        }
    }

    var onDictationFinished: (() -> Void)?
    private var backgroundCompletionTask: UIBackgroundTaskIdentifier = .invalid
    private let engine: any LocalTranscriptionEngine
    private let recorder = AudioRecorder()
    private let store: HistoryStore
    private let dictionaryStore: DictionaryStore
    private let defaults: UserDefaults
    private let verificationMode: Bool
    private var recordingStartedAt: Date?
    private var captureModel: SpeechModel?
    private var captureBackgroundInferenceAllowed = false
    private var currentEntryID: UUID?
    private var recordingTimer: Timer?
    private var sessionTimer: Timer?
    private var preparationTask: Task<Void, Error>?
    private var preparationModel: SpeechModel?
    private var preparationRevision = 0
    private var preparedModel: SpeechModel?
    private var streamingTask: Task<Void, Error>?
    private var recordingID: UUID?
    private var capturedSampleCount: Int64 = 0
    private var captureWarning: String?
    private var acceptsLiveUpdates = false
    private var runtimeReleaseTask: Task<Void, Never>?
    private var memoryObserver: NSObjectProtocol?
    private var foreground = true
    private var microphoneRevision = 0
    private var historyWritable = true
    private var dictionaryWritable = true
    var keyboardSessionActive: Bool { keyboardSessionExpiresAt.map { $0 > Date() } ?? false }
    var isBusy: Bool { phase == .preparing || phase == .transcribing }

    #if DEBUG
    var verificationCaptureSnapshot: CaptureBufferSnapshot { recorder.captureSnapshot }
    #endif

    init(engine: any LocalTranscriptionEngine, defaults: UserDefaults = .standard, historyURL: URL? = nil, verificationMode: Bool = false) {
        self.engine = engine
        self.defaults = defaults
        self.verificationMode = verificationMode
        selectedModel = SpeechModel(rawValue: defaults.string(forKey: "selectedModel") ?? "") ?? .parakeetRealtimeEOU
        saveHistory = defaults.object(forKey: "saveHistory") as? Bool ?? true
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalScribe", isDirectory: true)
        store = HistoryStore(file: historyURL ?? directory.appendingPathComponent("history.json"))
        dictionaryStore = DictionaryStore(file: (historyURL?.deletingLastPathComponent() ?? directory).appendingPathComponent("dictionary.json"))
        dictionary = []
        do { dictionary = try dictionaryStore.load() }
        catch { dictionaryWritable = false; errorMessage = "Your dictionary could not be opened. It has been preserved: \(error.localizedDescription)" }
        do { history = try store.load() }
        catch { historyWritable = false; errorMessage = "Your history could not be opened. It has been preserved: \(error.localizedDescription)" }
        recorder.onLevel = { [weak self] level in
            guard self?.phase == .recording else { return }
            self?.level = level
        }
        recorder.onOverflow = { [weak self] droppedSamples in
            guard let self, self.phase == .recording else { return }
            self.captureWarning = "Recognition could not keep up with the microphone. Recording stopped; \(String(format: "%.2f", Double(droppedSamples) / 16_000)) seconds of new audio could not be buffered. Captured text is preserved."
            Task { await self.stopRecording(endKeyboardSession: true) }
        }
        recorder.onCaptureFailure = { [weak self] failure in
            guard let self, self.phase == .recording else { return }
            self.captureWarning = failure.localizedDescription
            Task { await self.stopRecording(endKeyboardSession: true) }
        }
        recorder.onInterruption = { [weak self] in
            guard let self else { return }
            if self.phase == .recording {
                self.captureWarning = "The microphone was interrupted. Recording stopped and captured speech is being finished."
                Task { await self.stopRecording(endKeyboardSession: true) }
            } else { self.disableKeyboardSession() }
        }
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.phase == .recording {
                    self.captureWarning = "iPhone requested more memory. Recording stopped; captured text is preserved."
                    await self.stopRecording(endKeyboardSession: true)
                }
                if self.phase == .idle {
                    self.disableKeyboardSession()
                    self.releaseRuntime()
                }
            }
        }
        Task { await refreshInstalledModels() }
    }

    func refreshInstalledModels() async {
        var installed: Set<SpeechModel> = []
        for model in SpeechModel.allCases { if await engine.isInstalled(model) { installed.insert(model) } }
        installedModels = installed
        if phase == .idle { prewarmSelectedModel() }
    }

    func download(_ model: SpeechModel) async {
        guard downloadingModel == nil, phase == .idle, !keyboardSessionActive else { return }
        errorMessage = nil; downloadingModel = model; downloadProgress = 0
        defer { downloadingModel = nil; prewarmSelectedModel() }
        do {
            try await engine.download(model) { [weak self] progress in
                Task { @MainActor in self?.downloadProgress = min(1, max(0, progress)) }
            }
            await refreshInstalledModels()
            guard installedModels.contains(model) else { throw AppError.modelMissing }
            selectedModel = model
        } catch { errorMessage = "Model download failed: \(error.localizedDescription)" }
    }

    func startRecording() async {
        guard !verificationMode, phase == .idle, downloadingModel == nil else { return }
        guard foreground || keyboardSessionActive else { errorMessage = "Open LocalScribe to start a microphone session."; return }
        guard installedModels.contains(selectedModel) else { errorMessage = "Download your selected model in Models before dictating."; return }
        errorMessage = nil
        phase = .preparing
        let model = selectedModel
        let revision = microphoneRevision
        let backgroundAllowed = await (engine as? any BackgroundInferenceReportingEngine)?.supportsBackgroundInference(for: model) ?? false
        guard revision == microphoneRevision, phase == .preparing else { return }
        do {
            // Capture does not wait for Core ML compilation/loading. Stop remains available
            // while the ordered recognition pump waits for the model.
            try await recorder.arm()
            guard revision == microphoneRevision, foreground || keyboardSessionActive else {
                if recordingID == nil { recorder.shutdown() }
                if revision == microphoneRevision, phase == .preparing {
                    phase = .idle
                    errorMessage = "Open LocalScribe to start recording."
                    scheduleModelRelease()
                }
                return
            }
            recorder.beginCapture()
            let id = UUID()
            recordingID = id
            transcript = ""; rawTranscript = ""; partialText = ""; currentEntryID = nil; captureModel = model; captureBackgroundInferenceAllowed = backgroundAllowed
            capturedSampleCount = 0; captureWarning = nil; acceptsLiveUpdates = true
            elapsed = 0; level = 0; recordingStartedAt = Date(); phase = .recording
            if keyboardSessionActive { renewKeyboardSession() }
            recordingTimer?.invalidate()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .recording, let start = self.recordingStartedAt else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                    if let expires = self.keyboardSessionExpiresAt, expires.timeIntervalSinceNow <= 60 { self.renewKeyboardSession() }
                }
            }
            let task = Task { [self] in
                try await waitForInferenceForeground(backgroundAllowed: backgroundAllowed, recordingID: id)
                try await prepareRuntime(model)
                guard recordingID == id else { throw CancellationError() }
                guard let streaming = engine as? any StreamingLocalTranscriptionEngine else { throw AppError.streamingUnavailable }
                try await waitForInferenceForeground(backgroundAllowed: backgroundAllowed, recordingID: id)
                try await streaming.beginStreaming { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.recordingID == id, self.acceptsLiveUpdates else { return }
                        self.rawTranscript = update.text
                        self.partialText = TranscriptCorrection.apply(self.dictionary, to: update.text)
                    }
                }
                while phase == .recording, recordingID == id {
                    try await waitForInferenceForeground(backgroundAllowed: backgroundAllowed, recordingID: id)
                    guard phase == .recording else { break }
                    let samples = recorder.drainCapture(minimumSamples: 16_000, maximumSamples: 32_000)
                    if samples.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
                    else { try await streaming.appendStreaming(samples: samples) }
                }
            }
            streamingTask = task
            Task { [weak self] in
                do { try await task.value }
                catch {
                    guard let self, self.recordingID == id, self.phase == .recording else { return }
                    await self.stopRecording(streamFailure: error)
                }
            }
        } catch {
            guard revision == microphoneRevision else { return }
            recorder.shutdown(); phase = .idle; errorMessage = error.localizedDescription
            scheduleModelRelease()
        }
    }

    /// Foreground shortcuts explicitly own this recording and its eventual clipboard copy.
    /// Normal Dictate and keyboard recording continue through their existing APIs.
    func startActionButtonRecording() async {
        guard foreground, phase == .idle, !verificationMode else { return }
        actionButtonRecording = true
        await startRecording()
        if phase != .recording { actionButtonRecording = false }
    }

    func stopActionButtonRecording() async {
        guard actionButtonRecording else { return }
        await stopRecording(endKeyboardSession: true)
    }

    private func waitForInferenceForeground(backgroundAllowed: Bool, recordingID id: UUID) async throws {
        // The active engine reports its configured backend, which is frozen for this
        // recording. Unknown engines wait for foreground; model names confer no permission.
        while !backgroundAllowed && !foreground && recordingID == id {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard recordingID == id else { throw CancellationError() }
    }

    func stopRecording(endKeyboardSession: Bool = false) async {
        await stopRecording(endKeyboardSession: endKeyboardSession, streamFailure: nil)
    }

    private func stopRecording(endKeyboardSession: Bool = false, streamFailure: Error?) async {
        guard phase == .recording, let id = recordingID else { return }
        beginBackgroundCompletion()
        recordingTimer?.invalidate(); recordingTimer = nil
        let tail = recorder.endCapture(keepEngineRunning: !endKeyboardSession && keyboardSessionActive)
        let snapshot = recorder.captureSnapshot
        capturedSampleCount = snapshot.receivedSamples - snapshot.overflowSamples
        if snapshot.processingFailureCount > 0 {
            captureWarning = "Microphone audio conversion failed. Recording stopped; already captured text is preserved."
        }
        if snapshot.overflowSamples > 0 {
            captureWarning = "Recognition could not keep up with the microphone. \(String(format: "%.2f", Double(snapshot.overflowSamples) / 16_000)) seconds of new audio could not be buffered. Captured text is preserved."
        }
        let model = captureModel ?? selectedModel
        let backgroundAllowed = captureBackgroundInferenceAllowed
        recordingStartedAt = nil; level = 0; phase = .transcribing
        if endKeyboardSession { disableKeyboardSession() }
        else if keyboardSessionActive { renewKeyboardSession() }
        defer {
            guardRecordingCompletion(id)
        }
        var failure = streamFailure
        do { try await streamingTask?.value }
        catch { if failure == nil { failure = error } }
        do {
            if let failure { throw failure }
            try await waitForInferenceForeground(backgroundAllowed: backgroundAllowed, recordingID: id)
            guard capturedSampleCount > 0 else { throw RecordingError.noAudio }
            guard let streaming = engine as? any StreamingLocalTranscriptionEngine else { throw AppError.streamingUnavailable }
            // Final queued audio is bounded by the recorder backlog, with small awaited
            // chunks so no unbounded asynchronous audio queue is introduced.
            var offset = 0
            while offset < tail.count {
                try await waitForInferenceForeground(backgroundAllowed: backgroundAllowed, recordingID: id)
                let end = min(offset + 32_000, tail.count)
                try await streaming.appendStreaming(samples: Array(tail[offset..<end]))
                offset = end
            }
            try await waitForInferenceForeground(backgroundAllowed: backgroundAllowed, recordingID: id)
            let recognized = try await streaming.finishStreaming()
            guard recordingID == id else { return }
            acceptsLiveUpdates = false
            rawTranscript = recognized
            transcript = TranscriptCorrection.apply(dictionary, to: recognized).trimmingCharacters(in: .whitespacesAndNewlines)
            partialText = ""
            guard !transcript.isEmpty else { throw AppError.emptyTranscript }
        } catch {
            acceptsLiveUpdates = false
            // A later recognition failure must not erase words already delivered.
            transcript = TranscriptCorrection.apply(dictionary, to: rawTranscript).trimmingCharacters(in: .whitespacesAndNewlines)
            partialText = ""
            errorMessage = error.localizedDescription + (transcript.isEmpty ? "" : " Captured text remains available to copy or share.")
            if let streaming = engine as? any StreamingLocalTranscriptionEngine { await streaming.cancelStreaming() }
        }
        guard recordingID == id else { return }
        if let warning = captureWarning { errorMessage = warning }
        if saveHistory, !transcript.isEmpty {
            let entry = TranscriptEntry(text: transcript, model: model, duration: Double(capturedSampleCount) / 16_000)
            var updated = history
            updated.insert(entry, at: 0)
            do {
                guard historyWritable else { throw AppError.historyUnavailable }
                try store.save(updated)
                history = updated; currentEntryID = entry.id
            } catch {
                errorMessage = "Dictation is complete, but history could not be saved: \(error.localizedDescription) Your text is still available here to copy or share."
            }
        }
        await refreshPerformanceReports()
    }

    private func guardRecordingCompletion(_ id: UUID) {
        guard recordingID == id else { return }
        streamingTask = nil; recordingID = nil; captureModel = nil; captureBackgroundInferenceAllowed = false; acceptsLiveUpdates = false
        actionButtonRecording = false
        phase = .idle
        onDictationFinished?()
        endBackgroundCompletion()
        scheduleModelRelease()
    }

    func cancelPreparation() async {
        guard phase == .preparing else { return }
        microphoneRevision += 1
        preparationTask?.cancel()
        recorder.shutdown()
        phase = .idle
        if !foreground { releaseRuntime() }
    }

    func enableKeyboardSession() async {
        guard !verificationMode, phase == .idle, downloadingModel == nil, foreground else { return }
        guard installedModels.contains(selectedModel) else { errorMessage = "Download a model before enabling the keyboard microphone session."; return }
        phase = .preparing; errorMessage = nil
        let revision = microphoneRevision
        defer { if revision == microphoneRevision { phase = .idle; if !keyboardSessionActive { scheduleModelRelease() } } }
        do {
            try await recorder.arm()
            guard foreground, revision == microphoneRevision else { throw AppError.sessionEnded }
            try await prepareRuntime(selectedModel)
            await refreshPerformanceReports()
            guard foreground, revision == microphoneRevision else { throw AppError.sessionEnded }
            renewKeyboardSession()
        } catch {
            guard revision == microphoneRevision else {
                if recordingID == nil, !keyboardSessionActive { recorder.shutdown() }
                return
            }
            await refreshPerformanceReports(); recorder.shutdown(); errorMessage = error.localizedDescription
        }
    }

    private func renewKeyboardSession() {
        keyboardSessionExpiresAt = Date().addingTimeInterval(300)
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.phase == .recording { self.renewKeyboardSession() }
                else { await self.finishKeyboardSession() }
            }
        }
    }

    func disableKeyboardSession() {
        microphoneRevision += 1
        sessionTimer?.invalidate(); sessionTimer = nil
        keyboardSessionExpiresAt = nil
        if phase == .recording {
            Task { await stopRecording(endKeyboardSession: true) }
        } else {
            recorder.shutdown()
            if phase == .preparing { preparationTask?.cancel(); phase = .idle }
            if phase == .idle { scheduleModelRelease() }
        }
    }

    /// Stop microphone access at the deadline, then finish captured speech locally.
    func finishKeyboardSession() async {
        if phase == .recording { await stopRecording(endKeyboardSession: true) }
        else { disableKeyboardSession() }
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if !active && !keyboardSessionActive && !actionButtonRecording {
            if phase == .recording { Task { await stopRecording() } }
            else if phase == .preparing { Task { await cancelPreparation() } }
            else { recorder.shutdown(); if phase == .idle { releaseRuntime() } }
        }
        if active, phase == .idle { prewarmSelectedModel() }
    }

    func saveTranscriptEdits() {
        guard let id = currentEntryID else { return }
        updateHistory(id: id, text: transcript)
    }
    func updateHistory(id: UUID, text: String) {
        guard historyWritable else { errorMessage = AppError.historyUnavailable.localizedDescription; return }
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        var updated = history
        updated[index].text = text
        do { try store.save(updated); history = updated }
        catch { errorMessage = "Your edit could not be saved: \(error.localizedDescription)" }
    }

    private func beginBackgroundCompletion() {
        guard backgroundCompletionTask == .invalid else { return }
        backgroundCompletionTask = UIApplication.shared.beginBackgroundTask(withName: "Finish local dictation") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.errorMessage = "iOS ended background processing before dictation finished. Return to LocalScribe to check your text."
                self.endBackgroundCompletion()
            }
        }
    }

    private func endBackgroundCompletion() {
        guard backgroundCompletionTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundCompletionTask)
        backgroundCompletionTask = .invalid
    }

    private func refreshPerformanceReports() async {
        if let measured = engine as? any PerformanceReportingEngine { performanceReports = await measured.performanceReports() }
    }

    private func prewarmSelectedModel() {
        guard !verificationMode, foreground, phase == .idle, downloadingModel == nil, installedModels.contains(selectedModel) else { return }
        let model = selectedModel
        Task { [weak self] in
            do { try await self?.prepareRuntime(model) }
            catch is CancellationError { }
            catch {
                guard let self, self.selectedModel == model, self.phase == .idle, self.foreground else { return }
                self.errorMessage = "The model could not be prepared: \(error.localizedDescription)"
            }
        }
    }

    private func prepareRuntime(_ model: SpeechModel) async throws {
        if preparedModel == model { return }
        if preparationModel == model, let preparationTask, !preparationTask.isCancelled {
            try await preparationTask.value
            return
        }
        let previous = preparationTask
        previous?.cancel()
        let release = runtimeReleaseTask
        preparationRevision += 1
        let revision = preparationRevision
        preparationModel = model
        preparedModel = nil
        modelStatus = "Loading \(model.name)…"
        let engine = engine
        let task = Task { [self] in
            _ = await previous?.result
            await release?.value
            try Task.checkCancellation()
            let statusTask = Task { [weak self] in
                guard let reporting = engine as? any ModelPreparationReportingEngine else { return }
                while !Task.isCancelled {
                    if let stage = await reporting.preparationStage(),
                       let self, self.preparationRevision == revision {
                        switch stage {
                        case .checkingInstallation: self.modelStatus = "Checking \(model.name)…"
                        case .verifyingFiles: self.modelStatus = "Verifying \(model.name)…"
                        case .loadingCoreML: self.modelStatus = "Loading \(model.name)…"
                        case .initializingRecognizer: self.modelStatus = "Starting \(model.name)…"
                        case .ready: break
                        }
                    }
                    do { try await Task.sleep(for: .milliseconds(250)) }
                    catch { return }
                }
            }
            defer { statusTask.cancel() }
            try await engine.prepare(model)
            try Task.checkCancellation()
        }
        preparationTask = task
        do {
            try await task.value
            guard revision == preparationRevision else { throw CancellationError() }
            preparedModel = model
            preparationTask = nil; preparationModel = nil; modelStatus = nil
            await refreshPerformanceReports()
        } catch {
            if revision == preparationRevision {
                preparationTask = nil; preparationModel = nil; modelStatus = nil
            }
            throw error
        }
    }

    private func scheduleModelRelease() {
        // Keep a prepared model ready for repeated foreground dictation. Background
        // lifecycle and memory warnings release it, rather than an arbitrary idle timer.
        guard phase == .idle, !keyboardSessionActive else { return }
        if !foreground { releaseRuntime() }
    }

    private func releaseRuntime() {
        guard !verificationMode, phase == .idle, !keyboardSessionActive else { return }
        preparationRevision += 1
        preparationTask?.cancel()
        let preparation = preparationTask
        preparationTask = nil; preparationModel = nil; preparedModel = nil; modelStatus = nil
        let previous = runtimeReleaseTask
        let engine = engine
        runtimeReleaseTask = Task {
            _ = await preparation?.result
            await previous?.value
            await engine.unload()
        }
    }

}

private enum AppError: LocalizedError {
    case modelMissing, emptyTranscript, sessionEnded, historyUnavailable, streamingUnavailable
    var errorDescription: String? {
        switch self {
        case .modelMissing: "The downloaded model could not be verified. Please try downloading it again."
        case .emptyTranscript: "No speech was recognized. Try a longer recording in a quieter place."
        case .sessionEnded: "The microphone session ended. Open LocalScribe to start again."
        case .streamingUnavailable: "This speech engine does not support live dictation."
        case .historyUnavailable: "Existing history could not be opened and has been preserved. Resolve the storage issue before saving new entries."
        }
    }
}
