import Foundation
import LocalScribeCore

@main struct PersonalizationControllerCheck {
    enum Failure: Error { case failed(String) }
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.failed(message) }; checks += 1
    }
    @MainActor static func eventually(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<200 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw Failure.failed("Timed out")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalScribePersonalizationCheck-\(UUID())")
        let defaults = UserDefaults(suiteName: "Personalization-\(UUID())")!
        defaults.set(false, forKey: "saveHistory")
        let engine = LifecycleEngine(); await engine.releasePreparation()
        let controller = AppController(engine: engine, defaults: defaults, historyURL: root.appendingPathComponent("history.json"))
        await controller.refreshInstalledModels()
        let recorder = AudioRecorder.latest!
        try controller.upsertDictionaryRule(id: nil, heard: "captured", replacement: "Recognized", isEnabled: true)
        let id = controller.dictionary[0].id
        try controller.upsertDictionaryRule(id: id, heard: "Captured", replacement: "Recognized", isEnabled: true)
        try check(controller.dictionary.count == 1 && controller.dictionary[0].id == id, "Edit retains rule identity")
        try check(try DictionaryStore(file: root.appendingPathComponent("dictionary.json")).load() == controller.dictionary, "Dictionary commits to disk")
        do { try controller.upsertSnippet(id: nil, trigger: "CAPTURED", expansion: "Conflict", isEnabled: true); throw Failure.failed("Conflict accepted") }
        catch PersonalizationValidation.Failure.duplicateTrigger { checks += 1 }
        let expansion = "\nLine one\nLine two\n"
        try controller.upsertSnippet(id: nil, trigger: "Captured words", expansion: expansion, isEnabled: true)
        try check(controller.snippets[0].expansion == expansion, "Snippet whitespace preserved by controller")
        await controller.startRecording(); let recording = controller.currentRecordingID
        recorder.feed(32_000)
        try await eventually { !controller.partialText.isEmpty }
        try check(controller.partialText == expansion, "Actual live pipeline applies whole snippet")
        await controller.stopRecording()
        try check(controller.transcript == expansion, "Actual final pipeline preserves exact snippet expansion")
        try check(controller.completedRecordingID == recording, "Completion identifies the owning recording")
        try controller.deleteSnippet(id: controller.snippets[0].id)
        await controller.startRecording(); recorder.feed(16_000)
        try await eventually { !controller.partialText.isEmpty }
        await controller.cancelRecording()
        try check(controller.phase == .idle && !recorder.recording && controller.currentRecordingID == nil, "Cancel stops capture")
        try check(controller.transcript.isEmpty && controller.partialText.isEmpty && controller.completedRecordingID == nil, "Cancel never publishes completion or speech")
        try check(controller.history.isEmpty, "Canceled utterance is not saved")
        let oldDictionary = controller.dictionary
        let dictionaryURL = root.appendingPathComponent("dictionary.json")
        let corrupt = Data("not JSON".utf8); try corrupt.write(to: dictionaryURL)
        do { try controller.upsertDictionaryRule(id: id, heard: "Captured", replacement: "Changed", isEnabled: true); throw Failure.failed("Corrupt overwrite accepted") }
        catch is DecodingError { checks += 1 }
        try check(controller.dictionary == oldDictionary && (try Data(contentsOf: dictionaryURL)) == corrupt, "Failed save preserves memory and file")
        let guarded = AppController(engine: engine, defaults: defaults, historyURL: root.appendingPathComponent("history.json"))
        try check(!guarded.canEditDictionary, "Unreadable dictionary remains read-only")

        let historyRoot = root.appendingPathComponent("history-case")
        let file = historyRoot.appendingPathComponent("history.json")
        let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(60)
        let old = Calendar.current.date(byAdding: .day, value: -9, to: today)!
        let entries = [TranscriptEntry(createdAt: today, text: "Today", model: .parakeetPhonon, duration: 4), TranscriptEntry(createdAt: old, text: "Older", model: .parakeetPhonon, duration: 5)]
        try HistoryStore(file: file).save(entries)
        let historyController = AppController(engine: engine, defaults: defaults, historyURL: file)
        try historyController.replaceHistory(id: entries[0].id, text: "Edited")
        try check(historyController.history[0].id == entries[0].id && historyController.history[0].duration == 4 && historyController.history[0].createdAt == today, "History edit retains metadata")
        try check(historyController.historyRemovalCount(for: 7) == 1, "Retention identifies only older calendar days")
        try historyController.setHistoryRetention(days: 7)
        try check(historyController.history.count == 1 && defaults.integer(forKey: "historyRetentionDays") == 7, "Retention commits data before preference")
        let retained = historyController.history
        do { try historyController.deleteHistory(ids: [UUID()]); throw Failure.failed("Stale deletion accepted") }
        catch { try check(historyController.history == retained, "Stale delete preserves entries") }
        try historyController.clearHistory()
        try check(historyController.history.isEmpty && (try HistoryStore(file: file).load()).isEmpty, "Clear persists only explicit history removal")

        historyController.keyboardIdleMinutes = 1
        await historyController.refreshInstalledModels(); await historyController.enableKeyboardSession()
        try check((historyController.keyboardSessionExpiresAt?.timeIntervalSinceNow ?? 0) <= 61 && (historyController.keyboardSessionExpiresAt?.timeIntervalSinceNow ?? 0) > 55, "Configured timeout applies to idle lease")
        let shared = try SharedKeyboardStore(directory: root.appendingPathComponent("keyboard"))
        let bridge = KeyboardSessionCoordinator(controller: historyController, store: shared)
        // End/re-arm so the coordinator observes a new explicit microphone lease.
        await historyController.finishKeyboardSession()
        await historyController.enableKeyboardSession()
        try await eventually { (try? shared.readStatus()?.phase) == .ready }
        let status = try shared.readStatus()!
        let utterance = UUID()
        try shared.writeCommand(KeyboardCommand(sessionID: status.sessionID!, utteranceID: utterance, action: .start))
        try await eventually { historyController.phase == .recording }
        let keyboardRecorder = AudioRecorder.latest!
        keyboardRecorder.feed(16_000)
        try await eventually { !historyController.partialText.isEmpty }
        try shared.writeCommand(KeyboardCommand(sessionID: status.sessionID!, utteranceID: utterance, action: .cancel))
        try await eventually { historyController.phase == .idle && (try? shared.readStatus()?.phase) == .ready }
        try check(historyController.transcript.isEmpty && (try shared.readStatus()?.transcript) == nil, "Actual keyboard cancel publishes no result")
        try check(historyController.keyboardSessionActive && keyboardRecorder.armed, "Keyboard cancel preserves explicitly armed idle microphone")
        _ = bridge
        await historyController.finishKeyboardSession()
        print("PASS: \(checks) personalization/history/cancel controller checks")
    }
}
