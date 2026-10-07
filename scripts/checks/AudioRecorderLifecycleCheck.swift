import AVFoundation
import Foundation
import LocalScribeCore

// Exercise the production AudioRecorder with deterministic permission/session/engine
// boundaries. Real AVAudioFormat and AVAudioConverter are retained; no mic is opened.
struct FixtureAudioApplication {
    enum Permission { case granted, denied }
    var recordPermission = Permission.granted
}
@MainActor enum AVAudioApplication {
    static var shared = FixtureAudioApplication()
    static var continuation: CheckedContinuation<Bool, Never>?
    static var holdPermission = false
    static func requestRecordPermission() async -> Bool {
        if holdPermission {
            holdPermission = false
            return await withCheckedContinuation { continuation = $0 }
        }
        return true
    }
}
@MainActor final class AVAudioSession {
    static let instance = AVAudioSession()
    nonisolated static let interruptionNotification = Notification.Name("RecorderFixtureInterruption")
    nonisolated static let routeChangeNotification = Notification.Name("RecorderFixtureRouteChange")
    nonisolated static let mediaServicesWereResetNotification = Notification.Name("RecorderFixtureReset")
    enum InterruptionType: UInt { case began = 1 }
    enum RouteChangeReason: UInt { case oldDeviceUnavailable = 1 }
    enum Category { case record }
    enum Mode { case measurement }
    struct CategoryOptions: OptionSet { let rawValue: Int; static let allowBluetoothHFP = Self(rawValue: 1) }
    struct SetActiveOptions: OptionSet { let rawValue: Int; static let notifyOthersOnDeactivation = Self(rawValue: 1) }
    enum Port { case builtInMic }
    struct Input { let portType: Port }
    var availableInputs: [Input]? = [.init(portType: .builtInMic)]
    var active = false
    var failPreferredInput = false
    var activations = 0
    var deactivations = 0
    static func sharedInstance() -> AVAudioSession { instance }
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions) throws {}
    func setAllowHapticsAndSystemSoundsDuringRecording(_ enabled: Bool) throws {}
    func setActive(_ active: Bool, options: SetActiveOptions = []) throws {
        self.active = active
        if active { activations += 1 } else { deactivations += 1 }
    }
    func setPreferredInput(_ input: Input?) throws {
        if failPreferredInput { throw FixtureFailure.expected }
    }
}
let AVAudioSessionInterruptionTypeKey = "type"
let AVAudioSessionRouteChangeReasonKey = "reason"
@MainActor final class AVAudioEngine {
    static var engines: [AVAudioEngine] = []
    let inputNode = FixtureInputNode()
    var isRunning = false
    init() { Self.engines.append(self) }
    func prepare() {}
    func start() throws { isRunning = true }
    func stop() { isRunning = false }
}
@MainActor final class FixtureInputNode {
    var taps = 0
    func outputFormat(forBus bus: Int) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    }
    func installTap(onBus bus: Int, bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        precondition(taps == 0, "A second arm cannot install a duplicate tap")
        taps += 1
    }
    func removeTap(onBus bus: Int) { taps -= 1 }
}
enum FixtureFailure: Error { case expected, failed(String) }
@main struct AudioRecorderLifecycleCheck {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw FixtureFailure.failed(message) }
        checks += 1
    }
    @MainActor static func main() async throws {
        let session = AVAudioSession.sharedInstance()
        let recorder = AudioRecorder()
        let engine = AVAudioEngine.engines.last!
        AVAudioApplication.shared.recordPermission = .denied
        AVAudioApplication.holdPermission = true
        do { try await recorder.arm(requireExistingPermission: true); throw FixtureFailure.failed("Background arm should reject missing grant") }
        catch RecordingError.microphoneDenied {}
        try check(AVAudioApplication.continuation == nil && !session.active, "Background arm never asks for microphone permission")
        AVAudioApplication.shared.recordPermission = .granted
        AVAudioApplication.holdPermission = false
        session.failPreferredInput = true
        do { try await recorder.arm(); throw FixtureFailure.failed("Expected input-selection failure") }
        catch FixtureFailure.expected {}
        try check(!session.active, "A failure after session activation deactivates it")
        try check(!engine.isRunning && engine.inputNode.taps == 0, "Setup failure leaves no running engine or tap")
        session.failPreferredInput = false
        let activationCount = session.activations
        AVAudioApplication.holdPermission = true
        let staleArm = Task { try await recorder.arm() }
        while AVAudioApplication.continuation == nil { await Task.yield() }
        recorder.shutdown()
        AVAudioApplication.continuation?.resume(returning: true)
        AVAudioApplication.continuation = nil
        do { try await staleArm.value; throw FixtureFailure.failed("Expected stale activation cancellation") }
        catch is CancellationError {}
        try check(session.activations == activationCount && !session.active, "Canceled permission response cannot activate the audio session")
        try check(!engine.isRunning && engine.inputNode.taps == 0, "Canceled permission response cannot install an input tap")
        try await recorder.arm()
        try check(session.active && engine.isRunning && engine.inputNode.taps == 1, "A fresh retry can record after cancellation")
        try await recorder.arm()
        try check(engine.inputNode.taps == 1, "Arming an already running recorder remains idempotent")
        recorder.shutdown()
        try check(!session.active && !engine.isRunning && engine.inputNode.taps == 0, "Shutdown retires the audio engine and tap")
        AVAudioApplication.holdPermission = true
        let supersededArm = Task { try await recorder.arm() }
        while AVAudioApplication.continuation == nil { await Task.yield() }
        recorder.shutdown()
        try await recorder.arm()
        AVAudioApplication.continuation?.resume(returning: true)
        AVAudioApplication.continuation = nil
        do { try await supersededArm.value; throw FixtureFailure.failed("Expected superseded arm cancellation") }
        catch is CancellationError {}
        try check(session.active && engine.isRunning && engine.inputNode.taps == 1, "A stale permission reply cannot replace or retire a newer recording")
        recorder.shutdown()
        AVAudioApplication.holdPermission = true
        let canceledTask = Task { try await recorder.arm() }
        while AVAudioApplication.continuation == nil { await Task.yield() }
        canceledTask.cancel()
        AVAudioApplication.continuation?.resume(returning: true)
        AVAudioApplication.continuation = nil
        do { try await canceledTask.value; throw FixtureFailure.failed("Expected task cancellation") }
        catch is CancellationError {}
        try check(!session.active && !engine.isRunning && engine.inputNode.taps == 0, "Task cancellation alone prevents session activation after permission")
        print("PASS: \(checks) production AudioRecorder lifecycle checks")
    }
}
