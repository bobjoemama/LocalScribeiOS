import Foundation

public struct NoteEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var text: String

    public init(id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date? = nil, text: String = "") {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.text = text
    }

    public var title: String {
        let line = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line.map { String($0.prefix(80)) } ?? "Untitled note"
    }

    public var preview: String {
        let lines = text.components(separatedBy: .newlines)
        guard let titleLine = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        return lines.dropFirst(titleLine + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Preserve typed whitespace. Dictation starts a new line when text already exists.
    public mutating func appendDictation(_ dictatedText: String, at date: Date = Date()) {
        guard !dictatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !text.isEmpty, !text.hasSuffix("\n"), !text.hasSuffix("\r") { text += "\n" }
        text += dictatedText
        updatedAt = max(createdAt, date)
    }
}

public enum NoteStoreError: LocalizedError {
    case unsupportedFormat, duplicateIdentifier
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "The notes file uses an unsupported format. The existing file has been preserved."
        case .duplicateIdentifier: "The notes file contains duplicate identifiers. The existing file has been preserved."
        }
    }
}

/// One serialized local store. Validate existing data before replacing it, and
/// write atomically so a failed write cannot truncate an earlier saved note.
public actor NoteStore {
    public let file: URL
    private struct Document: Codable {
        let version: Int
        let notes: [NoteEntry]
    }
    private struct Header: Decodable { let version: Int }
    public init(file: URL) { self.file = file }

    public static func emptyData() throws -> Data {
        try JSONEncoder().encode(Document(version: 2, notes: []))
    }

    public func load() throws -> [NoteEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try decode(Data(contentsOf: file))
    }

    public func save(_ notes: [NoteEntry]) throws {
        try validate(notes)
        // This check also protects a store instance whose caller skipped load().
        if FileManager.default.fileExists(atPath: file.path) { _ = try load() }
        let encoder = JSONEncoder()
        // Date's native reference-date Double round-trips exactly. Converting
        // through epoch milliseconds loses precision for real Date() values.
        encoder.dateEncodingStrategy = .deferredToDate
        let data = try encoder.encode(Document(version: 2, notes: notes))
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excludedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(values)
        #if os(iOS)
        // Match history protection. A locked-device save may fail; callers keep
        // the pending draft and retry after unlock rather than weakening protection.
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }

    private func decode(_ data: Data) throws -> [NoteEntry] {
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        switch header.version {
        case 1: decoder.dateDecodingStrategy = .millisecondsSince1970
        case 2: decoder.dateDecodingStrategy = .deferredToDate
        default: throw NoteStoreError.unsupportedFormat
        }
        let document = try decoder.decode(Document.self, from: data)
        try validate(document.notes)
        return document.notes
    }
    private func validate(_ notes: [NoteEntry]) throws {
        guard Set(notes.map(\.id)).count == notes.count else { throw NoteStoreError.duplicateIdentifier }
    }
}
