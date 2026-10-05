import Foundation
import Testing
@testable import LocalScribeCore

private func notesTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("localscribe-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func notesStoreRoundTripsWhitespaceDatesAndIdentifiers() async throws {
    let directory = try notesTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteStore(file: directory.appendingPathComponent("notes.json"))
    #expect(try await store.load().isEmpty)
    let original = NoteEntry(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                             updatedAt: Date(timeIntervalSince1970: 1_700_000_005),
                             text: "Title\twith tabs\n\nSecond line\tkeeps spacing.\n\n")
    try await store.save([original])
    #expect(try await store.load() == [original])
    #expect(original.title == "Title\twith tabs")
}

@Test func notesStoreRoundTripsCurrentTimestampPrecisionExactly() async throws {
    let directory = try notesTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteStore(file: directory.appendingPathComponent("notes.json"))
    // Exercise actual current timestamps, including their sub-millisecond bits,
    // rather than choosing dates whose epoch-millisecond conversion is exact.
    let notes = (0..<64).map { NoteEntry(createdAt: Date(), updatedAt: Date(), text: "Note \($0)\t\n\n") }
    try await store.save(notes)
    #expect(try await store.load() == notes)
}

@Test func notesStoreReadsLegacyMillisecondsAndWritesExactVersionTwo() async throws {
    let directory = try notesTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.json")
    let original = NoteEntry(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                             updatedAt: Date(timeIntervalSince1970: 1_700_000_005),
                             text: "Legacy note\t\n\n")
    struct LegacyDocument: Encodable { let version: Int; let notes: [NoteEntry] }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(LegacyDocument(version: 1, notes: [original])).write(to: file)
    let store = NoteStore(file: file)
    #expect(try await store.load() == [original])
    let current = NoteEntry(createdAt: Date(), updatedAt: Date(), text: "New note\t\n")
    try await store.save([original, current])
    #expect(try await store.load() == [original, current])
    let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(document["version"] as? Int == 2)
}

@Test func noteSearchFindsTitlesAndFullBodyIgnoringCaseAndAccents() {
    let note = NoteEntry(text: "\n\tCafé plan\nHidden detail: NOVA\tproject.\n")
    #expect(note.title == "Café plan")
    #expect(note.matches("CAFE"))
    #expect(note.matches("nova\tproject"))
    #expect(note.matches("   "))
    #expect(!note.matches("absent"))
    #expect(NoteEntry().title == "Untitled note")
}

@Test func noteDictationAppendsWithoutNormalizingTypedWhitespace() {
    var trailing = NoteEntry(text: "Typed\ttext\n\n")
    trailing.appendDictation("Dictated\twords.\n")
    #expect(trailing.text == "Typed\ttext\n\nDictated\twords.\n")
    var sameLine = NoteEntry(text: "Typed text\t")
    sameLine.appendDictation("New speech.")
    #expect(sameLine.text == "Typed text\t\nNew speech.")
    let unchanged = sameLine
    sameLine.appendDictation(" \t\n")
    #expect(sameLine == unchanged)
}

@Test func corruptNotesArePreservedEvenIfCallerSkipsLoad() async throws {
    let directory = try notesTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.json")
    let corrupt = Data("{\"version\":1,\"notes\":[broken".utf8)
    try corrupt.write(to: file)
    let store = NoteStore(file: file)
    await #expect(throws: (any Error).self) { try await store.load() }
    await #expect(throws: (any Error).self) { try await store.save([NoteEntry(text: "Do not replace existing notes")]) }
    #expect(try Data(contentsOf: file) == corrupt)
}

@Test func failedNoteSaveLeavesPreviousSnapshotReadable() async throws {
    let directory = try notesTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.json")
    let store = NoteStore(file: file)
    let original = NoteEntry(text: "Keep this saved note.")
    try await store.save([original])
    let bytes = try Data(contentsOf: file)
    await #expect(throws: (any Error).self) { try await store.save([original, original]) }
    #expect(try Data(contentsOf: file) == bytes)
    #expect(try await store.load() == [original])
    let invalid = NoteEntry(createdAt: Date(timeIntervalSince1970: .infinity), text: "Encoding must fail")
    await #expect(throws: (any Error).self) { try await store.save([invalid]) }
    #expect(try Data(contentsOf: file) == bytes)
}

@Test func unsupportedNotesFormatIsPreserved() async throws {
    let directory = try notesTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.json")
    let future = Data("{\"version\":3,\"notes\":[]}".utf8)
    try future.write(to: file)
    let store = NoteStore(file: file)
    await #expect(throws: (any Error).self) { try await store.save([]) }
    #expect(try Data(contentsOf: file) == future)
}

@Test func failedNoteDirectoryCreationPreservesBlockingFile() async throws {
    let directory = try notesTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocker = directory.appendingPathComponent("blocked")
    let bytes = Data("An existing file, not a directory".utf8)
    try bytes.write(to: blocker)
    let store = NoteStore(file: blocker.appendingPathComponent("notes.json"))
    await #expect(throws: (any Error).self) { try await store.save([NoteEntry(text: "Unsaved draft")]) }
    #expect(try Data(contentsOf: blocker) == bytes)
}
