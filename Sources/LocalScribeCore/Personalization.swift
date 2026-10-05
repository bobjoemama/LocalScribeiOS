import Foundation

public struct SpokenSnippet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), trigger: String, expansion: String, isEnabled: Bool = true) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.isEnabled = isEnabled
    }
    private enum CodingKeys: String, CodingKey { case id, trigger, expansion, isEnabled }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        trigger = try values.decode(String.self, forKey: .trigger)
        expansion = try values.decode(String.self, forKey: .expansion)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

public enum PersonalizationValidation {
    public enum Failure: LocalizedError, Equatable, Sendable {
        case emptyTrigger, nonlexicalTrigger, emptyExpansion, duplicateTrigger
        public var errorDescription: String? {
            switch self {
            case .emptyTrigger: "Enter a spoken word or phrase."
            case .nonlexicalTrigger: "The spoken phrase must contain a letter or number."
            case .emptyExpansion: "Enter the replacement text."
            case .duplicateTrigger: "This spoken phrase already exists in your dictionary or snippets."
            }
        }
    }
    public static func validate(rule: DictionaryRule, dictionary: [DictionaryRule], snippets: [SpokenSnippet], excludingID: UUID? = nil) throws {
        try validateFields(trigger: rule.heard, expansion: rule.replacement,
                           existing: dictionary.filter { $0.id != excludingID }.map(\.heard) + snippets.map(\.trigger))
    }
    public static func validate(snippet: SpokenSnippet, dictionary: [DictionaryRule], snippets: [SpokenSnippet], excludingID: UUID? = nil) throws {
        try validateFields(trigger: snippet.trigger, expansion: snippet.expansion,
                           existing: dictionary.map(\.heard) + snippets.filter { $0.id != excludingID }.map(\.trigger))
    }
    private static func validateFields(trigger: String, expansion: String, existing: [String]) throws {
        let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { throw Failure.emptyTrigger }
        guard trigger.range(of: "[\\p{L}\\p{N}]", options: .regularExpression) != nil else { throw Failure.nonlexicalTrigger }
        guard !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptyExpansion }
        guard !existing.contains(where: { folded($0) == folded(trigger) }) else { throw Failure.duplicateTrigger }
    }
    fileprivate static func folded(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Deterministic local text substitutions, compiled when the user's rules change.
/// Matching uses original text once; expansions never become new matching input.
public struct TranscriptPersonalizer: Sendable {
    private struct Entry: Sendable { let trigger: String; let expansion: String; let ordinal: Int }
    private let entries: [Entry]
    private let regex: NSRegularExpression?
    private let wholeSnippets: [String: String]

    public init(dictionary: [DictionaryRule], snippets: [SpokenSnippet]) {
        var whole: [String: String] = [:]
        for snippet in snippets where snippet.isEnabled {
            let key = PersonalizationValidation.folded(snippet.trigger)
            guard !key.isEmpty, whole[key] == nil else { continue }
            whole[key] = snippet.expansion
        }
        wholeSnippets = whole
        let candidates = dictionary.filter(\.isEnabled).map { ($0.heard, $0.replacement) }
            + snippets.filter(\.isEnabled).map { ($0.trigger, $0.expansion) }
        var seen = Set<String>()
        entries = candidates.enumerated().compactMap { ordinal, candidate in
            let trigger = candidate.0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty, seen.insert(PersonalizationValidation.folded(trigger)).inserted else { return nil }
            return Entry(trigger: trigger, expansion: candidate.1, ordinal: ordinal)
        }.sorted {
            $0.trigger.count == $1.trigger.count ? $0.ordinal < $1.ordinal : $0.trigger.count > $1.trigger.count
        }
        let alternatives = entries.map { entry in
            // Possessives are legal boundaries. A trigger ending in n must not
            // partially rewrite n't contractions, including curly apostrophes.
            let contractionFence = entry.trigger.lowercased().hasSuffix("n") ? "(?!['’‘ʼ＇`´‛′ʹ]t)" : ""
            return "(" + Self.literalPattern(for: entry.trigger) + ")" + contractionFence
        }
        if alternatives.isEmpty { regex = nil }
        else {
            regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{M}\\p{N}_])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{M}\\p{N}_])", options: .caseInsensitive)
        }
    }

    private static func literalPattern(for phrase: String) -> String {
        // Accept both standard Unicode representations of each saved grapheme.
        // Noncapturing alternatives keep entry capture indices stable. Matching
        // still happens against the original text, preserving untouched bytes.
        phrase.map { character in
            let value = String(character)
            let forms = [value, value.precomposedStringWithCanonicalMapping, value.decomposedStringWithCanonicalMapping]
            var seen = Set<[UInt16]>()
            let alternatives = forms.filter { seen.insert(Array($0.utf16)).inserted }
                .map { NSRegularExpression.escapedPattern(for: $0) }
            return alternatives.count == 1 ? alternatives[0] : "(?:" + alternatives.joined(separator: "|") + ")"
        }.joined()
    }

    public func apply(_ text: String) -> String {
        // A whole dictated snippet returns precisely its saved text. Recognizers
        // commonly append sentence punctuation that would corrupt an email,
        // signature, or code expansion. Inline substitutions retain that context.
        var wholePhrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let expansion = wholeSnippets[PersonalizationValidation.folded(wholePhrase)] { return expansion }
        let terminators = CharacterSet(charactersIn: ".!?。！？")
        while let last = wholePhrase.unicodeScalars.last, terminators.contains(last) {
            wholePhrase.removeLast()
            wholePhrase = wholePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
            if let expansion = wholeSnippets[PersonalizationValidation.folded(wholePhrase)] { return expansion }
        }
        guard let regex else { return text }
        let original = text as NSString
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            // Each escaped alternative owns one capture group, identifying the
            // literal saved expansion even when Unicode case folding changes length.
            for index in entries.indices where match.range(at: index + 1).location != NSNotFound {
                result.replaceCharacters(in: match.range, with: entries[index].expansion)
                break
            }
        }
        return result as String
    }
}

public struct SnippetStore: Sendable {
    public let file: URL
    public init(file: URL) { self.file = file }
    public func load() throws -> [SpokenSnippet] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([SpokenSnippet].self, from: Data(contentsOf: file))
    }
    public func save(_ snippets: [SpokenSnippet]) throws {
        // Preserve a corrupt existing file rather than replacing it with defaults.
        // The app also keeps its loaded library read-only after a storage failure.
        _ = try load()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snippets)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        var protectedFile = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedFile.setResourceValues(values)
    }
}
