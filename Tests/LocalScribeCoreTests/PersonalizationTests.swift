import Foundation
import Testing
@testable import LocalScribeCore

@Test func legacyDictionaryDefaultsToEnabledAndNewStateRoundTrips() throws {
    let id = UUID()
    let legacy = Data("[{\"id\":\"\(id)\",\"heard\":\"nova\",\"replacement\":\"NovaOS\"}]".utf8)
    let rules = try JSONDecoder().decode([DictionaryRule].self, from: legacy)
    #expect(rules == [DictionaryRule(id: id, heard: "nova", replacement: "NovaOS")])
    let disabled = DictionaryRule(heard: "nova", replacement: "NovaOS", isEnabled: false)
    #expect(try JSONDecoder().decode(DictionaryRule.self, from: JSONEncoder().encode(disabled)) == disabled)
    #expect(TranscriptCorrection.apply([disabled], to: "nova") == "nova")
}

@Test func snippetsAndDictionaryMatchLongestOnceAcrossBothLibraries() {
    let personalizer = TranscriptPersonalizer(dictionary: [
        DictionaryRule(heard: "nova", replacement: "NovaOS"),
        DictionaryRule(heard: "NovaOS", replacement: "wrong")
    ], snippets: [
        SpokenSnippet(trigger: "nova signature", expansion: "Regards,\nNovaOS"),
        SpokenSnippet(trigger: "email", expansion: "mail@example.com", isEnabled: false)
    ])
    #expect(personalizer.apply("NOVA SIGNATURE; nova, email and supernova.") == "Regards,\nNovaOS; NovaOS, email and supernova.")
    #expect(personalizer.apply("NovaOS") == "wrong") // Original words, not expansions, are matching input.
}

@Test func personalizationPreservesLiteralCasingWhitespaceAndMultilineExpansion() {
    let expansion = "  FIRST $1 \\path\nSecond line\n"
    let personalizer = TranscriptPersonalizer(dictionary: [], snippets: [
        SpokenSnippet(trigger: "my signature", expansion: expansion),
        SpokenSnippet(trigger: "c++ [x]", expansion: "C++")
    ])
    #expect(personalizer.apply("MY SIGNATURE") == expansion)
    #expect(personalizer.apply("Say my signature, then c++ [x].") == "Say \(expansion), then C++.")
}

@Test func unicodeLettersNumbersMarksAndEmojiHaveWholePhraseBoundaries() {
    let personalizer = TranscriptPersonalizer(dictionary: [
        DictionaryRule(heard: "café", replacement: "Café"),
        DictionaryRule(heard: "東京", replacement: "Tokyo")
    ], snippets: [SpokenSnippet(trigger: "launch 🚀", expansion: "Launch ready")])
    #expect(personalizer.apply("CAFÉ, décafé; 東京. launch 🚀!") == "Café, décafé; Tokyo. Launch ready!")
    #expect(personalizer.apply("café2 _café café_ 東京都 launch 🚀ready") == "café2 _café café_ 東京都 launch 🚀ready")
    #expect(personalizer.apply("café\u{0301}") == "café\u{0301}") // A following mark belongs to the original word.
}

@Test func contractionsAreProtectedButPossessivesAndCompleteContractionsWork() {
    let personalizer = TranscriptPersonalizer(dictionary: [
        DictionaryRule(heard: "Don", replacement: "Donna"),
        DictionaryRule(heard: "can", replacement: "possible"),
        DictionaryRule(heard: "John", replacement: "Bob")
    ], snippets: [])
    #expect(personalizer.apply("Don, DON'T, don’t, donʼt; can't, CAN‘T; John's and John’s.") == "Donna, DON'T, don’t, donʼt; can't, CAN‘T; Bob's and Bob’s.")
    let complete = TranscriptPersonalizer(dictionary: [DictionaryRule(heard: "don't", replacement: "do not")], snippets: [SpokenSnippet(trigger: "don'ts", expansion: "restrictions")])
    #expect(complete.apply("don't, don'ts") == "do not, restrictions")
}

@Test func personalizationValidationRejectsInvalidFieldsAndCrossLibraryConflicts() throws {
    let dictionary = [DictionaryRule(heard: "Café", replacement: "Coffee", isEnabled: false)]
    let snippets = [SpokenSnippet(trigger: "my signature", expansion: "Name")]
    #expect(throws: PersonalizationValidation.Failure.emptyTrigger) {
        try PersonalizationValidation.validate(snippet: SpokenSnippet(trigger: " \n", expansion: "Name"), dictionary: [], snippets: [])
    }
    #expect(throws: PersonalizationValidation.Failure.nonlexicalTrigger) {
        try PersonalizationValidation.validate(rule: DictionaryRule(heard: "🚀 !!!", replacement: "Launch"), dictionary: [], snippets: [])
    }
    #expect(throws: PersonalizationValidation.Failure.emptyExpansion) {
        try PersonalizationValidation.validate(snippet: SpokenSnippet(trigger: "signature", expansion: "\n \t"), dictionary: [], snippets: [])
    }
    #expect(throws: PersonalizationValidation.Failure.duplicateTrigger) {
        try PersonalizationValidation.validate(snippet: SpokenSnippet(trigger: " CAFE\u{0301} ", expansion: "Replacement"), dictionary: dictionary, snippets: snippets)
    }
    #expect(throws: PersonalizationValidation.Failure.duplicateTrigger) {
        try PersonalizationValidation.validate(rule: DictionaryRule(heard: "MY SIGNATURE", replacement: "Other"), dictionary: dictionary, snippets: snippets)
    }
    try PersonalizationValidation.validate(snippet: SpokenSnippet(trigger: "launch 🚀", expansion: "Launch"), dictionary: dictionary, snippets: snippets)
    try PersonalizationValidation.validate(rule: dictionary[0], dictionary: dictionary, snippets: snippets, excludingID: dictionary[0].id)
    try PersonalizationValidation.validate(snippet: snippets[0], dictionary: dictionary, snippets: snippets, excludingID: snippets[0].id)
    #expect(throws: PersonalizationValidation.Failure.duplicateTrigger) {
        try PersonalizationValidation.validate(rule: dictionary[0], dictionary: dictionary, snippets: snippets)
    }
}

@Test func duplicateLegacyTriggersResolveDeterministicallyWithoutChaining() {
    let personalizer = TranscriptPersonalizer(dictionary: [DictionaryRule(heard: "hello", replacement: "Dictionary")], snippets: [
        SpokenSnippet(trigger: "HELLO", expansion: "Snippet"),
        SpokenSnippet(trigger: "Dictionary", expansion: "Recursive")
    ])
    #expect(personalizer.apply("Hello. hello!") == "Dictionary. Dictionary!")
}

@Test func snippetStoreRoundTripsAndPreservesCorruptFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalScribeSnippetStoreTests-\(UUID())")
    let store = SnippetStore(file: directory.appendingPathComponent("nested/snippets.json"))
    #expect(try store.load().isEmpty)
    let snippets = [SpokenSnippet(trigger: "address", expansion: "First line\nSecond line", isEnabled: false)]
    try store.save(snippets)
    #expect(try store.load() == snippets)
    let values = try store.file.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
    let corrupt = Data("{preserve existing broken library}".utf8)
    try corrupt.write(to: store.file)
    #expect(throws: (any Error).self) { _ = try store.load() }
    #expect(throws: (any Error).self) { try store.save([]) }
    #expect(try Data(contentsOf: store.file) == corrupt)
}

@Test func wholeSnippetIgnoresOnlyAddedSentenceTerminatorsAndPreservesSavedTextExactly() {
    let expansion = "\n  First line\nSecond line\n\n"
    let personalizer = TranscriptPersonalizer(dictionary: [DictionaryRule(heard: "dictionary word", replacement: "Replacement")], snippets: [
        SpokenSnippet(trigger: "the signature", expansion: expansion),
        SpokenSnippet(trigger: "c++", expansion: "std::vector<int>"),
        SpokenSnippet(trigger: "email@work", expansion: "name@example.com"),
        SpokenSnippet(trigger: "signal", expansion: "Plain"),
        SpokenSnippet(trigger: "signal!", expansion: "Explicit exclamation"),
        SpokenSnippet(trigger: "disabled", expansion: "Wrong", isEnabled: false)
    ])
    #expect(personalizer.apply("  THE SIGNATURE.\n") == expansion)
    #expect(personalizer.apply("the signature!?。！？") == expansion)
    #expect(personalizer.apply("then the signature.") == "then \(expansion).")
    #expect(personalizer.apply("C++. ") == "std::vector<int>")
    #expect(personalizer.apply("EMAIL@WORK!") == "name@example.com")
    #expect(personalizer.apply("signal!") == "Explicit exclamation")
    #expect(personalizer.apply("signal!!") == "Explicit exclamation")
    #expect(personalizer.apply("signal++") == "Plain++") // Inline matching preserves meaningful punctuation.
    #expect(personalizer.apply("disabled.") == "disabled.")
    #expect(personalizer.apply("dictionary word.") == "Replacement.")
    let canonical = TranscriptPersonalizer(dictionary: [], snippets: [SpokenSnippet(trigger: "café", expansion: "Literal")])
    #expect(canonical.apply("CAFE\u{0301}.") == "Literal")
}

@Test func combiningMarksRemainWordCharactersAndCanonicalDictionaryMatchesPreserveUntouchedBytes() {
    let unaccented = TranscriptPersonalizer(dictionary: [DictionaryRule(heard: "cafe", replacement: "Wrong")], snippets: [])
    let decomposedAccent = "cafe\u{0301}"
    let prefixedMark = "\u{0301}cafe"
    #expect(Array(unaccented.apply(decomposedAccent).utf8) == Array(decomposedAccent.utf8))
    #expect(Array(unaccented.apply(prefixedMark).utf8) == Array(prefixedMark.utf8))
    let accented = TranscriptPersonalizer(dictionary: [DictionaryRule(heard: "café", replacement: "Coffee")], snippets: [])
    let untouched = "na\u{0308}ive"
    #expect(Array(accented.apply("CAFE\u{0301}, \(untouched)").utf8) == Array("Coffee, \(untouched)".utf8))
    let phrase = TranscriptPersonalizer(dictionary: [DictionaryRule(heard: "café résumé", replacement: "Credentials")], snippets: [])
    #expect(phrase.apply("cafe\u{0301} résumé.") == "Credentials.")
    #expect(phrase.apply("café re\u{0301}sume\u{0301}.") == "Credentials.")
}
