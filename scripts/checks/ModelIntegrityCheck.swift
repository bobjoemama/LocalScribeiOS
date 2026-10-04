import CryptoKit
import Foundation

@main struct IntegrityChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("localscribe-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("a local model payload".utf8)
        let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let gitSHA1 = Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8) + bytes).map { String(format: "%02x", $0) }.joined()
        func entry(path: String = "weight.bin", sha256 hash: String? = nil, size: Int? = nil) -> ModelIntegrityManifest.Model {
            .init(id: "test", repository: "test/model", revision: "pinned", license: "test", totalBytes: Int64(bytes.count), files: [.init(path: path, size: Int64(size ?? bytes.count), sha256: hash, gitBlobSHA1: gitSHA1)])
        }
        try bytes.write(to: root.appendingPathComponent("weight.bin"))
        try ModelIntegrity.verify(entry(sha256: sha256), at: root)
        try ModelIntegrity.verify(entry(), at: root)
        func mustReject(_ model: ModelIntegrityManifest.Model) throws {
            do { try ModelIntegrity.verify(model, at: root); fatalError("Accepted invalid model") }
            catch is ModelInstallationError { }
        }
        try mustReject(entry(sha256: String(repeating: "0", count: 64)))
        try mustReject(entry(size: bytes.count + 1))
        try mustReject(entry(path: "../weight.bin"))
        var tampered = bytes
        tampered[0] = 0
        try tampered.write(to: root.appendingPathComponent("weight.bin"))
        try mustReject(entry())
        let manifest = try JSONDecoder().decode(ModelIntegrityManifest.self, from: Data(contentsOf: URL(fileURLWithPath: "Resources/model-integrity.json")))
        precondition(manifest.models.count == 5)
        for model in manifest.models {
            precondition(model.revision.count == 40 && model.files.count == 18)
            precondition(model.files.reduce(Int64(0)) { $0 + $1.size } == model.totalBytes)
            precondition(Set(model.files.map(\.path)).count == model.files.count)
        }
        print("PASS: SHA256, Git blob identity, tampering, truncation, path traversal, pinned catalog totals")
    }
}
