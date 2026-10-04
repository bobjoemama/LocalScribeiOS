import CryptoKit
import Foundation

struct ModelIntegrityManifest: Decodable, Sendable {
    struct Model: Decodable, Sendable {
        struct File: Decodable, Sendable {
            let path: String
            let size: Int64
            let remotePath: String?
            let sha256: String?
            let gitBlobSHA1: String
            init(path: String, size: Int64, remotePath: String? = nil, sha256: String?, gitBlobSHA1: String) {
                self.path = path; self.size = size; self.remotePath = remotePath; self.sha256 = sha256; self.gitBlobSHA1 = gitBlobSHA1
            }
        }
        let id: String
        let repository: String
        let revision: String
        let license: String
        let totalBytes: Int64
        let files: [File]
    }
    let models: [Model]

    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "model-integrity", withExtension: "json") else {
            throw ModelInstallationError.missingManifest
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

enum ModelInstallationError: LocalizedError {
    case missingManifest, missingModel, integrity(String), noRuntime
    var errorDescription: String? {
        switch self {
        case .missingManifest: "The model catalog is missing. Rebuild LocalScribe with its resources."
        case .missingModel: "Download this model from Models before dictating."
        case .integrity(let file): "Model verification failed for \(file). Download the model again."
        case .noRuntime: "The local speech runtime has not been added to this build yet."
        }
    }
}

/// Checks the publisher's pinned byte identity before Core ML loads a model.
/// Large weight files are hashed incrementally to keep peak memory bounded.
enum ModelIntegrity {
    static func verify(_ model: ModelIntegrityManifest.Model, at root: URL) throws {
        for file in model.files {
            try Task.checkCancellation()
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else {
                throw ModelInstallationError.integrity("invalid catalog path")
            }
            let url = root.appendingPathComponent(file.path)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attrs[.size] as? NSNumber)?.int64Value == file.size else {
                throw ModelInstallationError.integrity(file.path)
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var sha256 = SHA256()
            var gitSHA1 = Insecure.SHA1()
            if file.sha256 == nil { gitSHA1.update(data: Data("blob \(file.size)\0".utf8)) }
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                if file.sha256 != nil { sha256.update(data: data) }
                else { gitSHA1.update(data: data) }
            }
            let actual = file.sha256 != nil ? sha256.finalize().map { String(format: "%02x", $0) }.joined() : gitSHA1.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == (file.sha256 ?? file.gitBlobSHA1) else {
                throw ModelInstallationError.integrity(file.path)
            }
        }
    }
}
