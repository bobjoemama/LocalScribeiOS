import Foundation

/// Word-level Levenshtein error counts against a human-supplied reference.
public struct WordErrorRateResult: Codable, Equatable, Sendable {
    public let referenceWordCount: Int
    public let hypothesisWordCount: Int
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int

    public var errorCount: Int { substitutions + deletions + insertions }
    /// Undefined for an empty reference, including when both strings are empty.
    /// Insertions can make WER greater than 1; the result is never clamped.
    public var rate: Double? {
        referenceWordCount > 0 ? Double(errorCount) / Double(referenceWordCount) : nil
    }
}

public enum WordErrorRate {
    /// This policy removes Unicode punctuation, folds case with a fixed locale,
    /// preserves accents, and splits on whitespace. Apostrophes and hyphens are
    /// removed within words: "can't" becomes "cant", "well-being" becomes "wellbeing".
    /// It does not expand numbers or contractions, or segment unspaced languages.
    public static func normalizedWords(_ text: String) -> [String] {
        let folded = text.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        return folded.split(whereSeparator: { $0.isWhitespace }).compactMap { token in
            let cleaned = String(String.UnicodeScalarView(token.unicodeScalars.filter {
                !CharacterSet.punctuationCharacters.contains($0)
            }))
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    public static func evaluate(reference: String, hypothesis: String) -> WordErrorRateResult {
        let expected = normalizedWords(reference)
        let actual = normalizedWords(hypothesis)
        // Two rows preserve the edit breakdown in O(hypothesis words) memory.
        var previous = (0...actual.count).map { Edits(insertions: $0) }
        for (referenceIndex, referenceWord) in expected.enumerated() {
            var current = [Edits(deletions: referenceIndex + 1)]
            current.reserveCapacity(actual.count + 1)
            for (hypothesisIndex, hypothesisWord) in actual.enumerated() {
                if referenceWord == hypothesisWord {
                    current.append(previous[hypothesisIndex])
                } else {
                    let substitution = previous[hypothesisIndex].adding(substitutions: 1)
                    let deletion = previous[hypothesisIndex + 1].adding(deletions: 1)
                    let insertion = current[hypothesisIndex].adding(insertions: 1)
                    // Stable ties prefer substitution, then deletion, then insertion.
                    var best = substitution
                    if deletion.count < best.count { best = deletion }
                    if insertion.count < best.count { best = insertion }
                    current.append(best)
                }
            }
            previous = current
        }
        let edits = previous[actual.count]
        return WordErrorRateResult(referenceWordCount: expected.count,
                                   hypothesisWordCount: actual.count,
                                   substitutions: edits.substitutions,
                                   deletions: edits.deletions,
                                   insertions: edits.insertions)
    }

    private struct Edits {
        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var count: Int { substitutions + deletions + insertions }
        func adding(substitutions: Int = 0, deletions: Int = 0, insertions: Int = 0) -> Edits {
            Edits(substitutions: self.substitutions + substitutions,
                  deletions: self.deletions + deletions,
                  insertions: self.insertions + insertions)
        }
    }
}
