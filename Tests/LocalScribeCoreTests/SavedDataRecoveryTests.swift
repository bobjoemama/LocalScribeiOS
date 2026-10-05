import Foundation
import Testing
@testable import LocalScribeCore

@Test func recoveryPreservesCorruptBytesAndAllowsNewDictionaryWrites() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("dictionary.json")
    let original = Data("not readable JSON".utf8)
    try original.write(to: file)
    let savedCopy = try SavedDataRecovery.reset(file: file, emptyData: Data("[]".utf8))
    let backup = try #require(savedCopy)
    #expect(try Data(contentsOf: backup) == original)
    #expect(try backup.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    #expect(try SavedDataRecovery.backups(for: file).map(\.standardizedFileURL.path).contains(backup.standardizedFileURL.path))
    let store = DictionaryStore(file: file)
    #expect(try store.load().isEmpty)
    try store.save([DictionaryRule(heard: "term", replacement: "Term")])
    #expect(try store.load().count == 1)
}

@Test func recoveryDoesNotChangeOriginalWhenBackupCannotBeCreated() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("history.json")
    let original = Data("existing saved text".utf8)
    try original.write(to: file)
    let blocker = directory.appendingPathComponent("Recovery")
    try Data("blocking file".utf8).write(to: blocker)
    #expect(throws: (any Error).self) { try SavedDataRecovery.reset(file: file, emptyData: Data("[]".utf8)) }
    #expect(try Data(contentsOf: file) == original)
    #expect(try Data(contentsOf: blocker) == Data("blocking file".utf8))
}

@Test func recoveryCreatesValidNotesAndScopesBackupsToTheSelectedFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.json")
    #expect(try SavedDataRecovery.reset(file: file, emptyData: NoteStore.emptyData()) == nil)
    #expect(try await NoteStore(file: file).load().isEmpty)
    let history = directory.appendingPathComponent("history.json")
    try Data("[]".utf8).write(to: history)
    _ = try SavedDataRecovery.reset(file: history, emptyData: Data("[]".utf8))
    #expect(try SavedDataRecovery.backups(for: history).count == 1)
    #expect(try SavedDataRecovery.backups(for: file).isEmpty)
}
