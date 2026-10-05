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
                    Task {
                        busy = true
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
                    Button("Reset \(collection.rawValue)…", role: .destructive) { requestedReset = collection }
                        .disabled(!available)
                    if controller.unreadableSavedData.contains(collection)
                        || (collection == .notes && notes.errorMessage != nil)
                    {
                        Text("\(collection.title) could not be opened or saved.").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(
                    "Retry after unlocking if a file could not be opened. Reset saves a protected recovery copy before clearing the selected collection. Models and settings stay unchanged."
                )
            }
            if !recoveryCopies.isEmpty {
                Section {
                    ForEach(recoveryCopies, id: \.self) { file in
                        ShareLink(item: file) { Label(copyLabel(file), systemImage: "square.and.arrow.up") }
                    }
                } header: {
                    Text("Recovery copies")
                } footer: {
                    Text("Copies contain saved text. Choose where to export them.")
                }
            }
            if let status { Section { Text(status).textSelection(.enabled) } }
        }
        .navigationTitle("Saved data")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadCopies() }
        .confirmationDialog(
            "Reset \(requestedReset?.rawValue ?? "saved data")?",
            isPresented: Binding(get: { requestedReset != nil }, set: { if !$0 { requestedReset = nil } }),
            titleVisibility: .visible
        ) {
            Button("Reset \(requestedReset?.rawValue ?? "saved data")", role: .destructive) {
                guard let collection = requestedReset else { return }
                requestedReset = nil
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

    private func reset(_ collection: SavedDataCollection) async {
        guard available else { return }
        busy = true
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
