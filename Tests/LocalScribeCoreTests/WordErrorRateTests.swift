import Foundation
import Testing
@testable import LocalScribeCore

@Test func wordErrorRateCountsSubstitutionsInsertionsAndDeletions() {
    let mixed = WordErrorRate.evaluate(reference: "one two three", hypothesis: "one too three four")
    #expect(mixed.substitutions == 1)
    #expect(mixed.insertions == 1)
    #expect(mixed.deletions == 0)
    #expect(mixed.rate == 2.0 / 3.0)
    let deletion = WordErrorRate.evaluate(reference: "keep this word", hypothesis: "keep word")
    #expect(deletion.deletions == 1)
    #expect(deletion.errorCount == 1)
    #expect(deletion.rate == 1.0 / 3.0)
}

@Test func wordErrorRateHandlesEmptyReferencesAndDoesNotClamp() {
    let bothEmpty = WordErrorRate.evaluate(reference: "...", hypothesis: "")
    #expect(bothEmpty.rate == nil)
    #expect(bothEmpty.errorCount == 0)
    let noReference = WordErrorRate.evaluate(reference: "", hypothesis: "two words")
    #expect(noReference.rate == nil)
    #expect(noReference.insertions == 2)
    let noHypothesis = WordErrorRate.evaluate(reference: "two words", hypothesis: "")
    #expect(noHypothesis.rate == 1)
    #expect(noHypothesis.deletions == 2)
    #expect(WordErrorRate.evaluate(reference: "one", hypothesis: "two three four").rate == 3)
}

@Test func wordErrorRateUsesExplicitUnicodeNormalization() {
    let result = WordErrorRate.evaluate(reference: "CAFÉ, Straße! Can't well-being", hypothesis: "cafe\u{301} strasse cant wellbeing")
    #expect(result.rate == 0)
    #expect(WordErrorRate.normalizedWords("Hello\tWORLD\n‘café’ —") == ["hello", "world", "café"])
    #expect(WordErrorRate.evaluate(reference: "café", hypothesis: "cafe").substitutions == 1)
    #expect(WordErrorRate.normalizedWords("你好 世界") == ["你好", "世界"])
}

@Test func wordErrorRateAlignmentHandlesRepeatedWordsAndStableTies() {
    let repeated = WordErrorRate.evaluate(reference: "go go now", hypothesis: "go now")
    #expect(repeated.deletions == 1)
    #expect(repeated.substitutions == 0)
    let tie = WordErrorRate.evaluate(reference: "a b", hypothesis: "b a")
    #expect(tie.errorCount == 2)
    #expect(tie.substitutions == 2)
}

@Test func wordErrorRateResultRoundTripsWithoutNonfiniteNumbers() throws {
    let result = WordErrorRate.evaluate(reference: "", hypothesis: "inserted")
    let encoded = try JSONEncoder().encode(result)
    #expect(try JSONDecoder().decode(WordErrorRateResult.self, from: encoded) == result)
}
