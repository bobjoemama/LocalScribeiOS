import Foundation

/// A replacing preview, rather than a second accumulated transcript. Both UI
/// targets use this boundary so ActivityKit never receives unbounded speech text.
enum DictationTranscriptTail {
    static let maximumUTF8Bytes = 1_024
    static let unpunctuatedWordLimit = 65

    static func make(from transcript: String, sentenceLimit: Int = 3) -> String {
        guard sentenceLimit > 0 else { return "" }
        let source = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "" }
        // Inspect only a bounded suffix even after a long recording.
        let candidate = suffix(source, maximumBytes: 8_192)
        var sentences: [String] = []
        var prefix = ""
        candidate.enumerateSubstrings(in: candidate.startIndex..<candidate.endIndex, options: .bySentences) { text, _, _, _ in
            guard let text else { return }
            let fragment = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Foundation may enumerate a blank paragraph as a sentence. It
            // must not evict spoken text from the three-sentence preview.
            guard !fragment.isEmpty else { return }
            let current = prefix + fragment
            // Foundation can split common English titles such as "Dr." into
            // their own sentence. Keep the title with the name that follows it.
            let lastWord = current.split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? ""
            if ["dr.", "mr.", "mrs.", "ms.", "prof.", "sr.", "jr."].contains(lastWord) {
                prefix = current + " "
                return
            }
            prefix = ""
            sentences.append(current)
            if sentences.count > sentenceLimit { sentences.removeFirst() }
        }
        if !prefix.isEmpty {
            sentences.append(prefix.trimmingCharacters(in: .whitespacesAndNewlines))
            if sentences.count > sentenceLimit { sentences.removeFirst() }
        }
        let hasSentencePunctuation = candidate.contains { ".!?。！？".contains($0) }
        let preview: String
        if hasSentencePunctuation, !sentences.isEmpty {
            preview = sentences.joined(separator: " ")
        } else {
            // Realtime produces no automatic punctuation. Advance by words
            // instead of claiming these are three recognized sentences.
            preview = candidate.split(whereSeparator: \.isWhitespace).suffix(unpunctuatedWordLimit).joined(separator: " ")
        }
        return suffix(preview, maximumBytes: maximumUTF8Bytes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func suffix(_ text: String, maximumBytes: Int) -> String {
        var bytes = 0
        var beginning = text.endIndex
        // Character boundaries preserve emoji and combining marks when the
        // payload limit cuts a very long sentence or unpunctuated dictation.
        for character in text.reversed() {
            let size = String(character).utf8.count
            guard bytes + size <= maximumBytes else { break }
            bytes += size
            beginning = text.index(before: beginning)
        }
        return String(text[beginning...])
    }
}
