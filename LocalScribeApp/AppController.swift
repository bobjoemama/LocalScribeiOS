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
    @Published private(set) var downloadCompletedCount = 0
    @Published private(set) var downloadTotalCount = 0
    @Published private(set) var failedDownloadModel: SpeechModel?
    @Published private(set) var downloadCancelled = false
    private var downloadTask: Task<Void, Error>?
    private var downloadRevision = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var keyboardSessionExpiresAt: Date?
    @Published private(set) var actionButtonRecording = false
    @Published var selectedModel: SpeechModel {
        didSet {
            defaults.set(selectedModel.rawValue, forKey: "selectedModel")
            guard oldValue != selectedModel else { return }
            prewarmRevision += 1
            guard phase == .idle, !keyboardSessionActive, actionRecordingRequestID == nil, recordingModel == nil else { return }
            releaseRuntime()
            prewarmSelectedModel()
        }
    }
    @Published var keepModelLoaded: Bool {
        didSet {
            defaults.set(keepModelLoaded, forKey: "keepModelLoaded")
            guard oldValue != keepModelLoaded else { return }
            if keepModelLoaded { prewarmSelectedModel() }
            else { scheduleModelRelease() }
        }
    }
    @Published var saveHistory: Bool {
        didSet { defaults.set(saveHistory, forKey: "saveHistory") }
    }
    @Published private(set) var dictionary: [DictionaryRule]
    @Published private(set) var snippets: [SpokenSnippet] = []
    @Published private(set) var completedRecordingID: UUID?
    @Published private(set) var historyRetentionDays = 0
    var currentRecordingID: UUID? { recordingID }
    var actionButtonModel: SpeechModel { selectedModel }
    var canEditDictionary: Bool { dictionaryWritable && snippetsWritable }
    var canEditSnippets: Bool { dictionaryWritable && snippetsWritable }
    var canEditHistory: Bool { historyWritable && phase == .idle }
    @Published var keyboardIdleMinutes: Int {
        didSet { defaults.set(keyboardIdleMinutes, forKey: "keyboardIdleMinutes") }
    }
    @Published var preferBuiltInMicrophone: Bool {
        didSet { defaults.set(preferBuiltInMicrophone, forKey: "preferBuiltInMicrophone"); recorder.preferBuiltInMicrophone = preferBuiltInMicrophone }
    }
    @Published var hapticFeedback: Bool {
        didSet { defaults.set(hapticFeedback, forKey: "hapticFeedback"); recorder.hapticFeedbackEnabled = hapticFeedback }
    }

    var onDictationFinished: (() -> Void)?
    private var backgroundCompletionTask: UIBackgroundTaskIdentifier = .invalid
    private let engine: any LocalTranscriptionEngine
    private let recorder = AudioRecorder()
    private let store: HistoryStore
    private let dictionaryStore: DictionaryStore
    private let snippetStore: SnippetStore
    private var personalizer = TranscriptPersonalizer(dictionary: [], snippets: [])
    private let defaults: UserDefaults
    private let verificationMode: Bool
    private var recordingStartedAt: Date?
    @Published private(set) var recordingModel: SpeechModel?
    private var captureBackgroundInferenceAllowed = false
    private var currentEntryID: UUID?
    private var recordingTimer: Timer?
    private var sessionTimer: Timer?
    private var recordingCleanupTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Error>?
    private var preparationModel: SpeechModel?
    private var preparationRevision = 0
    private var prewarmRevision = 0
    @Published private(set) var preparedModel: SpeechModel?
    private var streamingTask: Task<Void, Error>?
    private var recordingID: UUID?
    private var actionRecordingRequestID: UUID?
    private var capturedSampleCount: Int64 = 0
    private enum CompletionStage {
        case drainingRecognition, processingAudio, finalizingTranscript, savingResult
    }
    private var completionStage: CompletionStage?
    private var captureWarning: String?
    private var acceptsLiveUpdates = false
    private var runtimeReleaseTask: Task<Void, Never>?
    private var memoryObserver: NSObjectProtocol?
    private var foreground = true
    private var microphoneRevision = 0
    private var historyWritable = true
    private var dictionaryWritable = true
    private var snippetsWritable = true
    var keyboardSessionActive: Bool { keyboardSessionExpiresAt.map { $0 > Date() } ?? false }
    var isBusy: Bool { phase == .preparing || phase == .transcribing }

    #if DEBUG
    var verificationCaptureSnapshot: CaptureBufferSnapshot { recorder.captureSnapshot }
    #endif

    #if DEBUG && targetEnvironment(simulator)
    /// Frozen screenshot state only. No recording identifier, audio, inference,
    /// timer or activity is created; hardware metrics remain genuine sampler data.
    func applyDesignPreviewState(_ state: DesignPreviewConfiguration.State) {
        guard verificationMode else { return }
        recordingID = nil
        completedRecordingID = nil
        recordingStartedAt = nil
        recordingModel = nil
        actionButtonRecording = false
        keyboardSessionExpiresAt = nil
        selectedModel = .parakeetRealtimeEOU
        installedModels = DesignPreviewConfiguration.installedModels
        preparedModel = .parakeetRealtimeEOU
        transcript = ""
        rawTranscript = ""
        partialText = ""
        errorMessage = nil
        modelStatus = nil
        level = 0
        elapsed = 0
        downloadingModel = nil
        failedDownloadModel = nil
        downloadProgress = 0
        downloadCompletedCount = 0
        downloadTotalCount = 0
        downloadCancelled = false
        phase = .idle
        switch state {
        case .idle: break
        case .recording:
            recordingModel = selectedModel
            phase = .recording
            partialText = DesignPreviewConfiguration.liveTranscript
            level = 0.62
            elapsed = 42
        case .preparing:
            selectedModel = .parakeetPhonon
            recordingModel = selectedModel
            preparedModel = nil
            phase = .preparing
            modelStatus = "Loading Phonon-2…"
            elapsed = 4
        case .transcribing:
            recordingModel = selectedModel
            phase = .transcribing
            partialText = DesignPreviewConfiguration.liveTranscript
            elapsed = 42
        case .done:
            transcript = DesignPreviewConfiguration.transcript
            rawTranscript = transcript
        case .error:
            transcript = DesignPreviewConfiguration.transcript
            rawTranscript = transcript
            errorMessage = "Design preview: the microphone was interrupted. Captured text remains available."
        case .modelsDownloading:
            downloadingModel = .parakeetPhononG4
            downloadProgress = 0.62
            downloadCompletedCount = 2
            downloadTotalCount = 5
        case .modelsFailed:
            failedDownloadModel = .parakeetPhononG4
            errorMessage = "Design preview: download failed. Check your connection and try again."
        }
    }
    #endif

    init(engine: any LocalTranscriptionEngine, defaults: UserDefaults = .standard, historyURL: URL? = nil, verificationMode: Bool = false) {
        self.engine = engine
        self.defaults = defaults
        self.verificationMode = verificationMode
        #if canImport(UIKit)
        foreground = UIApplication.shared.applicationState == .active
        #endif
        selectedModel = SpeechModel(rawValue: defaults.string(forKey: "selectedModel") ?? "") ?? .parakeetRealtimeEOU
        keepModelLoaded = defaults.object(forKey: "keepModelLoaded") as? Bool ?? true
        saveHistory = defaults.object(forKey: "saveHistory") as? Bool ?? true
        let idle = defaults.integer(forKey: "keyboardIdleMinutes")
        keyboardIdleMinutes = [1, 5, 15, 30].contains(idle) ? idle : 5
        preferBuiltInMicrophone = defaults.bool(forKey: "preferBuiltInMicrophone")
        hapticFeedback = defaults.bool(forKey: "hapticFeedback")
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalScribe", isDirectory: true)
        store = HistoryStore(file: historyURL ?? directory.appendingPathComponent("history.json"))
        dictionaryStore = DictionaryStore(file: (historyURL?.deletingLastPathComponent() ?? directory).appendingPathComponent("dictionary.json"))
        snippetStore = SnippetStore(file: (historyURL?.deletingLastPathComponent() ?? directory).appendingPathComponent("snippets.json"))
        dictionary = []
        recorder.preferBuiltInMicrophone = preferBuiltInMicrophone
        recorder.hapticFeedbackEnabled = hapticFeedback
        do { dictionary = try dictionaryStore.load() }
        catch { dictionaryWritable = false; errorMessage = "Your dictionary could not be opened. It has been preserved: \(error.localizedDescription)" }
        do { snippets = try snippetStore.load() }
        catch { snippetsWritable = false; errorMessage = "Your snippets could not be opened. They have been preserved: \(error.localizedDescription)" }
        personalizer = TranscriptPersonalizer(dictionary: dictionary, snippets: snippets)
        do { history = try store.load() }
        catch { historyWritable = false; errorMessage = "Your history could not be opened. It has been preserved: \(error.localizedDescription)" }
        let retention = defaults.integer(forKey: "historyRetentionDays")
        historyRetentionDays = [0, 1, 7, 30].contains(retention) ? retention : 0
        pruneRetainedHistory()
        recorder.onLevel = { [weak self] level in
            guard self?.phase == .recording else { return }
            self?.level = level
        }
        recorder.onOverflow = { [weak self] droppedSamples in
            guard let self, self.phase == .recording else { return }
            self.captureWarning = "Recognition could not keep up with the microphone. Recording stopped; \(String(format: "%.2f", Double(droppedSamples) / 16_000)) seconds of new audio could not be buffered. Captured text is preserved."
            self.queueRecordingStop(endKeyboardSession: true)
        }
        recorder.onCaptureFailure = { [weak self] failure in
            guard let self, self.phase == .recording else { return }
            self.captureWarning = failure.localizedDescription
            self.queueRecordingStop(endKeyboardSession: true)
        }
        recorder.onInterruption = { [weak self] in
            guard let self else { return }
            if self.phase == .recording {
                self.captureWarning = "The microphone was interrupted. Recording stopped and captured speech is being finished."
                self.queueRecordingStop(endKeyboardSession: true)
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

    /// An event can enqueue a stop before its recording ends. Validate ownership
    /// again after the queue hop so it cannot stop a replacement recording.
    private func queueRecordingStop(endKeyboardSession: Bool) {
        guard let id = recordingID else { return }
        Task { @MainActor [weak self] in
            guard let self, self.recordingID == id, self.phase == .recording else { return }
            await self.stopRecording(endKeyboardSession: endKeyboardSession)
        }
    }

    private func queuePreparationCancellation() {
        let revision = microphoneRevision
        Task { @MainActor [weak self] in
            guard let self, self.microphoneRevision == revision, self.phase == .preparing else { return }
            await self.cancelPreparation()
        }
    }

    func refreshInstalledModels(prewarm: Bool = true) async {
        var installed: Set<SpeechModel> = []
        for model in SpeechModel.allCases { if await engine.isInstalled(model) { installed.insert(model) } }
        installedModels = installed
        if prewarm, phase == .idle { prewarmSelectedModel() }
    }

    func download(_ model: SpeechModel) async {
        await downloadModels([model])
    }

    func downloadAllMissingModels() async {
        await downloadModels(SpeechModel.allCases.filter { !installedModels.contains($0) })
    }

    func cancelDownload() {
        guard downloadingModel != nil else { return }
        downloadCancelled = true
        downloadTask?.cancel()
    }

    private func downloadModels(_ models: [SpeechModel]) async {
        guard !models.isEmpty, downloadingModel == nil, phase == .idle, !keyboardSessionActive else { return }
        errorMessage = nil; failedDownloadModel = nil; downloadCancelled = false
        downloadCompletedCount = 0; downloadTotalCount = models.count
        downloadRevision += 1
        let revision = downloadRevision
        downloadingModel = models[0]; downloadProgress = 0
        let engine = engine
        let task = Task { [self] in
            for model in models {
                try Task.checkCancellation()
                downloadingModel = model; downloadProgress = 0
                do {
                    try await engine.download(model) { [weak self] progress in
                        Task { @MainActor in
                            guard let self, self.downloadRevision == revision,
                                  self.downloadingModel == model, !self.downloadCancelled else { return }
                            self.downloadProgress = min(1, max(0, progress))
                        }
                    }
                    try Task.checkCancellation()
                    guard await engine.isInstalled(model) else { throw AppError.modelMissing }
                    installedModels.insert(model)
                    downloadCompletedCount += 1
                } catch {
                    if !Task.isCancelled { failedDownloadModel = model }
                    throw error
                }
            }
        }
        downloadTask = task
        do { try await task.value }
        catch is CancellationError { downloadCancelled = true }
        catch {
            if !downloadCancelled { errorMessage = "Download failed for \(downloadingModel?.name ?? "model"): \(error.localizedDescription)" }
        }
        downloadTask = nil
        downloadingModel = nil
        // Installation never changes the user's choice or loads successive models.
        await refreshInstalledModels()
    }

    func startRecording() async {
        await startRecording(model: selectedModel)
    }

    private func startRecording(model: SpeechModel, actionRequestID: UUID? = nil) async {
        if let actionRequestID, actionRecordingRequestID != actionRequestID { return }
        await recordingCleanupTask?.value
        if let actionRequestID, actionRecordingRequestID != actionRequestID { return }
        guard !verificationMode, phase == .idle, downloadingModel == nil else { return }
        // A foreground recording takes ownership from an idle Action startup.
        if actionRequestID == nil { actionRecordingRequestID = nil; actionButtonRecording = false }
        guard foreground || keyboardSessionActive || actionButtonRecording else { errorMessage = "Open LocalScribe to start a microphone session."; return }
        guard installedModels.contains(model) else { errorMessage = "Download your selected model in Models before dictating."; return }
        errorMessage = nil
        prewarmRevision += 1
        cancelMismatchedPrewarm(model)
        recordingModel = model
        phase = .preparing
        microphoneRevision += 1
        let revision = microphoneRevision
        let backgroundAllowed = await (engine as? any BackgroundInferenceReportingEngine)?.supportsBackgroundInference(for: model) ?? false
        guard revision == microphoneRevision, phase == .preparing,
              actionRequestID == nil || actionRecordingRequestID == actionRequestID else { return }
        if Task.isCancelled, actionRequestID != nil {
            await cancelPreparation()
            return
        }
        guard !actionButtonRecording || backgroundAllowed || foreground else {
            errorMessage = "\(model.name) requires LocalScribe to stay open. Select a model that supports background dictation to use the Action Button from another app."
            phase = .idle
            recordingModel = nil
            return
        }
        captureBackgroundInferenceAllowed = backgroundAllowed
        do {
            // Capture does not wait for Core ML compilation/loading. Stop remains available
            // while the ordered recognition pump waits for the model.
            try Task.checkCancellation()
            try await recorder.arm(requireExistingPermission: actionButtonRecording, mixWithOtherAudio: actionButtonRecording)
            guard revision == microphoneRevision,
                  actionRequestID == nil || actionRecordingRequestID == actionRequestID,
                  foreground || keyboardSessionActive || actionButtonRecording else {
                if recordingID == nil { recorder.shutdown() }
                if revision == microphoneRevision, phase == .preparing {
                    phase = .idle
                    recordingModel = nil
                    errorMessage = "Open LocalScribe to start recording."
                    scheduleModelRelease()
                }
                return
            }
            try Task.checkCancellation()
            recorder.beginCapture()
            let id = UUID()
            recordingID = id
            completedRecordingID = nil
            transcript = ""; rawTranscript = ""; partialText = ""; currentEntryID = nil; recordingModel = model; captureBackgroundInferenceAllowed = backgroundAllowed
            capturedSampleCount = 0; captureWarning = nil; acceptsLiveUpdates = true
            elapsed = 0; level = 0; recordingStartedAt = Date(); phase = .recording
            recordingFeedback()
            if keyboardSessionActive { renewKeyboardSession() }
            recordingTimer?.invalidate()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .recording, let start = self.recordingStartedAt else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                    if let expires = self.keyboardSessionExpiresAt, expires.timeIntervalSinceNow <= min(60, TimeInterval(self.keyboardIdleMinutes * 30)) { self.renewKeyboardSession() }
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
                        self.partialText = self.personalizer.apply(update.text)
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
            recorder.shutdown(); phase = .idle; recordingModel = nil; errorMessage = error.localizedDescription
            scheduleModelRelease()
        }
    }

    /// Reserve the actual model before installation or Live Activity work can
    /// suspend. A matching cancellation can retire this startup without capture.
    func reserveActionButtonRecording(requestID: UUID, model: SpeechModel) -> Bool {
        guard phase == .idle, !verificationMode, actionRecordingRequestID == nil else { return false }
        actionRecordingRequestID = requestID
        prewarmRevision += 1
        recordingModel = model
        cancelMismatchedPrewarm(model)
        return true
    }

    /// The shortcut freezes the same selected model used by Dictate.
    func startActionButtonRecording(requestID: UUID = UUID(), model requestedModel: SpeechModel? = nil) async {
        guard reserveActionButtonRecording(requestID: requestID, model: requestedModel ?? actionButtonModel) else { return }
        await startReservedActionButtonRecording(requestID: requestID)
    }

    /// Continue only the existing reservation; a cancelled startup is never
    /// recreated when an earlier installation or Activity await finally returns.
    func startReservedActionButtonRecording(requestID: UUID) async {
        guard actionRecordingRequestID == requestID, phase == .idle,
              !verificationMode, let model = recordingModel else { return }
        defer {
            if actionRecordingRequestID == requestID, phase != .recording {
                actionRecordingRequestID = nil
                actionButtonRecording = false
                recordingModel = nil
            }
        }
        let backgroundAllowed = await (engine as? any BackgroundInferenceReportingEngine)?.supportsBackgroundInference(for: model) == true
        guard actionRecordingRequestID == requestID, !Task.isCancelled,
              phase == .idle, !verificationMode else { return }
        guard backgroundAllowed || foreground else {
            errorMessage = "\(model.name) requires LocalScribe to stay open. Select a model that supports background dictation to use the Action Button from another app."
            return
        }
        guard recorder.microphonePermissionGranted else {
            errorMessage = "Open LocalScribe and allow microphone access before using the Action Button."
            return
        }
        captureBackgroundInferenceAllowed = backgroundAllowed
        actionButtonRecording = true
        await startRecording(model: model, actionRequestID: requestID)
    }

    /// Cancellation may arrive before capability discovery creates any recording.
    /// Match the Action request so its late cleanup cannot cancel a replacement.
    func cancelActionButtonRecording(requestID: UUID) async {
        guard actionRecordingRequestID == requestID else { return }
        actionRecordingRequestID = nil
        let ownsRecording = actionButtonRecording
        actionButtonRecording = false
        if ownsRecording { await cancelRecording() }
        else if phase == .idle { recordingModel = nil }
    }

    func stopActionButtonRecording(progress: Progress? = nil) async {
        guard actionButtonRecording else { return }
        await stopRecording(endKeyboardSession: true, streamFailure: nil, progress: progress)
    }

    /// Reports observed work and elapsed waiting time while an App Intent awaits the
    /// owned pipeline. Work units advance only at real checkpoints in stopRecording.
    func monitorActionCompletionProgress(_ progress: Progress?) -> Task<Void, Never>? {
        guard let progress, let id = recordingID else { return nil }
        let began = ContinuousClock.now
        return Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.recordingID == id,
                      self.phase == .recording || self.phase == .transcribing else { return }
                switch self.completionStage {
                case .processingAudio: progress.localizedDescription = "Processing captured audio"
                case .finalizingTranscript: progress.localizedDescription = "Finalizing transcript"
                case .savingResult: progress.localizedDescription = "Saving result"
                case .drainingRecognition, nil:
                    progress.localizedDescription = self.preparedModel == nil
                        ? "Preparing recognition" : "Finishing live recognition"
                }
                let seconds = max(0, began.duration(to: .now).components.seconds)
                progress.localizedAdditionalDescription = "Elapsed \(seconds) s"
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    private func waitForInferenceForeground(backgroundAllowed: Bool, recordingID id: UUID) async throws {
        // The active engine reports its configured backend, which is frozen for this
        // recording. Unknown engines wait for foreground; model names confer no permission.
        while !backgroundAllowed && !foreground && recordingID == id {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard recordingID == id else { throw CancellationError() }
    }

    func stopRecording(endKeyboardSession: Bool = false) async {
        await stopRecording(endKeyboardSession: endKeyboardSession, streamFailure: nil)
    }

    private func stopRecording(endKeyboardSession: Bool = false, streamFailure: Error?, progress: Progress? = nil) async {
        guard phase == .recording, let id = recordingID, let model = recordingModel else { return }
        beginBackgroundCompletion()
        recordingTimer?.invalidate(); recordingTimer = nil
        let tail = recorder.endCapture(keepEngineRunning: !endKeyboardSession && keyboardSessionActive)
        progress?.totalUnitCount = Int64((tail.count + 31_999) / 32_000 + 3)
        progress?.completedUnitCount = 0
        let snapshot = recorder.captureSnapshot
        capturedSampleCount = snapshot.receivedSamples - snapshot.overflowSamples
        if snapshot.processingFailureCount > 0 {
            captureWarning = "Microphone audio conversion failed. Recording stopped; already captured text is preserved."
        }
        if snapshot.overflowSamples > 0 {
            captureWarning = "Recognition could not keep up with the microphone. \(String(format: "%.2f", Double(snapshot.overflowSamples) / 16_000)) seconds of new audio could not be buffered. Captured text is preserved."
        }
        let backgroundAllowed = captureBackgroundInferenceAllowed
        recordingStartedAt = nil; level = 0; phase = .transcribing
        recordingFeedback()
        if endKeyboardSession { disableKeyboardSession() }
        else if keyboardSessionActive { renewKeyboardSession() }
        defer {
            guardRecordingCompletion(id)
        }
        completionStage = .drainingRecognition
        var failure = streamFailure
        do { try await streamingTask?.value; progress?.completedUnitCount += 1 }
        catch { if failure == nil { failure = error } }
        do {
            if let failure { throw failure }
            try await waitForInferenceForeground(backgroundAllowed: backgroundAllowed, recordingID: id)
            guard capturedSampleCount > 0 else { throw RecordingError.noAudio }
            guard let streaming = engine as? any StreamingLocalTranscriptionEngine else { throw AppError.streamingUnavailable }
            // Final queued audio is bounded by the recorder backlog, with small awaited
            // chunks so no unbounded asynchronous audio queue is introduced.
            completionStage = .processingAudio
            var offset = 0
            while offset < tail.count {
                try await waitForInferenceForeground(backgroundAllowed: backgroundAllowed, recordingID: id)
                let end = min(offset + 32_000, tail.count)
                try await streaming.appendStreaming(samples: Array(tail[offset..<end]))
                offset = end
                progress?.completedUnitCount += 1
            }
            try await waitForInferenceForeground(backgroundAllowed: backgroundAllowed, recordingID: id)
            completionStage = .finalizingTranscript
            let recognized = try await streaming.finishStreaming()
            try Task.checkCancellation()
            guard recordingID == id else { return }
            progress?.completedUnitCount += 1
            acceptsLiveUpdates = false
            rawTranscript = recognized
            transcript = personalizer.apply(recognized.trimmingCharacters(in: .whitespacesAndNewlines))
            partialText = ""
            guard !transcript.isEmpty else { throw AppError.emptyTranscript }
        } catch is CancellationError {
            if recordingID == id { await cancelRecording() }
            return
        } catch {
            guard recordingID == id else { return }
            acceptsLiveUpdates = false
            // A later recognition failure must not erase words already delivered.
            transcript = personalizer.apply(rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines))
            partialText = ""
            errorMessage = error.localizedDescription + (transcript.isEmpty ? "" : " Captured text remains available to copy or share.")
            if let streaming = engine as? any StreamingLocalTranscriptionEngine { await streaming.cancelStreaming() }
        }
        guard recordingID == id else { return }
        completionStage = .savingResult
        if let warning = captureWarning { errorMessage = warning }
        if saveHistory, !transcript.isEmpty {
            let entry = TranscriptEntry(text: transcript, model: model, duration: Double(capturedSampleCount) / 16_000)
            var updated = history
            updated.insert(entry, at: 0)
            do {
                guard historyWritable else { throw AppError.historyUnavailable }
                updated = retainedHistory(updated, days: historyRetentionDays)
                try store.save(updated)
                history = updated; currentEntryID = entry.id
            } catch {
                errorMessage = "Dictation is complete, but history could not be saved: \(error.localizedDescription) Your text is still available here to copy or share."
            }
        }
        await refreshPerformanceReports()
        if recordingID == id { progress?.completedUnitCount += 1 }
    }

    private func guardRecordingCompletion(_ id: UUID) {
        guard recordingID == id else { return }
        completionStage = nil
        streamingTask = nil; recordingID = nil; recordingModel = nil; captureBackgroundInferenceAllowed = false; acceptsLiveUpdates = false
        actionButtonRecording = false
        actionRecordingRequestID = nil
        completedRecordingID = id
        phase = .idle
        onDictationFinished?()
        endBackgroundCompletion()
        scheduleModelRelease()
    }

    /// Explicit cancellation discards this utterance and never finalizes it into
    /// history or a clipboard result. The keyboard's armed microphone may remain.
    func cancelRecording() async {
        actionRecordingRequestID = nil
        actionButtonRecording = false
        if phase == .preparing { await cancelPreparation(); return }
        guard phase == .recording || phase == .transcribing else { return }
        microphoneRevision += 1
        completionStage = nil
        recordingID = nil
        completedRecordingID = nil
        acceptsLiveUpdates = false
        recordingTimer?.invalidate(); recordingTimer = nil
        _ = recorder.endCapture(keepEngineRunning: keyboardSessionActive)
        let streamTask = streamingTask
        streamingTask = nil
        streamTask?.cancel()
        preparationTask?.cancel()
        transcript = ""; rawTranscript = ""; partialText = ""
        recordingModel = nil; captureBackgroundInferenceAllowed = false
        actionButtonRecording = false; recordingStartedAt = nil; elapsed = 0; level = 0
        errorMessage = nil; captureWarning = nil
        phase = .idle
        onDictationFinished?()
        let previous = recordingCleanupTask
        let engine = engine
        let cleanup = Task {
            await previous?.value
            _ = await streamTask?.result
            if let streaming = engine as? any StreamingLocalTranscriptionEngine { await streaming.cancelStreaming() }
        }
        recordingCleanupTask = cleanup
        await cleanup.value
        recordingCleanupTask = nil
        endBackgroundCompletion()
        scheduleModelRelease()
    }

    private func recordingFeedback() {
        #if canImport(UIKit)
        if hapticFeedback { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        #endif
    }

    func cancelPreparation() async {
        guard phase == .preparing else { return }
        actionRecordingRequestID = nil
        actionButtonRecording = false
        microphoneRevision += 1
        recordingModel = nil
        preparationTask?.cancel()
        recorder.shutdown()
        phase = .idle
        if preparationTask != nil { releaseRuntime() }
        else { scheduleModelRelease() }
    }

    func enableKeyboardSession() async {
        guard !verificationMode, phase == .idle, downloadingModel == nil, foreground, actionRecordingRequestID == nil else { return }
        let model = selectedModel
        guard installedModels.contains(model) else { errorMessage = "Download a model before enabling the keyboard microphone session."; return }
        prewarmRevision += 1
        recordingModel = model
        phase = .preparing; errorMessage = nil
        microphoneRevision += 1
        let revision = microphoneRevision
        defer { if revision == microphoneRevision { phase = .idle; recordingModel = nil; if !keyboardSessionActive { scheduleModelRelease() } } }
        do {
            try await recorder.arm()
            guard foreground, revision == microphoneRevision else { throw AppError.sessionEnded }
            try await prepareRuntime(model)
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
        keyboardSessionExpiresAt = Date().addingTimeInterval(TimeInterval(keyboardIdleMinutes * 60))
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(keyboardIdleMinutes * 60), repeats: false) { [weak self] _ in
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
            queueRecordingStop(endKeyboardSession: true)
        } else {
            recorder.shutdown()
            if phase == .preparing { preparationTask?.cancel(); phase = .idle; recordingModel = nil }
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
        if !active && !keyboardSessionActive && (!actionButtonRecording || !captureBackgroundInferenceAllowed) {
            if phase == .recording { queueRecordingStop(endKeyboardSession: false) }
            else if phase == .preparing { queuePreparationCancellation() }
            else {
                recorder.shutdown()
                if phase == .idle {
                    // A ready runtime can stay resident without executing. An
                    // unfinished foreground warm-up must not submit GPU/ANE work
                    // after backgrounding; prepare it again on the next foreground.
                    if preparationTask != nil { releaseRuntime() }
                    else { scheduleModelRelease() }
                }
            }
        }
        if active, phase == .idle { pruneRetainedHistory(); prewarmSelectedModel() }
    }

    func upsertDictionaryRule(id: UUID?, heard: String, replacement: String, isEnabled: Bool) throws {
        guard dictionaryWritable && snippetsWritable else { throw AppError.libraryUnavailable }
        if let id, !dictionary.contains(where: { $0.id == id }) { throw AppError.entryChanged }
        let rule = DictionaryRule(id: id ?? UUID(), heard: heard.trimmingCharacters(in: .whitespacesAndNewlines), replacement: replacement, isEnabled: isEnabled)
        try PersonalizationValidation.validate(rule: rule, dictionary: dictionary, snippets: snippets, excludingID: id)
        var updated = dictionary
        if let id, let index = updated.firstIndex(where: { $0.id == id }) { updated[index] = rule }
        else { updated.append(rule) }
        try dictionaryStore.save(updated)
        dictionary = updated
        rebuildPersonalizer()
    }

    func deleteDictionaryRule(id: UUID) throws {
        guard dictionaryWritable else { throw AppError.dictionaryUnavailable }
        guard dictionary.contains(where: { $0.id == id }) else { throw AppError.entryChanged }
        let updated = dictionary.filter { $0.id != id }
        try dictionaryStore.save(updated)
        dictionary = updated
        rebuildPersonalizer()
    }

    func upsertSnippet(id: UUID?, trigger: String, expansion: String, isEnabled: Bool) throws {
        guard dictionaryWritable && snippetsWritable else { throw AppError.libraryUnavailable }
        if let id, !snippets.contains(where: { $0.id == id }) { throw AppError.entryChanged }
        let snippet = SpokenSnippet(id: id ?? UUID(), trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines), expansion: expansion, isEnabled: isEnabled)
        try PersonalizationValidation.validate(snippet: snippet, dictionary: dictionary, snippets: snippets, excludingID: id)
        var updated = snippets
        if let id, let index = updated.firstIndex(where: { $0.id == id }) { updated[index] = snippet }
        else { updated.append(snippet) }
        try snippetStore.save(updated)
        snippets = updated
        rebuildPersonalizer()
    }

    func deleteSnippet(id: UUID) throws {
        guard snippetsWritable else { throw AppError.snippetsUnavailable }
        guard snippets.contains(where: { $0.id == id }) else { throw AppError.entryChanged }
        let updated = snippets.filter { $0.id != id }
        try snippetStore.save(updated)
        snippets = updated
        rebuildPersonalizer()
    }

    private func rebuildPersonalizer() {
        personalizer = TranscriptPersonalizer(dictionary: dictionary, snippets: snippets)
        if phase == .recording { partialText = personalizer.apply(rawTranscript) }
    }

    func saveTranscriptEdits() {
        guard let id = currentEntryID else { return }
        updateHistory(id: id, text: transcript)
    }
    func historyRemovalCount(for days: Int) -> Int {
        history.count - retainedHistory(history, days: days).count
    }

    func setHistoryRetention(days: Int) throws {
        guard [0, 1, 7, 30].contains(days), canEditHistory else { throw AppError.historyUnavailable }
        let updated = retainedHistory(history, days: days)
        try store.save(updated)
        history = updated
        historyRetentionDays = days
        defaults.set(days, forKey: "historyRetentionDays")
        if let id = currentEntryID, !history.contains(where: { $0.id == id }) { currentEntryID = nil }
    }

    private func retainedHistory(_ entries: [TranscriptEntry], days: Int) -> [TranscriptEntry] {
        guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: 1 - days, to: Calendar.current.startOfDay(for: Date())) else { return entries }
        return entries.filter { $0.createdAt >= cutoff }
    }

    private func pruneRetainedHistory() {
        guard canEditHistory, historyRetentionDays > 0 else { return }
        let updated = retainedHistory(history, days: historyRetentionDays)
        guard updated.count != history.count else { return }
        do { try store.save(updated); history = updated }
        catch { errorMessage = "History could not be trimmed: \(error.localizedDescription) Existing transcripts were preserved." }
    }

    func replaceHistory(id: UUID, text: String) throws {
        guard canEditHistory else { throw AppError.historyUnavailable }
        guard let index = history.firstIndex(where: { $0.id == id }) else { throw AppError.entryChanged }
        var updated = history
        updated[index].text = text
        try store.save(updated)
        history = updated
    }

    func updateHistory(id: UUID, text: String) {
        do { try replaceHistory(id: id, text: text) }
        catch { errorMessage = "Your edit could not be saved: \(error.localizedDescription)" }
    }

    func deleteHistory(ids: Set<UUID>) throws {
        guard canEditHistory else { throw AppError.historyUnavailable }
        guard ids.allSatisfy({ id in history.contains(where: { $0.id == id }) }) else { throw AppError.entryChanged }
        let updated = history.filter { !ids.contains($0.id) }
        try store.save(updated)
        history = updated
        if let id = currentEntryID, ids.contains(id) { currentEntryID = nil }
    }

    func clearHistory() throws { try deleteHistory(ids: Set(history.map(\.id))) }

    var unreadableSavedData: Set<SavedDataCollection> {
        var result: Set<SavedDataCollection> = []
        if !historyWritable { result.insert(.history) }
        if !dictionaryWritable { result.insert(.dictionary) }
        if !snippetsWritable { result.insert(.snippets) }
        return result
    }

    func retrySavedData() throws -> [String] {
        try requireIdleSavedDataRecovery()
        var failures: [String] = []
        do { dictionary = try dictionaryStore.load(); dictionaryWritable = true }
        catch { dictionaryWritable = false; failures.append("Dictionary: \(error.localizedDescription)") }
        do { snippets = try snippetStore.load(); snippetsWritable = true }
        catch { snippetsWritable = false; failures.append("Snippets: \(error.localizedDescription)") }
        do { history = try store.load(); historyWritable = true }
        catch { historyWritable = false; failures.append("History: \(error.localizedDescription)") }
        personalizer = TranscriptPersonalizer(dictionary: dictionary, snippets: snippets)
        return failures
    }

    @discardableResult func resetSavedData(_ collection: SavedDataCollection) throws -> URL? {
        try requireIdleSavedDataRecovery()
        let file: URL
        switch collection {
        case .history: file = store.file
        case .dictionary: file = dictionaryStore.file
        case .snippets: file = snippetStore.file
        case .notes: throw NSError(domain: "LocalScribe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reset notes through the notes controller."])
        }
        let backup = try SavedDataRecovery.reset(file: file, emptyData: Data("[]".utf8))
        switch collection {
        case .history: history = []; historyWritable = true; currentEntryID = nil
        case .dictionary: dictionary = []; dictionaryWritable = true
        case .snippets: snippets = []; snippetsWritable = true
        case .notes: break
        }
        personalizer = TranscriptPersonalizer(dictionary: dictionary, snippets: snippets)
        return backup
    }

    func savedDataBackups() throws -> [URL] {
        try [store.file, dictionaryStore.file, snippetStore.file].flatMap { try SavedDataRecovery.backups(for: $0) }
    }

    private func requireIdleSavedDataRecovery() throws {
        guard phase == .idle, !keyboardSessionActive, !actionButtonRecording else {
            throw NSError(domain: "LocalScribe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stop recording and end the keyboard microphone session before managing saved data."])
        }
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

    private func cancelMismatchedPrewarm(_ model: SpeechModel) {
        guard let preparationModel, preparationModel != model else { return }
        releaseRuntime()
    }

    private func prewarmSelectedModel() {
        guard !verificationMode, keepModelLoaded, foreground, phase == .idle, downloadingModel == nil,
              actionRecordingRequestID == nil, recordingModel == nil, recordingCleanupTask == nil else { return }
        // Lifecycle discovery and foregrounding keep the runtime already in use.
        // An explicit selection releases it before requesting its replacement.
        let model = preparedModel ?? preparationModel ?? selectedModel
        guard installedModels.contains(model) else { return }
        let revision = preparationRevision
        let intentRevision = prewarmRevision
        Task { [weak self] in
            guard let self, self.keepModelLoaded, self.foreground, self.phase == .idle,
                  self.downloadingModel == nil, self.actionRecordingRequestID == nil,
                  self.recordingModel == nil, self.recordingCleanupTask == nil,
                  self.preparationRevision == revision, self.prewarmRevision == intentRevision else { return }
            do { try await self.prepareRuntime(model) }
            catch is CancellationError { }
            catch {
                guard self.prewarmRevision == intentRevision, self.phase == .idle, self.foreground,
                      self.actionRecordingRequestID == nil, self.recordingModel == nil else { return }
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
        // Retention owns only runtime references. It never arms a microphone or
        // extends background execution. Real memory warnings still force release.
        guard phase == .idle, !keyboardSessionActive else { return }
        if !keepModelLoaded { releaseRuntime() }
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
    case modelMissing, emptyTranscript, sessionEnded, historyUnavailable, streamingUnavailable, dictionaryUnavailable, snippetsUnavailable, libraryUnavailable, entryChanged
    var errorDescription: String? {
        switch self {
        case .modelMissing: "The downloaded model could not be verified. Please try downloading it again."
        case .emptyTranscript: "No speech was recognized. Try a longer recording in a quieter place."
        case .sessionEnded: "The microphone session ended. Open LocalScribe to start again."
        case .streamingUnavailable: "This speech engine does not support live dictation."
        case .dictionaryUnavailable: "Your existing dictionary is unavailable and has been preserved. Resolve the storage issue before changing it."
        case .snippetsUnavailable: "Your existing snippets are unavailable and have been preserved. Resolve the storage issue before changing them."
        case .libraryUnavailable: "Some saved replacements could not be opened. Open Saved data to retry or reset the affected collection before adding terms or snippets."
        case .entryChanged: "This entry has changed or is no longer available. Close the editor and try again."
        case .historyUnavailable: "Existing history could not be opened and has been preserved. Resolve the storage issue before saving new entries."
        }
    }
}
