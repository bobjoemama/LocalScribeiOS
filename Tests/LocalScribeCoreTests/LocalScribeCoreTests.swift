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

@Test func recordingCanDrainBeyondTheOldDurationLimitWithoutLoss() {
    let buffer = CaptureBuffer(capacitySamples: CaptureBuffer.sampleRate * 10)
    buffer.begin()
    var emitted: Int64 = 0
    // Three minutes exceed the former two-minute session bound while queued audio
    // stays below ten seconds. Every chunk retains its order and original values.
    for second in 0..<180 {
        let samples = Array(repeating: Float(second), count: CaptureBuffer.sampleRate)
        #expect(!buffer.append(samples))
        if second % 8 == 7 {
            let chunk = buffer.drain(minimumSamples: CaptureBuffer.sampleRate * 8)
            #expect(chunk.count == CaptureBuffer.sampleRate * 8)
            for offset in 0..<8 {
                #expect(chunk[offset * CaptureBuffer.sampleRate] == Float(second - 7 + offset))
            }
            emitted += Int64(chunk.count)
        }
        #expect(buffer.snapshot.bufferedSamples <= CaptureBuffer.sampleRate * 8)
        #expect(buffer.snapshot.overflowSamples == 0)
    }
    let tail = buffer.finish()
    #expect(tail.count == CaptureBuffer.sampleRate * 4)
    emitted += Int64(tail.count)
    #expect(emitted == Int64(CaptureBuffer.sampleRate * 180))
    #expect(buffer.snapshot.receivedSamples == emitted)
    #expect(buffer.snapshot.drainedSamples == emitted)
    #expect(buffer.captureGeneration == nil)
}

@Test func drainPreservesMinimumTailAndGenerationFence() throws {
    let buffer = CaptureBuffer(capacitySamples: 6)
    buffer.begin()
    let generation = try #require(buffer.captureGeneration)
    buffer.append([1, 2, 3, 4], generation: generation)
    #expect(buffer.drain(minimumSamples: 5, maximumSamples: 5).isEmpty)
    #expect(buffer.snapshot.bufferedSamples == 4)
    #expect(buffer.drain(minimumSamples: 2, maximumSamples: 3, generation: generation) == [1, 2, 3])
    #expect(buffer.captureGeneration == generation)
    #expect(!buffer.append([5, 6, 7, 8], generation: generation))
    #expect(buffer.drain(maximumSamples: 3) == [4, 5, 6])
    #expect(buffer.finish() == [7, 8])
    #expect(buffer.snapshot.receivedSamples == 8)
    #expect(buffer.snapshot.drainedSamples == 8)
    buffer.begin()
    buffer.append([9, 10])
    #expect(buffer.drain(maximumSamples: 2, generation: generation).isEmpty)
    #expect(buffer.finish() == [9, 10])
}

@Test func captureBackpressureIsCountedAndNeverSilentlyHidden() {
    let buffer = CaptureBuffer(capacitySamples: 4)
    buffer.begin()
    #expect(buffer.append([1, 2, 3, 4]))
    #expect(buffer.snapshot.overflowSamples == 0) // Merely full is not lost audio.
    #expect(buffer.append([5, 6]))
    #expect(buffer.snapshot.receivedSamples == 6)
    #expect(buffer.snapshot.bufferedSamples == 4)
    #expect(buffer.snapshot.overflowSamples == 2)
    #expect(buffer.drain(maximumSamples: 2) == [1, 2])
    #expect(buffer.append([7, 8, 9]))
    #expect(buffer.snapshot.overflowSamples == 3)
    #expect(buffer.finish() == [3, 4, 7, 8])
    #expect(buffer.snapshot.receivedSamples == buffer.snapshot.drainedSamples + buffer.snapshot.overflowSamples)
    buffer.begin()
    #expect(buffer.snapshot.receivedSamples == 0)
    #expect(buffer.snapshot.overflowSamples == 0)
}

@Test func explicitCaptureDiscardIsSeparatelyCounted() {
    let buffer = CaptureBuffer(capacitySamples: 4)
    buffer.begin()
    buffer.append([1, 2, 3])
    #expect(buffer.drain(maximumSamples: 1) == [1])
    buffer.discard()
    #expect(buffer.finish().isEmpty)
    #expect(buffer.snapshot.discardedSamples == 2)
    #expect(buffer.snapshot.receivedSamples == buffer.snapshot.drainedSamples + buffer.snapshot.discardedSamples)
    #expect(!buffer.append([4]))
    #expect(buffer.snapshot.receivedSamples == 3)
}

@Test func converterFailuresSurviveStopAndRespectGeneration() throws {
    let buffer = CaptureBuffer()
    #expect(!buffer.markProcessingFailure())
    buffer.begin()
    let previous = try #require(buffer.captureGeneration)
    #expect(buffer.markProcessingFailure(generation: previous))
    #expect(buffer.snapshot.processingFailureCount == 1)
    _ = buffer.finish()
    #expect(buffer.snapshot.processingFailureCount == 1)
    buffer.begin()
    #expect(buffer.snapshot.processingFailureCount == 0)
    #expect(!buffer.markProcessingFailure(generation: previous))
    #expect(buffer.snapshot.processingFailureCount == 0)
}

@Test func concurrentCaptureAndDrainPreserveEverySample() async {
    let buffer = CaptureBuffer(capacitySamples: 16_000)
    buffer.begin()
    await withTaskGroup(of: [Float].self) { group in
        group.addTask {
            for value in 0..<8_000 { buffer.append([Float(value)]) }
            return []
        }
        group.addTask {
            var received: [Float] = []
            for _ in 0..<8_000 { received += buffer.drain(maximumSamples: 7) }
            return received
        }
        var received: [Float] = []
        for await part in group { received += part }
        received += buffer.finish()
        #expect(received == (0..<8_000).map { Float($0) })
    }
    #expect(buffer.snapshot.overflowSamples == 0)
    #expect(buffer.snapshot.drainedSamples == 8_000)
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
