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
    enum Category { case record, playAndRecord }
    enum Mode { case measurement }
    enum ErrorCode: Int {
        case cannotInterruptOthers = 560557684
        case cannotStartRecording = 561145187
        case insufficientPriority = 561017449
        case siriIsRecording = 1936290409
    }
    struct CategoryOptions: OptionSet {
        let rawValue: Int
        static let allowBluetoothHFP = Self(rawValue: 1)
        static let mixWithOthers = Self(rawValue: 2)
    }
    struct SetActiveOptions: OptionSet { let rawValue: Int; static let notifyOthersOnDeactivation = Self(rawValue: 1) }
    enum Port { case builtInMic }
    struct Input { let portType: Port }
    var availableInputs: [Input]? = [.init(portType: .builtInMic)]
    var active = false
    var failPreferredInput = false
    var activations = 0
    var deactivations = 0
    var background = false
    var forbidBackgroundRecording = false
    var category = Category.record
    var categoryOptions: CategoryOptions = []
    static func sharedInstance() -> AVAudioSession { instance }
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions) throws {
        self.category = category
        categoryOptions = options
    }
    func setAllowHapticsAndSystemSoundsDuringRecording(_ enabled: Bool) throws {}
    func setActive(_ active: Bool, options: SetActiveOptions = []) throws {
        if active, background {
            if !categoryOptions.contains(.mixWithOthers) {
                throw NSError(domain: NSOSStatusErrorDomain, code: ErrorCode.cannotInterruptOthers.rawValue)
            }
            if forbidBackgroundRecording {
                throw NSError(domain: NSOSStatusErrorDomain, code: ErrorCode.cannotStartRecording.rawValue)
            }
        }
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
        session.background = true
        do { try await recorder.arm(requireExistingPermission: true); throw FixtureFailure.failed("Nonmixable background session should fail") }
        catch RecordingError.audioSessionFailed(let code) {
            try check(code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue, "Background nonmixable failure preserves exact OS status")
        }
        try check(!session.active && !engine.isRunning && engine.inputNode.taps == 0, "Activation failure leaves no microphone or tap")
        try await recorder.arm(requireExistingPermission: true, mixWithOtherAudio: true)
        try check(session.active && engine.isRunning && engine.inputNode.taps == 1, "Mixable background activation reaches real recorder start")
        try check(session.category == .playAndRecord && session.categoryOptions.contains(.mixWithOthers), "Background policy uses a category supporting mixWithOthers")
        recorder.shutdown()
        session.forbidBackgroundRecording = true
        do { try await recorder.arm(requireExistingPermission: true, mixWithOtherAudio: true); throw FixtureFailure.failed("Mixing must not bypass recording denial") }
        catch RecordingError.audioSessionFailed(let code) {
            try check(code == AVAudioSession.ErrorCode.cannotStartRecording.rawValue, "Recording authorization denial stays distinct from mix failure")
            try check(RecordingError.audioSessionFailed(code: code).localizedDescription.contains("!rec"), "User can report the actual recording denial code")
        }
        try check(!session.active && !engine.isRunning && engine.inputNode.taps == 0, "Denied mixable session is completely cleaned up")
        session.background = false
        session.forbidBackgroundRecording = false
        var deliveredEvents = 0
        recorder.onInterruption = {
            deliveredEvents += 1
            _ = recorder.endCapture(keepEngineRunning: false)
        }
        let events: [(Notification.Name, [String: UInt]?)] = [
            (AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]),
            (AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]),
            (AVAudioSession.mediaServicesWereResetNotification, nil)
        ]
        for (name, info) in events {
            // The notification queues its actor delivery while A owns capture.
            // End A and begin B synchronously under the same keyboard activation.
            try await recorder.arm(requireExistingPermission: true)
            recorder.beginCapture()
            let before = deliveredEvents
            NotificationCenter.default.post(name: name, object: nil, userInfo: info)
            _ = recorder.endCapture(keepEngineRunning: true)
            recorder.beginCapture()
            let replacementGeneration = recorder.captureSnapshot.generation
            for _ in 0..<10 { await Task.yield() }
            try check(deliveredEvents == before && recorder.captureSnapshot.generation == replacementGeneration && engine.isRunning,
                      "Late \(name.rawValue) from capture A cannot stop B on the same activation")

            NotificationCenter.default.post(name: name, object: nil, userInfo: info)
            for _ in 0..<10 { await Task.yield() }
            try check(deliveredEvents == before + 1 && !engine.isRunning && recorder.captureSnapshot.generation == nil,
                      "Current \(name.rawValue) still stops B capture")

            try await recorder.arm(requireExistingPermission: true)
            NotificationCenter.default.post(name: name, object: nil, userInfo: info)
            recorder.beginCapture()
            for _ in 0..<10 { await Task.yield() }
            try check(deliveredEvents == before + 1 && engine.isRunning && recorder.captureSnapshot.generation != nil,
                      "Queued idle-keyboard \(name.rawValue) cannot stop a newly begun capture")
            _ = recorder.endCapture(keepEngineRunning: true)

            NotificationCenter.default.post(name: name, object: nil, userInfo: info)
            for _ in 0..<10 { await Task.yield() }
            try check(deliveredEvents == before + 2 && !engine.isRunning,
                      "Current idle-keyboard \(name.rawValue) still retires its microphone lease")

            try await recorder.arm(requireExistingPermission: true)
            recorder.beginCapture()
            // The platform can post from an audio worker. Observe on that thread
            // before the MainActor hop, rather than first queueing observer delivery.
            DispatchQueue.global().sync {
                NotificationCenter.default.post(name: name, object: nil, userInfo: info)
            }
            recorder.shutdown()
            try await recorder.arm(requireExistingPermission: true)
            recorder.beginCapture()
            for _ in 0..<10 { await Task.yield() }
            try check(deliveredEvents == before + 2 && engine.isRunning && recorder.captureSnapshot.generation != nil,
                      "Shutdown invalidates queued \(name.rawValue) before replacement activation")
            recorder.shutdown()

            NotificationCenter.default.post(name: name, object: nil, userInfo: info)
            try await recorder.arm(requireExistingPermission: true)
            recorder.beginCapture()
            for _ in 0..<10 { await Task.yield() }
            try check(deliveredEvents == before + 2 && engine.isRunning,
                      "Unarmed \(name.rawValue) cannot become a future capture's event")
            recorder.shutdown()
        }
        print("PASS: \(checks) production AudioRecorder lifecycle checks")
    }
}
