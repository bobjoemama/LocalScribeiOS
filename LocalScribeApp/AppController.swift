import Foundation
import Combine
import UIKit
import LocalScribeCore

@MainActor
final class AppController: ObservableObject {
    @Published private(set) var performanceReports: [EnginePerformanceReport] = []
    @Published private(set) var phase: DictationPhase = .idle
    @Published var transcript = ""
    @Published private(set) var rawTranscript = ""
    @Published private(set) var history: [TranscriptEntry] = []
    @Published var errorMessage: String?
    @Published private(set) var installedModels: Set<SpeechModel> = []
    @Published private(set) var downloadingModel: SpeechModel?
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var keyboardSessionExpiresAt: Date?
    @Published var selectedModel: SpeechModel {
        didSet { defaults.set(selectedModel.rawValue, forKey: "selectedModel") }
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
    private var recordingStartedAt: Date?
    private var captureModel: SpeechModel?
    private var currentEntryID: UUID?
    private var recordingTimer: Timer?
    private var sessionTimer: Timer?
    private var warmTimer: Timer?
    private var runtimeReleaseTask: Task<Void, Never>?
    private var memoryObserver: NSObjectProtocol?
    private var foreground = true
    private var microphoneRevision = 0
    private var historyWritable = true
    private var dictionaryWritable = true
    var keyboardSessionActive: Bool { keyboardSessionExpiresAt.map { $0 > Date() } ?? false }
    var isBusy: Bool { phase == .preparing || phase == .transcribing }

    init(engine: any LocalTranscriptionEngine, defaults: UserDefaults = .standard, historyURL: URL? = nil) {
        self.engine = engine
        self.defaults = defaults
        selectedModel = SpeechModel(rawValue: defaults.string(forKey: "selectedModel") ?? "") ?? .parakeetPhonon
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
        recorder.onLimit = { [weak self] in
            guard self?.phase == .recording else { return }
            Task { await self?.stopRecording() }
        }
        recorder.onInterruption = { [weak self] in
            guard let self else { return }
            self.disableKeyboardSession()
            self.errorMessage = "Recording stopped because the microphone was interrupted. Start a new recording when you’re ready."
        }
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .idle else { return }
                self.disableKeyboardSession()
                self.releaseRuntime()
                self.errorMessage = "iPhone requested more memory. The microphone session ended and the speech model was released. Your installed models and history are preserved."
            }
        }
        Task { await refreshInstalledModels() }
    }

    func refreshInstalledModels() async {
        var installed: Set<SpeechModel> = []
        for model in SpeechModel.allCases { if await engine.isInstalled(model) { installed.insert(model) } }
        installedModels = installed
    }

    func download(_ model: SpeechModel) async {
        guard downloadingModel == nil, phase == .idle, !keyboardSessionActive else { return }
        errorMessage = nil; downloadingModel = model; downloadProgress = 0
        defer { downloadingModel = nil }
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
        guard phase == .idle, downloadingModel == nil else { return }
        guard foreground || keyboardSessionActive else { errorMessage = "Open LocalScribe to start a microphone session."; return }
        guard installedModels.contains(selectedModel) else { errorMessage = "Download your selected model in Models before dictating."; return }
        errorMessage = nil
        phase = .preparing
        warmTimer?.invalidate(); warmTimer = nil
        let model = selectedModel
        let revision = microphoneRevision
        do {
            await runtimeReleaseTask?.value
            try await engine.prepare(model)
            await refreshPerformanceReports()
            guard revision == microphoneRevision, foreground || keyboardSessionActive else { throw AppError.sessionEnded }
            try await recorder.arm()
            guard revision == microphoneRevision, foreground || keyboardSessionActive else { recorder.shutdown(); throw AppError.sessionEnded }
            recorder.beginCapture()
            transcript = ""; rawTranscript = ""; currentEntryID = nil; captureModel = model
            elapsed = 0; level = 0; recordingStartedAt = Date(); phase = .recording
            recordingTimer?.invalidate()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .recording, let start = self.recordingStartedAt else { return }
                    self.elapsed = min(120, Date().timeIntervalSince(start))
                    if self.elapsed >= 120 { await self.stopRecording() }
                }
            }
        } catch { await refreshPerformanceReports(); recorder.shutdown(); phase = .idle; errorMessage = error.localizedDescription; scheduleModelRelease() }
    }

    func stopRecording(endKeyboardSession: Bool = false) async {
        guard phase == .recording else { return }
        beginBackgroundCompletion()
        recordingTimer?.invalidate(); recordingTimer = nil
        let samples = recorder.endCapture(keepEngineRunning: !endKeyboardSession && keyboardSessionActive)
        let duration = Double(samples.count) / 16_000
        let model = captureModel ?? selectedModel
        recordingStartedAt = nil; level = 0; phase = .transcribing
        if endKeyboardSession { disableKeyboardSession() }
        defer {
            phase = .idle
            onDictationFinished?()
            endBackgroundCompletion()
            scheduleModelRelease()
        }
        do {
            guard !samples.isEmpty else { throw RecordingError.noAudio }
            let recognized = try await engine.transcribe(samples: samples)
            await refreshPerformanceReports()
            rawTranscript = recognized
            transcript = TranscriptCorrection.apply(dictionary, to: recognized).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw AppError.emptyTranscript }
            if saveHistory {
                let entry = TranscriptEntry(text: transcript, model: model, duration: duration)
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
        } catch { await refreshPerformanceReports(); errorMessage = error.localizedDescription }
    }

    func enableKeyboardSession() async {
        guard phase == .idle, downloadingModel == nil, foreground else { return }
        guard installedModels.contains(selectedModel) else { errorMessage = "Download a model before enabling the keyboard microphone session."; return }
        phase = .preparing; errorMessage = nil
        warmTimer?.invalidate(); warmTimer = nil
        let revision = microphoneRevision
        defer { phase = .idle; if !keyboardSessionActive { scheduleModelRelease() } }
        do {
            await runtimeReleaseTask?.value
            try await engine.prepare(selectedModel)
            await refreshPerformanceReports()
            guard foreground, revision == microphoneRevision else { throw AppError.sessionEnded }
            try await recorder.arm()
            guard foreground, revision == microphoneRevision else { recorder.shutdown(); throw AppError.sessionEnded }
            keyboardSessionExpiresAt = Date().addingTimeInterval(300)
            sessionTimer?.invalidate()
            sessionTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    await self.finishKeyboardSession()
                }
            }
        } catch { await refreshPerformanceReports(); recorder.shutdown(); errorMessage = error.localizedDescription }
    }

    func disableKeyboardSession() {
        microphoneRevision += 1
        sessionTimer?.invalidate(); sessionTimer = nil
        keyboardSessionExpiresAt = nil
        recorder.shutdown()
        if phase == .recording {
            recordingTimer?.invalidate(); recordingTimer = nil
            phase = .idle; elapsed = 0; level = 0; recordingStartedAt = nil
        }
        if phase == .idle { scheduleModelRelease() }
    }

    /// Stop microphone access at the deadline, then finish captured speech locally.
    func finishKeyboardSession() async {
        if phase == .recording { await stopRecording(endKeyboardSession: true) }
        else { disableKeyboardSession() }
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if !active && !keyboardSessionActive {
            if phase == .recording {
                Task { await stopRecording() }
            } else { recorder.shutdown(); if phase == .idle { releaseRuntime() } }
        }
        if active, phase == .idle, !keyboardSessionActive { scheduleModelRelease() }
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

    private func scheduleModelRelease() {
        warmTimer?.invalidate(); warmTimer = nil
        guard phase == .idle, !keyboardSessionActive else { return }
        if !foreground { releaseRuntime(); return }
        warmTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.releaseRuntime() }
        }
    }

    private func releaseRuntime() {
        guard phase == .idle, !keyboardSessionActive else { return }
        warmTimer?.invalidate(); warmTimer = nil
        let previous = runtimeReleaseTask
        let engine = engine
        runtimeReleaseTask = Task {
            await previous?.value
            await engine.unload()
        }
    }
}

private enum AppError: LocalizedError {
    case modelMissing, emptyTranscript, sessionEnded, historyUnavailable
    var errorDescription: String? {
        switch self {
        case .modelMissing: "The downloaded model could not be verified. Please try downloading it again."
        case .emptyTranscript: "No speech was recognized. Try a longer recording in a quieter place."
        case .sessionEnded: "The microphone session ended. Open LocalScribe to start again."
        case .historyUnavailable: "Existing history could not be opened and has been preserved. Resolve the storage issue before saving new entries."
        }
    }
}
