import Combine
import Foundation
import LocalScribeCore

@MainActor
final class ProfilingReportStore: ObservableObject {
    @Published private(set) var report: ProfilingReport?
    func load(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw ProfilingReport.ReportError.invalid }
        guard let stream = InputStream(url: url) else { throw ProfilingReport.ReportError.invalid }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw ProfilingReport.ReportError.invalid }
            if count == 0 { break }
            guard data.count + count <= 1_048_576 else { throw ProfilingReport.ReportError.invalid }
            data.append(contentsOf: buffer.prefix(count))
        }
        let value = try ProfilingReport.decode(data)
        report = value
    }
    func clear() { report = nil }
}
