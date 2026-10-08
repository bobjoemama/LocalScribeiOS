import SwiftUI
import AppIntents
import UIKit
import LocalScribeCore

struct LocalScribeRootView: View {
    @ObservedObject var controller: AppController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    @State private var tab = 0
    @State private var showingModels = false
    @StateObject private var performance = LivePerformanceMonitor()
    @StateObject private var developerMetrics = DeveloperMetricsReceiver()
    @StateObject private var profilingReports = ProfilingReportStore()
    @State private var showingSavedData = false
    @State private var createdNote: CreatedNoteRequest?
    @State private var libraryPath: [LibraryDestination] = []
    @ObservedObject var notes: NotesController

    init(controller: AppController, notes: NotesController) {
        _controller = ObservedObject(wrappedValue: controller)
        _notes = ObservedObject(wrappedValue: notes)
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let names = ["dictate", "history", "library", "settings", "models"]
        if let index = arguments.firstIndex(of: "--preview-tab"), index + 1 < arguments.count {
            _tab = State(initialValue: names.firstIndex(of: arguments[index + 1]) ?? 0)
        }
        if let index = arguments.firstIndex(of: "--preview-library"), index + 1 < arguments.count {
            let destination: LibraryDestination? = switch arguments[index + 1] {
            case "dictionary": .dictionary
            case "snippets": .snippets
            case "notes": .notes
            default: nil
            }
            if let destination { _tab = State(initialValue: 2); _libraryPath = State(initialValue: [destination]) }
        }
        #endif
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            DictateView(controller: controller, openModels: { showingModels = true }, saveNote: { text in createdNote = CreatedNoteRequest(id: notes.create(text: text)) })
                .tabItem { Label("Dictate", systemImage: "mic") }.tag(0)
            NativeHistoryView(controller: controller, openSavedData: { showingSavedData = true })
                .tabItem { Label("History", systemImage: "clock") }.tag(1)
            LibraryView(controller: controller, notes: notes, path: $libraryPath, openSavedData: { showingSavedData = true })
                .tabItem { Label("Library", systemImage: "books.vertical") }.tag(2)
            SettingsView(controller: controller, notes: notes, openModels: { showingModels = true })
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
            ModelsView(controller: controller, showsDone: false)
                .tabItem { Label("Models", systemImage: "square.stack.3d.up") }.tag(4)
        }
        .sheet(isPresented: $showingModels) { ModelsView(controller: controller) }
        .sheet(isPresented: $showingSavedData) {
            NavigationStack {
                SavedDataView(controller: controller, notes: notes)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingSavedData = false } } }
            }
        }
        .sheet(item: $createdNote) { request in
            NavigationStack {
                NotesView(controller: notes, dictation: controller, initialNoteID: request.id)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { createdNote = nil } } }
            }
        }
        .environmentObject(performance)
        .environmentObject(developerMetrics)
        .environmentObject(profilingReports)
        .preferredColorScheme(colorScheme)
        .tint(AppTheme.accent)
        .background(AppTheme.canvas)
        .toolbarBackground(AppTheme.canvas, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .alert("LocalScribe", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { controller.setForeground(true); startPerformance() }
            else { performance.stop(); developerMetrics.stop() }
            if phase == .background { controller.setForeground(false) }
        }
        .onAppear {
            if controller.actionButtonRecording { tab = 0 }
            if scenePhase == .active { startPerformance() }
        }
        .onDisappear { performance.stop(); developerMetrics.stop() }
        .onChange(of: controller.actionButtonRecording) { _, recording in
            if recording { tab = 0 }
        }
        .onOpenURL { url in
            guard url.scheme == "localscribe" else { return }
            switch url.host {
            case "dictation": tab = 0
            case "models": tab = 4
            case "dictionary": tab = 2; libraryPath = [.dictionary]
            case "snippets": tab = 2; libraryPath = [.snippets]
            case "notes": tab = 2; libraryPath = [.notes]
            case "history": tab = 1
            case "settings": tab = 3
            default: break
            }
        }
    }
    private func startPerformance() {
        let args = ProcessInfo.processInfo.arguments
        guard !args.contains("--benchmark-models"), !args.contains("--verify-dictation") else { return }
        performance.start()
    }

}

private struct CreatedNoteRequest: Identifiable { let id: UUID }
