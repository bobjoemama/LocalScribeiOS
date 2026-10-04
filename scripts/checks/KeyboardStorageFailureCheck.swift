import Combine
import Foundation

// A controller fixture exercises the actual coordinator without microphone/model hardware.
@MainActor
final class AppController: ObservableObject {
    enum Phase { case idle, preparing, recording, transcribing }
    @Published var phase: Phase = .idle
    @Published var transcript = ""
    @Published var keyboardSessionExpiresAt: Date?
    @Published var errorMessage: String?
    var onDictationFinished: (() -> Void)?
    var keyboardBridge: KeyboardSessionCoordinator?
    var finishCount = 0
    var keyboardSessionActive: Bool { keyboardSessionExpiresAt.map { $0 > Date() } ?? false }

    func startRecording() async { transcript = ""; phase = .recording }
    func stopRecording() async {
        phase = .transcribing
        transcript = "Captured words remain in the app."
        phase = .idle
        onDictationFinished?()
    }
    func disableKeyboardSession() { keyboardSessionExpiresAt = nil }
    func finishKeyboardSession() async {
        finishCount += 1
        if phase == .recording { await stopRecording() }
        disableKeyboardSession()
    }
}

#if os(macOS)
extension SharedKeyboardStore {
    static func appGroupStore() throws -> SharedKeyboardStore { throw StoreError.unavailable }
}
#endif

@main
struct KeyboardStorageFailureCheck {
    enum CheckFailure: Error { case failed(String) }
    @MainActor static var count = 0

    @MainActor
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure.failed(message) }
        count += 1
    }

    @MainActor
    static func main() async throws {
        let appOnly = AppController()
        appOnly.keyboardBridge = KeyboardSessionCoordinator(controller: appOnly, store: nil)
        try check(appOnly.errorMessage == nil, "Optional unavailable keyboard does not interrupt app startup")
        appOnly.keyboardSessionExpiresAt = Date().addingTimeInterval(300)
        for _ in 0..<30 {
            if appOnly.keyboardSessionExpiresAt == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(appOnly.keyboardSessionExpiresAt == nil, "Missing group prevents microphone session authorization")
        try check(appOnly.errorMessage?.contains("shared access failed") == true, "Missing group is reported when requested")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalScribeStorageFailureCheck-\(UUID().uuidString)", isDirectory: true)
        let store = try SharedKeyboardStore(directory: directory)
        let controller = AppController()
        controller.keyboardBridge = KeyboardSessionCoordinator(controller: controller, store: store)
        controller.keyboardSessionExpiresAt = Date().addingTimeInterval(300)
        guard let status = try store.readStatus(), let sessionID = status.sessionID else { throw CheckFailure.failed("Initial session was not published") }
        try store.writeCommand(KeyboardCommand(sessionID: sessionID, utteranceID: UUID(), action: .start))
        for _ in 0..<30 {
            if controller.phase == .recording { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try check(controller.phase == .recording, "Fixture recording is owned by the actual coordinator")

        // Replace the status destination with a directory so atomic writes reliably fail,
        // independent of filesystem user privileges. Preserve every artifact by moving it.
        let bridgeDirectory = directory.appendingPathComponent("KeyboardBridge")
        let statusURL = bridgeDirectory.appendingPathComponent("status.json")
        try FileManager.default.moveItem(at: statusURL, to: bridgeDirectory.appendingPathComponent("status.before-failure.json"))
        try FileManager.default.createDirectory(at: statusURL, withIntermediateDirectories: false)
        await controller.stopRecording()
        // The exact regression: publishing a completed owned result fails, and revoking
        // the lease invokes the @Published sink. This must neither recurse nor republish.
        for _ in 0..<30 {
            if controller.keyboardSessionExpiresAt == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(controller.keyboardSessionExpiresAt == nil, "Storage failure revokes microphone authorization")
        try check(controller.finishCount == 1, "Storage failure requests one finite microphone stop")
        try check(controller.transcript == "Captured words remain in the app.", "Captured text remains available in the app")
        try check(controller.errorMessage?.contains("shared access failed") == true, "Failure remains visible to the user")

        // Repair the destination, then attempt a new arm. Terminal failure must not write
        // again or revive a heartbeat/result, even through controller callback emissions.
        try FileManager.default.moveItem(at: statusURL, to: bridgeDirectory.appendingPathComponent("status.blocked"))
        let sentinel = KeyboardSessionStatus(heartbeatAt: Date(timeIntervalSince1970: 42), message: "Sentinel must remain untouched")
        try store.writeStatus(sentinel)
        controller.keyboardSessionExpiresAt = Date().addingTimeInterval(300)
        for _ in 0..<30 {
            if controller.keyboardSessionExpiresAt == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.onDictationFinished?()
        try await Task.sleep(for: .milliseconds(600))
        try check(controller.keyboardSessionExpiresAt == nil, "Subsequent arm is revoked after its willSet assignment")
        try check(controller.finishCount == 2, "Subsequent arm requests a single stop")
        try check(try store.readStatus() == sentinel, "Terminal failure never republishes after destination repair")
        print("PASS: \(count) keyboard storage failure checks (completed-result failure, nonrecursive revocation, transcript preservation, willSet rearm and terminal writes)")
    }
}
