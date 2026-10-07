// Appended to the production NoteDictationSession and the established lifecycle
// fixtures by check_note_dictation_session.sh. This verifies ownership at real
// AppController suspension points, without SwiftUI or a physical microphone.
@main struct NoteDictationSessionCheck {
    enum Failure: Error { case failed(String) }
    @MainActor static var checks = 0

    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.failed(message) }
        checks += 1
    }

    @MainActor static func eventually(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.failed("Timed out waiting for a fixture transition")
    }

    @MainActor static func main() async {
        do { try await runChecks() }
        catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    @MainActor static func runChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalScribeNoteSessionCheck-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "LocalScribeNoteSessionCheck-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "saveHistory")
        preferences.set(false, forKey: "keepModelLoaded")
        preferences.set(SpeechModel.parakeetRealtimeEOU.rawValue, forKey: "selectedModel")
        let engine = LifecycleEngine()
        await engine.releasePreparation()
        let dictation = AppController(engine: engine, defaults: preferences, historyURL: directory.appendingPathComponent("history.json"))
        await dictation.refreshInstalledModels()
        let recorder = AudioRecorder.latest!
        let notes = NotesController(historyDirectoryURL: directory)
        try await eventually { !notes.isLoading }
        let noteID = notes.create(text: "Existing note stays intact.")
        _ = await notes.flush()
        let original = notes.note(noteID)!.text
        let session = NoteDictationSession(notes: notes, dictation: dictation, noteID: noteID)

        // Hold the actual controller inside microphone permission/preparation.
        AudioRecorder.holdNextArm = true
        let preparingNote = Task { @MainActor in await session.start() }
        try await eventually { recorder.armContinuation != nil }
        try check(session.isStarting && dictation.phase == .preparing, "Note preparation exposes an owned starting state")
        try check(dictation.currentRecordingID == nil, "Preparation has not started capture")
        await session.stop()
        try check(dictation.phase == .idle && !recorder.recording, "Stop cancels microphone preparation immediately")
        try check(notes.note(noteID)?.text == original, "Preparation cancellation preserves existing note text")
        recorder.armContinuation?.resume()
        recorder.armContinuation = nil
        await preparingNote.value
        try check(!session.isStarting && !session.ownsRecording, "Canceled startup relinquishes ownership")
        try check(!recorder.armed && !recorder.recording && dictation.currentRecordingID == nil, "Late permission completion cannot restart canceled capture")
        try check(dictation.completedRecordingID == nil, "Canceled preparation produces no transcript completion")

        // A canceled permission await may finish after a different owner starts.
        // Its late return must not claim or cancel that newer recording UUID.
        AudioRecorder.holdNextArm = true
        let canceledBeforeAction = Task { @MainActor in await session.start() }
        try await eventually { recorder.armContinuation != nil }
        await session.stop()
        await dictation.startActionButtonRecording()
        let newerActionID = dictation.currentRecordingID
        try check(dictation.actionButtonRecording && newerActionID != nil, "A new Action Button recording can start after canceled note preparation")
        recorder.armContinuation?.resume()
        recorder.armContinuation = nil
        await canceledBeforeAction.value
        try check(dictation.actionButtonRecording && dictation.currentRecordingID == newerActionID && dictation.phase == .recording,
                  "Canceled note startup never claims or cancels a newer Action Button recording")
        try check(!session.ownsRecording && notes.note(noteID)?.text == original,
                  "Canceled note remains unowned and unchanged after a newer recording starts")
        await dictation.cancelRecording()

        // A genuine note-owned recording stops and inserts its result once.
        await session.start()
        try check(session.ownsRecording && dictation.phase == .recording, "Note owns its successfully started recording")
        recorder.feed(16_000)
        await session.stop()
        try check(dictation.phase == .idle && !session.ownsRecording, "Stop finishes the owned recording")
        let completedNote = notes.note(noteID)!.text
        try check(completedNote.hasPrefix(original) && completedNote.contains("Captured words."), "Owned completion appends recognized text without replacing the note")
        session.receiveCompletion()
        await session.stop()
        try check(notes.note(noteID)?.text == completedNote, "Repeated Stop/completion does not insert text twice")

        // Preparation and capture started elsewhere must remain untouched.
        AudioRecorder.holdNextArm = true
        let externalPreparation = Task { @MainActor in await dictation.startRecording() }
        try await eventually { recorder.armContinuation != nil }
        await session.stop()
        try check(dictation.phase == .preparing && recorder.armContinuation != nil, "Note Stop does not cancel unrelated preparation")
        recorder.armContinuation?.resume()
        recorder.armContinuation = nil
        await externalPreparation.value
        let externalID = dictation.currentRecordingID
        await session.start()
        await session.stop()
        try check(externalID != nil && dictation.currentRecordingID == externalID && dictation.phase == .recording, "Note start/Stop cannot take over or stop unrelated capture")
        recorder.feed(16_000)
        await dictation.stopRecording()
        session.receiveCompletion()
        try check(notes.note(noteID)?.text == completedNote, "Unrelated completion is never inserted into this note")

        // A keyboard microphone lease and Action Button capture have distinct owners.
        await dictation.enableKeyboardSession()
        try check(dictation.keyboardSessionActive && recorder.armed, "Fixture has an active keyboard microphone lease")
        await session.start()
        await session.stop()
        try check(dictation.keyboardSessionActive && recorder.armed && !session.ownsRecording, "Note controls do not end or claim a keyboard lease")
        await dictation.finishKeyboardSession()
        await dictation.startActionButtonRecording()
        let actionID = dictation.currentRecordingID
        try check(dictation.actionButtonRecording && actionID != nil, "Fixture has an Action Button recording")
        await session.start()
        await session.stop()
        try check(dictation.actionButtonRecording && dictation.currentRecordingID == actionID && !session.ownsRecording, "Note controls do not claim or stop Action Button recording")
        await dictation.cancelRecording()
        _ = await notes.flush()
        print("PASS: \(checks) note dictation preparation and ownership checks")
    }
}
