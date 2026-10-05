import AppIntents
import Foundation
import LocalScribeCore
import UniformTypeIdentifiers

@MainActor final class UIPasteboard {
    enum OptionsKey: Hashable { case localOnly }
    static let general = UIPasteboard()
    private(set) var writes = [[String: Any]]()
    func setItems(_ items: [[String: Any]], options: [OptionsKey: Any]) { writes.append(contentsOf: items) }
}
struct DictationActivityAttributes {
    enum Phase: Equatable { case recording, transcribing, ready, failed }
}
@MainActor final class DictationLiveActivity {
    static var authorized = true
    static var requestSucceeds = true
    static var starts = 0
    static var requiredStarts = 0
    static var lastPhase = DictationActivityAttributes.Phase.recording
    static var lastText = ""
    static var regressedToRecording = false
    var canStartRecordingActivity: Bool { Self.authorized }
    func clearOrphanedActivities() {}
    @discardableResult func start(sessionID: UUID, modelName: String, startedAt: Date, required: Bool = false) -> Bool {
        Self.starts += 1
        Self.lastPhase = .recording; Self.lastText = ""; Self.regressedToRecording = false
        if required { Self.requiredStarts += 1 }
        return Self.authorized && Self.requestSucceeds
    }
    func update(phase: DictationActivityAttributes.Phase, elapsed: TimeInterval, message: String? = nil, transcript: String? = nil) {
        if Self.lastPhase == .transcribing && phase == .recording { Self.regressedToRecording = true }
        Self.lastPhase = phase
        if let transcript { Self.lastText = transcript }
    }
    func finish(copied: Bool, elapsed: TimeInterval, transcript: String? = nil) {
        if let transcript { Self.lastText = transcript }
    }
}

@main struct ActionShortcutCheck {
    enum Failure: Error { case check(String) }
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.check(message) }
        checks += 1
    }
    @MainActor static func fixture() async -> AppController {
        let engine = LifecycleEngine()
        await engine.releasePreparation()
        let defaults = UserDefaults(suiteName: "ShortcutCheck-\(UUID())")!
        defaults.set(false, forKey: "saveHistory")
        defaults.set(SpeechModel.parakeetRealtimeEOU.rawValue, forKey: "selectedModel")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ShortcutCheck-\(UUID())/history.json")
        let controller = AppController(engine: engine, defaults: defaults, historyURL: path)
        await controller.refreshInstalledModels()
        return controller
    }
    @MainActor static func main() async throws {
        // Compile and execute the actual intent perform, runtime, bridge and controller.
        // Only UIKit/audio/ActivityKit platform boundaries are fixtures.
        DictationActionRuntime.handler = nil
        let coldIntent = Task { try await ToggleDictationShortcut().perform() }
        try await Task.sleep(for: .milliseconds(150))
        let controller = await fixture()
        let recorder = AudioRecorder.latest!
        var owner: DictationActionBridge? = DictationActionBridge(controller: controller)
        weak var retainedBridge = owner
        _ = try await coldIntent.value
        try check(controller.phase == .recording && recorder.recording, "Cold registration starts capture before successful intent result")
        try check(controller.actionButtonRecording, "Intent return retains Action Button session ownership")
        try check(retainedBridge != nil, "App owner retains bridge after intent returns")
        try await Task.sleep(for: .milliseconds(200))
        try check(controller.phase == .recording, "First toggle stays recording after perform returns")
        try check(DictationLiveActivity.requiredStarts == 1, "Recording requests mandatory Live Activity")
        controller.setForeground(false)
        try check(recorder.recording && controller.phase == .recording, "Returning to caller does not stop app-owned microphone")
        recorder.feed(32_000)
        _ = try await ToggleDictationShortcut().perform()
        try check(controller.phase == .idle && !recorder.recording, "Next toggle stops same session")
        try check(UIPasteboard.general.writes.count == 1, "Stop copies owned transcript exactly once")
        try check(!DictationLiveActivity.regressedToRecording, "Stop never resets Activity processing to recording when partial text clears")
        try check(DictationLiveActivity.lastText == "Captured words.", "Final Activity preview uses actual final transcript")
        try check(UIPasteboard.general.writes.first?[UTType.utf8PlainText.identifier] as? String == "Captured words.", "Clipboard contains real controller transcript")
        do { _ = try await StopLiveDictationIntent(sessionID: UUID()).perform(); throw Failure.check("Stale stop must fail") }
        catch DictationActionError.noSession { checks += 1 }
        try check(UIPasteboard.general.writes.count == 1, "Stale Stop never copies again")
        DictationLiveActivity.authorized = false
        do { _ = try await StartDictationShortcut().perform(); throw Failure.check("Disabled activity must fail") }
        catch DictationActionError.failed { checks += 1 }
        try check(controller.phase == .idle && !recorder.recording, "Unavailable required Live Activity does not activate microphone")
        DictationLiveActivity.authorized = true
        DictationLiveActivity.requestSucceeds = false
        AudioRecorder.samplesOnBeginCapture = 8_000
        controller.saveHistory = true
        let writesBeforeFailedStart = UIPasteboard.general.writes.count
        do { _ = try await StartDictationShortcut().perform(); throw Failure.check("Activity creation failure must fail") }
        catch DictationActionError.failed { checks += 1 }
        try check(controller.phase == .idle && !recorder.recording, "Activity creation failure stops capture before successful shortcut return")
        try check(controller.transcript.isEmpty && controller.history.isEmpty, "Failed Activity creation discards captured audio rather than finalizing or saving it")
        try check(UIPasteboard.general.writes.count == writesBeforeFailedStart, "Failed shortcut start never replaces the clipboard")
        AudioRecorder.samplesOnBeginCapture = 0
        owner = nil
        try check(retainedBridge == nil, "Handler holds no hidden second recorder owner")
        retainedBridge = nil
        do { _ = try await StartDictationShortcut().perform(); throw Failure.check("Missing retained app owner must fail") }
        catch DictationActionError.notReady { checks += 1 }
        print("PASS: \(checks) actual shortcut/bridge/controller checks")
    }
}
