import LocalScribeCore
import SwiftUI

struct SavedDataView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var notes: NotesController
    @State private var requestedReset: SavedDataCollection?
    @State private var recoveryCopies: [URL] = []
    @State private var status: String?
    @State private var busy = false

    private var available: Bool {
        !busy && controller.phase == .idle && !controller.keyboardSessionActive
            && !controller.actionButtonRecording && !notes.isLoading && !notes.isSaving
    }

    var body: some View {
        Form {
            Section {
                Button("Retry opening saved data") {
                    guard available else { return }
                    busy = true
                    status = nil
                    Task {
                        defer { busy = false }
                        do {
                            let failures = try controller.retrySavedData()
                            await notes.retrySave()
                            status = (failures + [notes.errorMessage].compactMap { $0 }).joined(separator: "\n")
                            if status?.isEmpty == true { status = "Saved data opened." }
                        } catch { status = error.localizedDescription }
                    }
                }.disabled(!available)
                ForEach(SavedDataCollection.allCases) { collection in
                    LabeledContent(collection.title) {
                        Text(collectionStatus(collection))
                            .foregroundStyle(collectionNeedsAttention(collection) ? AppTheme.error : AppTheme.success)
                    }
                    Button("Reset \(collection.title)…", role: .destructive) { requestedReset = collection }
                        .disabled(!available)
                }
            } footer: {
                Text(
                    "Retry after unlocking if a file could not be opened. Reset saves a protected recovery copy before clearing the selected collection. Models and settings stay unchanged."
                ).foregroundStyle(AppTheme.inkSecondary)
            }.listRowBackground(AppTheme.surface)
            if busy {
                Section { ProgressView("Updating saved data…") }.listRowBackground(AppTheme.surface)
            }
            if !recoveryCopies.isEmpty {
                Section {
                    ForEach(recoveryCopies, id: \.self) { file in
                        ShareLink(item: file) { Label(copyLabel(file), systemImage: "square.and.arrow.up") }
                    }
                } header: {
                    Text("Recovery copies").foregroundStyle(AppTheme.inkSecondary)
                } footer: {
                    Text("Copies contain saved text. Choose where to export them.").foregroundStyle(AppTheme.inkSecondary)
                }.listRowBackground(AppTheme.surface)
            }
            if let status { Section { Text(status).textSelection(.enabled) }.listRowBackground(AppTheme.surface) }
        }
        .scribeForm()
        .navigationTitle("Saved data")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadCopies() }
        .confirmationDialog(
            "Reset \(requestedReset?.rawValue ?? "saved data")?",
            isPresented: Binding(get: { requestedReset != nil }, set: { if !$0 { requestedReset = nil } }),
            titleVisibility: .visible
        ) {
            Button("Reset \(requestedReset?.rawValue ?? "saved data")", role: .destructive) {
                guard available, let collection = requestedReset else { return }
                requestedReset = nil
                busy = true
                status = nil
                Task { await reset(collection) }
            }
            Button("Cancel", role: .cancel) { requestedReset = nil }
        } message: {
            Text(
                requestedReset == .notes
                    ? "Clears saved notes and current note drafts. The previous saved file is kept as a protected recovery copy."
                    : "Clears \(requestedReset?.rawValue ?? "the selected collection"), including unreadable entries. The previous saved file is kept as a protected recovery copy."
            )
        }
    }

    private func collectionNeedsAttention(_ collection: SavedDataCollection) -> Bool {
        controller.unreadableSavedData.contains(collection) || (collection == .notes && notes.errorMessage != nil)
    }

    private func collectionStatus(_ collection: SavedDataCollection) -> String {
        if collection == .notes {
            if notes.isLoading { return "Opening…" }
            if notes.errorMessage != nil { return "Needs attention" }
            if notes.hasUnsavedChanges { return "Unsaved changes" }
        }
        return controller.unreadableSavedData.contains(collection) ? "Unreadable" : "Available"
    }

    private func reset(_ collection: SavedDataCollection) async {
        defer { busy = false }
        do {
            if collection == .notes {
                _ = try await notes.resetSavedNotes()
            } else {
                _ = try controller.resetSavedData(collection)
            }
            status = "\(collection.title) reset."
            loadCopies()
        } catch { status = error.localizedDescription }
    }

    private func loadCopies() {
        do { recoveryCopies = try controller.savedDataBackups() + notes.savedDataBackups() } catch {
            status = "Could not open recovery copies: \(error.localizedDescription)"
        }
    }

    private func copyLabel(_ file: URL) -> String {
        let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count > 1, let timestamp = Double(parts[1]) else { return "Recovery copy" }
        let title = SavedDataCollection(rawValue: String(parts[0]))?.title ?? "Saved data"
        return "\(title) · \(Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened))"
    }
}

#if DEBUG && targetEnvironment(simulator)
private extension SavedDataView {
    init(designPreviewController controller: AppController, notes: NotesController,
         dialog: DesignPreviewConfiguration.Dialog?) {
        self.init(controller: controller, notes: notes)
        if dialog == .reset { _requestedReset = State(initialValue: .history) }
    }
}

@MainActor
func designPreviewSavedData(controller: AppController, notes: NotesController,
    dialog: DesignPreviewConfiguration.Dialog?) -> some View {
    SavedDataView(designPreviewController: controller, notes: notes, dialog: dialog)
}
#endif
