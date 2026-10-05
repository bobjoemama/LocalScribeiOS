import Foundation
import LocalScribeCore

@main struct NotesControllerCheck {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("localscribe-notes-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks = 0
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "NotesControllerCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        func settled(_ controller: NotesController) async throws {
            let deadline = Date().addingTimeInterval(3)
            while controller.isLoading {
                guard Date() < deadline else { throw NSError(domain: "NotesControllerCheck", code: 2) }
                await Task.yield()
            }
        }
        let controller = NotesController(historyDirectoryURL: directory)
        do {
            _ = try await controller.resetSavedNotes()
            throw NSError(domain: "NotesControllerCheck", code: 3, userInfo: [NSLocalizedDescriptionKey: "Loading reset unexpectedly succeeded"])
        } catch {
            try expect(controller.isLoading, "A reset during initial load must be rejected")
        }
        try await settled(controller)
        let id = controller.create(text: "Saved fixture note\nBody")
        let firstSaved = await controller.flush()
        try expect(firstSaved && controller.isSaved(id), "Note saves before resetting")
        let file = directory.appendingPathComponent("Notes/notes.json")
        let original = try Data(contentsOf: file)
        let backup = try await controller.resetSavedNotes()
        try expect(backup != nil, "Existing notes get a recoverable backup")
        try expect(try Data(contentsOf: backup!) == original, "Backup retains exact pre-reset bytes")
        try expect(try controller.savedDataBackups().contains { $0.standardizedFileURL.path == backup!.standardizedFileURL.path }, "Recovery backup is accessible through the controller")
        try expect(controller.notes.isEmpty && !controller.hasUnsavedChanges && controller.errorMessage == nil, "Successful reset clears memory and errors")
        let store = NoteStore(file: file)
        let resetNotes = try await store.load()
        try expect(resetNotes.isEmpty, "Reset writes a valid empty snapshot")
        controller.create(text: "Queued draft must not resurrect")
        _ = try await controller.resetSavedNotes()
        try await Task.sleep(for: .milliseconds(2_100))
        let afterAutosaveDelay = try await store.load()
        try expect(afterAutosaveDelay.isEmpty && controller.notes.isEmpty, "Canceled autosave does not resurrect pre-reset drafts")
        let newID = controller.create(text: "After reset")
        let newSaved = await controller.flush()
        try expect(newSaved && controller.isSaved(newID), "Notes remain writable after reset")

        let corruptDirectory = directory.appendingPathComponent("corrupt")
        let corruptFile = corruptDirectory.appendingPathComponent("Notes/notes.json")
        try FileManager.default.createDirectory(at: corruptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{broken fixture".utf8)
        try corrupt.write(to: corruptFile)
        let unreadable = NotesController(historyDirectoryURL: corruptDirectory)
        try await settled(unreadable)
        unreadable.create(text: "Draft retained until confirmed reset")
        let failedSave = await unreadable.flush()
        try expect(!failedSave && unreadable.hasUnsavedChanges, "Unreadable storage retains drafts and refuses overwrite")
        let corruptBackup = try await unreadable.resetSavedNotes()
        try expect(try Data(contentsOf: corruptBackup!) == corrupt, "Reset backs up even malformed saved data exactly")
        unreadable.create(text: "Recovered")
        let recoveredSave = await unreadable.flush()
        try expect(recoveredSave && unreadable.errorMessage == nil, "Recovered notes can save normally")

        let blockedDirectory = directory.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        let blocker = blockedDirectory.appendingPathComponent("Notes")
        let blockerBytes = Data("fixture file blocks directory creation".utf8)
        try blockerBytes.write(to: blocker)
        let blocked = NotesController(historyDirectoryURL: blockedDirectory)
        try await settled(blocked)
        let retainedID = blocked.create(text: "Keep this draft after reset failure")
        do {
            _ = try await blocked.resetSavedNotes()
            throw NSError(domain: "NotesControllerCheck", code: 4, userInfo: [NSLocalizedDescriptionKey: "Blocked reset unexpectedly succeeded"])
        } catch {
            try expect(blocked.note(retainedID)?.text == "Keep this draft after reset failure" && blocked.hasUnsavedChanges, "Failed recovery leaves all drafts intact")
            try expect(try Data(contentsOf: blocker) == blockerBytes, "Failed recovery leaves blocking file intact")
        }
        print("PASS: \(checks) notes controller recovery checks")
    }
}
