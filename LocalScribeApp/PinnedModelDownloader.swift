import Foundation

/// Installs alternate exact-weight encoder graphs without a second inference stack.
/// Files come from immutable public HF revisions, then ModelIntegrity checks every byte.
enum PinnedModelDownloader {
    static func download(_ model: ModelIntegrityManifest.Model, to root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1_800
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var completed: Int64 = 0
        for file in model.files {
            try Task.checkCancellation()
            let source = file.remotePath ?? file.path
            guard !source.hasPrefix("/"), !source.split(separator: "/").contains(".."), !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else {
                throw ModelInstallationError.integrity("invalid download path")
            }
            guard let url = URL(string: "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(source)") else { throw ModelInstallationError.missingManifest }
            let delegate = FileDownloadProgress(completed: completed, fileSize: file.size, total: model.totalBytes, progress: progress)
            let (temporary, response) = try await session.download(from: url, delegate: delegate)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ModelInstallationError.integrity("download returned an error") }
            let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value
            guard size == file.size else { throw ModelInstallationError.integrity(file.path) }
            let destination = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomically replace only this explicit installation's own managed file.
            // A stopped/corrupt install has no verification marker and cannot be loaded.
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
            completed += file.size
            progress(0.95 * Double(completed) / Double(model.totalBytes))
        }
    }
}

private final class FileDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let completed: Int64
    private let fileSize: Int64
    private let total: Int64
    private let progress: @Sendable (Double) -> Void
    init(completed: Int64, fileSize: Int64, total: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.completed = completed; self.fileSize = fileSize; self.total = total; self.progress = progress
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard total > 0 else { return }
        progress(0.95 * Double(completed + min(fileSize, totalBytesWritten)) / Double(total))
    }
}
