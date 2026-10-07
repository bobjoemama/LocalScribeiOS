#if DEBUG && targetEnvironment(simulator)
import Combine
import Foundation
import LocalScribeCore
import SwiftUI

/// Screenshot-only fixtures. This file is excluded from every physical-device
/// build and Release build. No fixture is a hardware or recognition measurement.
struct DesignPreviewConfiguration {
    enum State: String {
        case idle, recording, preparing, transcribing, done, error
        case modelsDownloading = "models-downloading"
        case modelsFailed = "models-failed"

        var showsModels: Bool { self == .modelsDownloading || self == .modelsFailed }
    }

    enum Destination: String {
        case performance, accuracy, about, usage
        case developerProfiling = "developer-profiling"
        case measurementDetails = "measurement-details"
        case actionButton = "action-button"
        case keyboardSetup = "keyboard-setup"
        case savedData = "saved-data"
        case historyEditor = "history-editor"
        case dictionaryEditor = "dictionary-editor"
        case dictionaryNew = "dictionary-new"
        case snippetEditor = "snippet-editor"
        case snippetNew = "snippet-new"
        case noteEditor = "note-editor"
    }

    enum Dialog: String {
        case discard, delete, reset
        case saveError = "save-error"
    }

    let state: State
    let appearance: String
    let showsModels: Bool
    let destination: Destination?
    let dialog: Dialog?

    static let current: DesignPreviewConfiguration? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--design-preview") else { return nil }
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let state = State(rawValue: value("--preview-state") ?? "idle") ?? .idle
        let requestedAppearance = value("--preview-appearance") ?? "system"
        return DesignPreviewConfiguration(
            state: state,
            appearance: ["system", "light", "dark"].contains(requestedAppearance) ? requestedAppearance : "system",
            showsModels: state.showsModels || value("--preview-tab") == "models",
            destination: value("--preview-destination").flatMap(Destination.init(rawValue:)),
            dialog: value("--preview-dialog").flatMap(Dialog.init(rawValue:)))
    }()

    static let installedModels: Set<SpeechModel> = [.parakeetRealtimeEOU, .moonshineSmall, .parakeetPhonon, .parakeetUltra]
    static let transcript = "Please send the updated meeting notes by Friday. Include the timeline and the decisions we made today. I will review the final version before the team meeting."
    static let liveTranscript = "We have finished the first draft and reviewed the remaining questions. The next step is to send the updated meeting notes to the team. Include the timeline and the decisions we made today. I will review the final version before Friday."
    static let firstNoteID = UUID(uuidString: "434C98A4-5DE5-40B4-8F47-8E927DC78580")!
}

/// A deliberately inert engine: only the installed-state fixture is returned.
/// Downloading, loading and recognition all fail instead of touching real files,
/// network, microphone or runtime adapters.
private actor DesignPreviewEngine: LocalTranscriptionEngine {
    func isInstalled(_ model: SpeechModel) async -> Bool { DesignPreviewConfiguration.installedModels.contains(model) }
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws { throw PreviewUnavailable() }
    func prepare(_ model: SpeechModel) async throws { throw PreviewUnavailable() }
    func transcribe(samples: [Float]) async throws -> String { throw PreviewUnavailable() }
    func unload() async {}

    private struct PreviewUnavailable: LocalizedError {
        var errorDescription: String? { "Design previews do not record, load models or download files." }
    }
}

@MainActor
private final class DesignPreviewContext: ObservableObject {
    let controller: AppController
    let notes: NotesController
    let defaults: UserDefaults
    let fixtureDirectory: URL
    @Published private(set) var fixtureError: String?

    init(configuration: DesignPreviewConfiguration) {
        let fixtureID = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalScribeDesignPreview", isDirectory: true)
            .appendingPathComponent(fixtureID, isDirectory: true)
        fixtureDirectory = directory
        defaults = UserDefaults(suiteName: "com.devesh.localscribe.design-preview.\(fixtureID)")!
        defaults.set(configuration.appearance, forKey: "appearance")
        defaults.set(SpeechModel.parakeetRealtimeEOU.rawValue, forKey: "selectedModel")
        defaults.set(true, forKey: "keepModelLoaded")
        defaults.set(true, forKey: "saveHistory")
        var startupError: String?
        do { try Self.seedStores(in: directory) }
        catch { startupError = "Could not prepare design fixtures: \(error.localizedDescription)" }
        controller = AppController(engine: DesignPreviewEngine(), defaults: defaults,
            historyURL: directory.appendingPathComponent("history.json"), verificationMode: true)
        notes = NotesController(historyDirectoryURL: directory)
        fixtureError = startupError
        Task {
            await controller.refreshInstalledModels()
            controller.applyDesignPreviewState(configuration.state)
        }
    }

    private static func seedStores(in directory: URL) throws {
        let now = Date()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        try HistoryStore(file: directory.appendingPathComponent("history.json")).save([
            TranscriptEntry(createdAt: now.addingTimeInterval(-600), text: DesignPreviewConfiguration.transcript,
                model: .parakeetRealtimeEOU, duration: 18),
            TranscriptEntry(createdAt: now.addingTimeInterval(-3_600), text: "Remember to pick up coffee on the way home.",
                model: .moonshineSmall, duration: 7),
            TranscriptEntry(createdAt: yesterday, text: "The updated schedule is ready. Please check the dates before sharing it.",
                model: .parakeetPhonon, duration: 11)
        ])
        try DictionaryStore(file: directory.appendingPathComponent("dictionary.json")).save([
            DictionaryRule(heard: "local scape", replacement: "LocalScribe"),
            DictionaryRule(heard: "devish", replacement: "Devesh"),
            DictionaryRule(heard: "swift you eye", replacement: "SwiftUI", isEnabled: false)
        ])
        try SnippetStore(file: directory.appendingPathComponent("snippets.json")).save([
            SpokenSnippet(trigger: "my sign off", expansion: "Thanks,\nDevesh"),
            SpokenSnippet(trigger: "meeting follow up", expansion: "Thanks for the meeting. I will send the notes and next steps shortly.")
        ])
        // NoteStore's current on-disk envelope, used only for synthetic files in
        // this fresh temporary directory. Dates use its native deferred format.
        struct PreviewNotesDocument: Encodable { let version = 2; let notes: [NoteEntry] }
        let noteDirectory = directory.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
        let noteData = try JSONEncoder().encode(PreviewNotesDocument(notes: [
            NoteEntry(id: DesignPreviewConfiguration.firstNoteID, createdAt: now.addingTimeInterval(-1_200), text: "Meeting notes\nSend the timeline to the team. Review the final draft before Friday."),
            NoteEntry(createdAt: yesterday, text: "Weekend errands\nPick up coffee. Check the library hours. Call home.")
        ]))
        try noteData.write(to: noteDirectory.appendingPathComponent("notes.json"), options: .atomic)
    }
}

@MainActor
struct DesignPreviewRootView: View {
    let configuration: DesignPreviewConfiguration
    @StateObject private var context: DesignPreviewContext
    @StateObject private var performance = LivePerformanceMonitor()
    @StateObject private var developerMetrics = DeveloperMetricsReceiver()
    @StateObject private var profilingReports = ProfilingReportStore()

    init(configuration: DesignPreviewConfiguration) {
        self.configuration = configuration
        _context = StateObject(wrappedValue: DesignPreviewContext(configuration: configuration))
    }

    private var colorScheme: ColorScheme? {
        switch configuration.appearance { case "light": .light; case "dark": .dark; default: nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(context.fixtureError ?? "Design preview · synthetic text and model states")
                .font(.system(size: 11)).foregroundStyle(AppTheme.inkSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 3).background(AppTheme.canvas)
            Group {
                if let destination = configuration.destination {
                    DesignPreviewDestinationView(destination: destination, dialog: configuration.dialog,
                        controller: context.controller, notes: context.notes)
                        .environmentObject(performance)
                        .environmentObject(developerMetrics)
                        .environmentObject(profilingReports)
                } else if configuration.showsModels {
                    ModelsView(controller: context.controller)
                } else {
                    LocalScribeRootView(controller: context.controller, notes: context.notes)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.canvas)
        .defaultAppStorage(context.defaults)
        .preferredColorScheme(colorScheme)
        .tint(AppTheme.accent)
        // Screenshot fixtures cannot trigger clipboard writes or other controls.
        // Routing is supplied by --preview-tab / --preview-library arguments.
        .allowsHitTesting(false)
        .accessibilityIdentifier("design-preview")
        .onAppear {
            // These are current measurements of the simulator app, never model
            // benchmark fixtures or measurements of a physical iPhone.
            if configuration.destination == .performance { performance.start() }
        }
        .onDisappear { performance.stop(); developerMetrics.stop() }
    }
}

@MainActor
private struct DesignPreviewDestinationView: View {
    let destination: DesignPreviewConfiguration.Destination
    let dialog: DesignPreviewConfiguration.Dialog?
    @ObservedObject var controller: AppController
    @ObservedObject var notes: NotesController

    var body: some View {
        switch destination {
        case .historyEditor:
            designPreviewHistoryEditor(entry: controller.history.first ?? TranscriptEntry(
                text: DesignPreviewConfiguration.transcript, model: .parakeetRealtimeEOU, duration: 18), dialog: dialog)
        case .dictionaryEditor, .dictionaryNew:
            designPreviewPersonalizationEditor(controller: controller,
                rule: destination == .dictionaryNew ? nil : controller.dictionary.first, dialog: dialog)
        case .snippetEditor, .snippetNew:
            designPreviewSnippetEditor(controller: controller,
                snippet: destination == .snippetNew ? nil : controller.snippets.first, dialog: dialog)
        default:
            NavigationStack {
                switch destination {
                case .performance: LivePerformanceView(controller: controller)
                case .developerProfiling: LivePerformanceView(controller: controller).designPreviewDeveloperProfiling()
                case .accuracy: PerformanceView(controller: controller)
                case .measurementDetails: designPreviewMeasurementDetails()
                case .actionButton: designPreviewActionButtonSetup(controller: controller)
                case .keyboardSetup: designPreviewKeyboardSetup()
                case .savedData: designPreviewSavedData(controller: controller, notes: notes, dialog: dialog)
                case .about: AboutView()
                case .usage: HistoryUsageView(controller: controller)
                case .noteEditor:
                    designPreviewNoteEditor(controller: notes, dictation: controller,
                        noteID: DesignPreviewConfiguration.firstNoteID, dialog: dialog)
                default: EmptyView()
                }
            }
        }
    }
}
#endif
