import Foundation
import Combine
import LocalScribeCore

@MainActor
final class NotesController: ObservableObject {
    @Published private(set) var notes: [NoteEntry] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var errorMessage: String?

    private let store: NoteStore
    private var writable = false
    private var savedIDs: Set<UUID> = []
    private var revision = 0
    private var autosaveTask: Task<Void, Never>?
    private var saveTask: Task<Bool, Never>?

    init(historyDirectoryURL: URL? = nil) {
        let base = historyDirectoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalScribe", isDirectory: true)
        store = NoteStore(file: base.appendingPathComponent("Notes", isDirectory: true).appendingPathComponent("notes.json"))
        Task {
            await loadPreservingDrafts()
            if hasUnsavedChanges { await flush() }
        }
    }

    func note(_ id: UUID) -> NoteEntry? { notes.first { $0.id == id } }
    func isSaved(_ id: UUID) -> Bool { savedIDs.contains(id) }
    func matching(_ query: String) -> [NoteEntry] {
        notes.filter { $0.matches(query) }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
    }

    @discardableResult func create(text: String = "") -> UUID {
        let note = NoteEntry(text: text)
        notes.insert(note, at: 0)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { changed() }
        return note.id
    }
    func update(_ id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updatedAt = max(notes[index].createdAt, Date())
        changed()
    }
    func appendDictation(_ text: String, to id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        notes[index].appendDictation(text)
        changed()
    }
    func delete(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        notes.removeAll { $0.id == id }
        // A newly created note may already be in an in-flight save even before
        // savedIDs updates. Always advance the revision to persist its deletion.
        changed()
    }
    func discardEmptyDraft(_ id: UUID) {
        guard !savedIDs.contains(id), let note = note(id), note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        delete(id)
    }

    private func changed() {
        revision += 1
        hasUnsavedChanges = true
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            _ = await self?.flush()
        }
    }

    /// Drain the current save and any edits made during it. Errors retain drafts
    /// in this controller and leave the previous on-disk snapshot intact.
    @discardableResult func flush() async -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        while true {
            if let saveTask {
                if !(await saveTask.value) { return false }
                continue
            }
            guard hasUnsavedChanges else { return true }
            guard writable else {
                errorMessage = "Your existing notes could not be opened and have been preserved. New edits remain in this session. Retry after resolving the storage issue."
                return false
            }
            let snapshot = notes.filter { savedIDs.contains($0.id) || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let savingRevision = revision
            isSaving = true
            let task = Task { () -> Bool in
                defer { self.isSaving = false; self.saveTask = nil }
                do {
                    try await self.store.save(snapshot)
                    self.savedIDs = Set(snapshot.map(\.id))
                    if self.revision == savingRevision { self.hasUnsavedChanges = false }
                    self.errorMessage = nil
                    return true
                } catch {
                    self.errorMessage = "Could not save notes: \(error.localizedDescription) Your edits remain here. Retry to save them."
                    return false
                }
            }
            saveTask = task
            if !(await task.value) { return false }
        }
    }

    func retrySave() async {
        if !writable { await loadPreservingDrafts() }
        _ = await flush()
    }
    private func loadPreservingDrafts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let saved = try await store.load()
            let drafts = notes
            let draftIDs = Set(drafts.map(\.id))
            notes = drafts + saved.filter { !draftIDs.contains($0.id) }
            savedIDs = Set(saved.map(\.id))
            writable = true
            errorMessage = nil
        } catch {
            writable = false
            errorMessage = "Could not open your notes: \(error.localizedDescription) The existing file has been preserved. New drafts remain in this session."
        }
    }
}
