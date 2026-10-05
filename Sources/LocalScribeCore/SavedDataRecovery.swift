import Foundation

public enum SavedDataCollection: String, CaseIterable, Identifiable, Sendable {
    case history, dictionary, snippets, notes
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// Explicit user recovery bypasses decoding a broken file, preserving its exact
/// bytes before an atomic replacement. Models and preferences are never touched.
public enum SavedDataRecovery {
    @discardableResult public static func reset(file: URL, emptyData: Data) throws -> URL? {
        let manager = FileManager.default
        let directory = file.deletingLastPathComponent()
        let original =
            manager.fileExists(atPath: file.path)
            ? try Data(contentsOf: file, options: .mappedIfSafe) : nil
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Exclude the directory before committing replacement, so a metadata
        // failure cannot report failure after the saved data already changed.
        try excludeFromBackup(directory)
        var backup: URL?
        if let original {
            let copies = directory.appendingPathComponent("Recovery", isDirectory: true)
            try manager.createDirectory(at: copies, withIntermediateDirectories: true)
            try excludeFromBackup(copies)
            let target = copies.appendingPathComponent(
                "\(file.deletingPathExtension().lastPathComponent)-\(Int(Date().timeIntervalSince1970))-\(UUID()).json")
            try write(original, to: target)
            try excludeFromBackup(target)
            backup = target
        }
        try write(emptyData, to: file)
        return backup
    }

    public static func backups(for file: URL) throws -> [URL] {
        let directory = file.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let prefix = file.deletingPathExtension().lastPathComponent + "-"
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        )
        .filter {
            guard $0.lastPathComponent.hasPrefix(prefix), $0.pathExtension == "json" else { return false }
            return try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func write(_ data: Data, to file: URL) throws {
        #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
            try data.write(to: file, options: .atomic)
        #endif
    }
    private static func excludeFromBackup(_ file: URL) throws {
        var url = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
