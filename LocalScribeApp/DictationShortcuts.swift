import AppIntents

struct StartDictationShortcut: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription("Start a background recording using your selected model. Use the result of Stop and Copy Dictation with the Shortcuts Copy to Clipboard action.")
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
    static let description = IntentDescription("Finish your shortcut recording locally in the background and return its transcript. Add Copy to Clipboard after this action to copy without opening LocalScribe.")
    static let openAppWhenRun = false
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await MainActor.run { _ = AppContext.shared }
        #if os(iOS)
        if #available(iOS 27.0, *) {
            guard let sessionID = await MainActor.run(body: { AppContext.shared.actionBridge.sessionIdentifier }) else {
                throw DictationActionError.noSession
            }
            progress.totalUnitCount = 1
            let cancellation = await MainActor.run { DictationActionRuntime.CancellationScope(sessionID: sessionID) }
            let text = try await performBackgroundTask {
                let result = try await cancellation.perform(.stop(sessionID: sessionID, progress: progress, completionExecution: .longRunningIntent))
                return result
            } onCancel: { reason in
                cancellation.cancel(reason: .init(reason))
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
    static let description = IntentDescription("Return empty output when starting, or the completed transcript when stopping. In your Action Button shortcut, copy the result only if it has a value.")
    static let openAppWhenRun = false
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await MainActor.run { _ = AppContext.shared }
        let action = await DictationActionRuntime.resolveToggleAction()
        #if os(iOS)
        if #available(iOS 27.0, *), case let .stop(sessionID?, _, _) = action {
            progress.totalUnitCount = 1
            let cancellation = await MainActor.run { DictationActionRuntime.CancellationScope(sessionID: sessionID) }
            let text = try await performBackgroundTask {
                let result = try await cancellation.perform(.stop(sessionID: sessionID, progress: progress, completionExecution: .longRunningIntent))
                return result
            } onCancel: { reason in
                cancellation.cancel(reason: .init(reason))
            }
            return .result(value: text ?? "")
        }
        #endif
        let text = try await DictationActionRuntime.perform(action)
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
