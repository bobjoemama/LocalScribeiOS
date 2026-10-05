import AppIntents

struct StartDictationShortcut: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription("Open Local Scribe and start a recording using your selected local model. Stop to copy the transcript.")
    static let openAppWhenRun = true
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult {
        try await DictationActionRuntime.perform(.start)
        return .result()
    }
}

struct StopDictationShortcut: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Stop and Copy Dictation"
    static let description = IntentDescription("Open Local Scribe, finish your shortcut recording locally, and copy the transcript.")
    static let openAppWhenRun = true
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult {
        try await DictationActionRuntime.perform(.stop(sessionID: nil))
        return .result()
    }
}

struct ToggleDictationShortcut: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Dictate and Copy"
    static let description = IntentDescription("Hold the Action Button once to start, release and speak, then hold again to stop and copy. Local Scribe opens for microphone access and local transcription.")
    static let openAppWhenRun = true
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult {
        try await DictationActionRuntime.perform(.toggle)
        return .result()
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
