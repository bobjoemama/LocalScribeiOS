import Foundation
import Testing
@testable import LocalScribeCore

@Test func correctionsRespectWholeWordsAndNeverChain() {
    let rules = [DictionaryRule(heard: "nova", replacement: "NovaOS"), DictionaryRule(heard: "NovaOS", replacement: "wrong"), DictionaryRule(heard: "nova os", replacement: "NovaOS")]
    #expect(TranscriptCorrection.apply(rules, to: "NOVA OS, nova; supernova. café") == "NovaOS, NovaOS; supernova. café")
}

@Test func correctionsTreatPatternsLiterallyAndSupportUnicode() {
    #expect(TranscriptCorrection.apply([DictionaryRule(heard: "c++", replacement: "C++"), DictionaryRule(heard: "café", replacement: "Café")], to: "c++ and café; décafé") == "C++ and Café; décafé")
}

@Test func audioDiscardsIdleInputAndBoundsRecording() {
    let buffer = CaptureBuffer()
    #expect(!buffer.append([1, 2]))
    #expect(buffer.finish().isEmpty)
    buffer.begin()
    #expect(buffer.append(Array(repeating: 0.3, count: CaptureBuffer.maximumSamples + 5)))
    #expect(buffer.finish().count == CaptureBuffer.maximumSamples)
    #expect(buffer.finish().isEmpty)
    buffer.begin()
    buffer.append([0.1, 0.2])
    buffer.discard()
    #expect(buffer.finish().isEmpty)
}

@Test func staleAudioCannotEnterTheNextUtterance() throws {
    let buffer = CaptureBuffer()
    #expect(buffer.captureGeneration == nil)
    buffer.begin()
    let previous = try #require(buffer.captureGeneration)
    buffer.append([0.1], generation: previous)
    #expect(buffer.finish() == [0.1])
    buffer.begin()
    let current = try #require(buffer.captureGeneration)
    #expect(current != previous)
    #expect(!buffer.append([0.9], generation: previous))
    buffer.append([0.2], generation: current)
    #expect(buffer.finish() == [0.2])
}

@Test func historyRoundTripsAndCorruptionIsReported() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = HistoryStore(file: directory.appendingPathComponent("history.json"))
    #expect(try store.load().isEmpty)
    let entry = TranscriptEntry(text: "A private thought.", model: .parakeetUltra, duration: 2.5)
    try store.save([entry])
    #expect(try store.load() == [entry])
    try Data("invalid".utf8).write(to: store.file)
    #expect(throws: (any Error).self) { try store.load() }
    try FileManager.default.removeItem(at: directory)
}

@Test func dictionaryIsStoredOutsidePreferencesAndExcludesBackup() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = DictionaryStore(file: directory.appendingPathComponent("dictionary.json"))
    #expect(try store.load().isEmpty)
    let rules = [DictionaryRule(heard: "devesh", replacement: "Devesh")]
    try store.save(rules)
    #expect(try store.load() == rules)
    #expect(try store.file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    try FileManager.default.removeItem(at: directory)
}
