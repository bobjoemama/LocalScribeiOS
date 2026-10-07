import Foundation

@main
struct DictationTranscriptTailCheck {
    static func main() {
        var checks = 0
        func require(_ condition: Bool, _ description: String) {
            precondition(condition, description)
            checks += 1
        }
        require(DictationTranscriptTail.make(from: " \n ").isEmpty, "Empty recognition stays empty")
        require(DictationTranscriptTail.make(from: "One. Two. Three. Four.") == "Two. Three. Four.", "Only latest three sentences remain")
        require(DictationTranscriptTail.make(from: "One. Two. Three. Four unfinished") == "Two. Three. Four unfinished", "Live incomplete sentence advances the preview")
        require(DictationTranscriptTail.make(from: "One. Two revised. Three!") == "One. Two revised. Three!", "Revised recognition replaces older text")
        require(DictationTranscriptTail.make(from: "One. Two. Three.", sentenceLimit: 2) == "Two. Three.", "Caller sentence limit is honored")
        require(DictationTranscriptTail.make(from: "One.", sentenceLimit: 0).isEmpty, "Zero sentence limit is empty")
        require(DictationTranscriptTail.make(from: "Dr. Lee arrived. We began. It worked.") == "Dr. Lee arrived. We began. It worked.", "Abbreviation does not remove first sentence")
        require(DictationTranscriptTail.make(from: "一。二。三。四。") == "二。 三。 四。", "CJK sentence punctuation advances")
        let words = (0..<100).map { "word\($0)" }
        let wordTail = DictationTranscriptTail.make(from: words.joined(separator: " "))
        require(wordTail == words.suffix(65).joined(separator: " "), "Unpunctuated recognition keeps latest 65 words")
        require(DictationTranscriptTail.make(from: "hello\nworld") == "hello world", "Unpunctuated line breaks preserve words")
        require(DictationTranscriptTail.make(from: "First.\nSecond.\n\nThird.\tFourth. ") == "Second. Third. Fourth.", "Blank paragraphs do not consume a sentence slot")
        require(DictationTranscriptTail.make(from: "Dr.\n\nLee arrived. We began. It worked.") == "Dr. Lee arrived. We began. It worked.", "Blank paragraphs preserve pending abbreviation text")
        let unicodeTail = DictationTranscriptTail.make(from: String(repeating: "👩🏽‍💻e\u{301}", count: 200) + " latest")
        require(unicodeTail.utf8.count <= DictationTranscriptTail.maximumUTF8Bytes, "UTF8 payload remains bounded")
        require(unicodeTail.hasSuffix(" latest") && !unicodeTail.contains("�"), "Unicode tail keeps latest text without malformed characters")
        let huge = DictationTranscriptTail.make(from: String(repeating: "old words ", count: 100_000) + "New. Recent. Latest.")
        require(huge.hasSuffix("New. Recent. Latest."), "Long recognition still preserves newest speech")
        require(huge.utf8.count <= 1_024, "Long recording does not enlarge ActivityKit payload")
        print("\(checks) dictation transcript-tail checks passed")
    }
}
