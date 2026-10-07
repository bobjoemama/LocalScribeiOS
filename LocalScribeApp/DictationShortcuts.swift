import AppIntents

struct StartDictationShortcut: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription("Start a background recording using your Action Button CPU model. Stop to copy the transcript.")
    static let openAppWhenRun = false
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await MainActor.run { _ = AppContext.shared }
        let text = try await DictationActionRuntime.perform(.start)
        return .result(value: text ?? "")
    }
}

struct StopDictationShortcut: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop and Copy Dictation"
    static let description = IntentDescription("Finish your shortcut recording locally in the background and copy the transcript.")
    static let openAppWhenRun = false
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await MainActor.run { _ = AppContext.shared }
        #if os(iOS)
        if #available(iOS 27.0, *) {
            let sessionID = await MainActor.run { AppContext.shared.actionBridge.sessionIdentifier }
            progress.totalUnitCount = 1
            let text = try await performBackgroundTask {
                let result = try await DictationActionRuntime.perform(.stop(sessionID: sessionID, progress: progress))
                return result
            } onCancel: { _ in
                guard let sessionID else { return }
                Task { @MainActor in await DictationActionRuntime.cancel(sessionID: sessionID) }
            }
            return .result(value: text ?? "")
        }
        #endif
        let text = try await DictationActionRuntime.perform(.stop(sessionID: nil))
        return .result(value: text ?? "")
    }
}

struct ToggleDictationShortcut: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Dictate and Copy"
    static let description = IntentDescription("Hold the Action Button once to start, release and speak, then hold again to stop and copy.")
    static let openAppWhenRun = false
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await MainActor.run { _ = AppContext.shared }
        #if os(iOS)
        let sessionID = await MainActor.run { AppContext.shared.actionBridge.sessionIdentifier }
        if #available(iOS 27.0, *), let sessionID {
            progress.totalUnitCount = 1
            let text = try await performBackgroundTask {
                let result = try await DictationActionRuntime.perform(.stop(sessionID: sessionID, progress: progress))
                return result
            } onCancel: { _ in
                Task { @MainActor in await DictationActionRuntime.cancel(sessionID: sessionID) }
            }
            return .result(value: text ?? "")
        }
        #endif
        let text = try await DictationActionRuntime.perform(.toggle)
        return .result(value: text ?? "")
    }
}

struct LocalScribeShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .blue }
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleDictationShortcut(), phrases: ["Dictate and copy with \(.applicationName)"], shortTitle: "Dictate and Copy", systemImageName: "mic")
        AppShortcut(intent: StartDictationShortcut(), phrases: ["Start dictation with \(.applicationName)"], shortTitle: "Start Dictation", systemImageName: "mic")
        AppShortcut(intent: StopDictationShortcut(), phrases: ["Stop dictation with \(.applicationName)"], shortTitle: "Stop and Copy", systemImageName: "stop.fill")
    }
}

#if os(iOS)
@available(iOS 27.0, *)
extension StopDictationShortcut: LongRunningIntent, CancellableIntent {}
@available(iOS 27.0, *)
extension ToggleDictationShortcut: LongRunningIntent, CancellableIntent {}
#endif
