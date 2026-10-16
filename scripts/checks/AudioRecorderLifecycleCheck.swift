import AVFoundation
import Foundation
import LocalScribeCore

// Exercise the production AudioRecorder with deterministic permission/session/engine
// boundaries and controlled actor-hop delivery. Real AVAudioFormat and
// AVAudioConverter are retained; no mic is opened.
final class FixtureAudioCallbacks: @unchecked Sendable {
    private static let shared = FixtureAudioCallbacks()
    private let lock = NSLock()
    private var callbacks: [@MainActor @Sendable () -> Void] = []
    nonisolated static func enqueue(_ callback: @escaping @MainActor @Sendable () -> Void) {
        shared.lock.withLock { shared.callbacks.append(callback) }
    }
    @MainActor static func drain() {
        while let callback = shared.lock.withLock({ shared.callbacks.isEmpty ? nil : shared.callbacks.removeFirst() }) {
            callback()
        }
    }
}

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
    enum Category: String { case record = "AVAudioSessionCategoryRecord", playAndRecord = "AVAudioSessionCategoryPlayAndRecord" }
    enum Mode: String { case measurement = "AVAudioSessionModeMeasurement" }
    enum ErrorCode: Int {
        case cannotInterruptOthers = 560557684
        case cannotStartRecording = 561145187
        case cannotStartPlaying = 561015905
        case insufficientPriority = 561017449
        case siriIsRecording = 1936290409
    }
    struct CategoryOptions: OptionSet {
        let rawValue: UInt
        static let allowBluetoothHFP = Self(rawValue: 4)
        static let mixWithOthers = Self(rawValue: 1)
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
    var activationErrorCode: Int?
    var rejectedStep: String?
    var omitMixOption = false
    var resetConfigurationOnDeactivate = false
    var category = Category.record
    var mode = Mode.measurement
    var categoryOptions: CategoryOptions = []
    static func sharedInstance() -> AVAudioSession { instance }
    func reject(_ step: String) throws {
        if rejectedStep == step { throw NSError(domain: NSOSStatusErrorDomain, code: 561015905) }
    }
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions) throws {
        try reject("category")
        self.category = category
        self.mode = mode
        categoryOptions = omitMixOption ? options.subtracting(.mixWithOthers) : options
    }
    func setAllowHapticsAndSystemSoundsDuringRecording(_ enabled: Bool) throws { try reject("sounds") }
    func setActive(_ active: Bool, options: SetActiveOptions = []) throws {
        if active { try reject("activation") }
        if active, let activationErrorCode {
            throw NSError(domain: NSOSStatusErrorDomain, code: activationErrorCode)
        }
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
        if !active, resetConfigurationOnDeactivate { category = .record; mode = .measurement; categoryOptions = [] }
    }
    func setPreferredInput(_ input: Input?) throws {
        try reject("input")
        if failPreferredInput { throw FixtureFailure.expected }
    }
}
let AVAudioSessionInterruptionTypeKey = "type"
let AVAudioSessionRouteChangeReasonKey = "reason"
@MainActor final class AVAudioEngine {
    static var engines: [AVAudioEngine] = []
    let inputNode = FixtureInputNode()
    var isRunning = false
    var failStart = false
    var startError: (any Error)?
    var invalidated = false
    init() { Self.engines.append(self) }
    func prepare() {}
    func start() throws {
        if let startError { throw startError }
        if invalidated { throw FixtureFailure.failed("Reused an audio engine orphaned by media reset") }
        if failStart { throw NSError(domain: NSOSStatusErrorDomain, code: 561015905) }
        isRunning = true
    }
    func stop() { isRunning = false }
}
@MainActor final class FixtureInputNode {
    var taps = 0
    private var tap: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    func emitSamples() {
        let format = outputFormat(forBus: 0)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = 0.25 }
        tap?(buffer, AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
    }
    func outputFormat(forBus bus: Int) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    }
    func installTap(onBus bus: Int, bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        precondition(taps == 0, "A second arm cannot install a duplicate tap")
        taps += 1
        tap = block
    }
    func removeTap(onBus bus: Int) { taps -= 1; tap = nil }
}
enum FixtureFailure: Error { case expected, failed(String) }
@main struct AudioRecorderLifecycleCheck {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw FixtureFailure.failed(message) }
        checks += 1
    }
    nonisolated static func post(_ name: Notification.Name, info: [String: UInt]?) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: info)
    }
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        let session = AVAudioSession.sharedInstance()
        let recorder = AudioRecorder()
        var engine = AVAudioEngine.engines.last!
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
        try check(session.category == .record && session.mode == .measurement && session.categoryOptions.rawValue == 4,
                  "Normal capture retains record/measurement with Bluetooth HFP")
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
        catch RecordingError.audioSessionFailed(let code, _) {
            try check(code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue, "Background nonmixable failure preserves exact OS status")
        }
        try check(!session.active && !engine.isRunning && engine.inputNode.taps == 0, "Activation failure leaves no microphone or tap")
        try await recorder.arm(requireExistingPermission: true, mixWithOtherAudio: true)
        try check(session.active && engine.isRunning && engine.inputNode.taps == 1, "Mixable background activation reaches real recorder start")
        try check(session.category == .playAndRecord && session.mode == .measurement && session.categoryOptions.rawValue == 5,
                  "Action capture retains playAndRecord/measurement with mixing and Bluetooth HFP")
        recorder.shutdown()
        session.forbidBackgroundRecording = true
        do { try await recorder.arm(requireExistingPermission: true, mixWithOtherAudio: true); throw FixtureFailure.failed("Mixing must not bypass recording denial") }
        catch RecordingError.audioSessionFailed(let code, _) {
            try check(code == AVAudioSession.ErrorCode.cannotStartRecording.rawValue, "Recording authorization denial stays distinct from mix failure")
            try check(RecordingError.audioSessionFailed(code: code).localizedDescription.contains("!rec"), "User can report the actual recording denial code")
        }
        try check(!session.active && !engine.isRunning && engine.inputNode.taps == 0, "Denied mixable session is completely cleaned up")
        session.background = false
        session.forbidBackgroundRecording = false
        session.activationErrorCode = 561015905
        do {
            try await recorder.arm(requireExistingPermission: true, mixWithOtherAudio: true)
            throw FixtureFailure.failed("Expected platform audio activation denial")
        } catch RecordingError.audioSessionFailed(let code, _) {
            let message = RecordingError.audioSessionFailed(code: code).localizedDescription
            try check(code == 561015905 && message.contains("!pla")
                      && message.contains("recording or playback"),
                      "Platform audio denial names !pla without claiming a playback-only cause")
        }
        session.activationErrorCode = nil
        let failureSteps = [
            ("category", "audio session configuration"),
            ("sounds", "recording sounds configuration"),
            ("activation", "audio session activation"),
            ("input", "microphone selection"),
            ("engine", "audio engine start")
        ]
        for (failureStep, expectedStep) in failureSteps {
            session.rejectedStep = failureStep
            engine.failStart = failureStep == "engine"
            do {
                try await recorder.arm(requireExistingPermission: true, mixWithOtherAudio: true)
                throw FixtureFailure.failed("Expected \(failureStep) failure")
            } catch let error as RecordingError {
                guard case .audioSessionFailed(let code, let context) = error else { throw error }
                try check(context?.errorDomain == NSOSStatusErrorDomain,
                          "OSStatus startup retains the original error domain")
                try check(code == 561015905 && error.localizedDescription.hasPrefix("Microphone setup failed at \(expectedStep)."),
                          "Same platform error at \(failureStep) reports the actual failing step")
            }
            try check(!session.active && !engine.isRunning && engine.inputNode.taps == 0,
                      "\(failureStep) failure retires activation, engine and tap")
            session.rejectedStep = nil
            engine.failStart = false
            try await recorder.arm(requireExistingPermission: true, mixWithOtherAudio: true)
            try check(session.active && engine.isRunning && engine.inputNode.taps == 1,
                      "Retry after \(failureStep) failure starts a fresh recorder")
            recorder.shutdown()
        }
        session.omitMixOption = true
        session.resetConfigurationOnDeactivate = true
        session.activationErrorCode = 561015905
        do {
            try await recorder.arm(requireExistingPermission: true, mixWithOtherAudio: true)
            throw FixtureFailure.failed("Expected activation failure with differing effective options")
        } catch let error as RecordingError {
            guard case .audioSessionFailed(_, let context) = error else { throw error }
            try check(context?.requested.options == 5 && context?.effective.options == 4
                      && context?.effective.category == "AVAudioSessionCategoryPlayAndRecord"
                      && context?.effective.mode == "AVAudioSessionModeMeasurement"
                      && session.categoryOptions.isEmpty,
                      "Failure snapshots effective category, mode and options before cleanup changes them")
            try check(error.localizedDescription.contains("options 0x4")
                      && error.localizedDescription.contains("Requested:")
                      && error.localizedDescription.contains("options 0x5"),
                      "Different effective options are visible alongside the requested configuration")
        }
        session.activationErrorCode = nil
        session.omitMixOption = false
        session.resetConfigurationOnDeactivate = false
        engine.startError = NSError(domain: "com.apple.coreaudio.avfaudio", code: 2003329396)
        session.omitMixOption = true
        session.resetConfigurationOnDeactivate = true
        do {
            try await recorder.arm(requireExistingPermission: true, mixWithOtherAudio: true)
            throw FixtureFailure.failed("Expected native AVFAudio engine failure")
        } catch RecordingError.audioSessionFailed(let code, let context) {
            try check(code == 2003329396 && context?.errorDomain == "com.apple.coreaudio.avfaudio"
                      && context?.step == .engine,
                      "AVFAudio startup retains original domain, code and actual failing operation")
            try check(context?.requested.options == 5 && context?.effective.options == 4
                      && context?.effective.category == "AVAudioSessionCategoryPlayAndRecord"
                      && context?.effective.mode == "AVAudioSessionModeMeasurement"
                      && session.categoryOptions.isEmpty,
                      "AVFAudio snapshots requested/effective session configuration before cleanup")
            try check(RecordingError.audioSessionFailed(code: code, context: context).localizedDescription.contains("com.apple.coreaudio.avfaudio"),
                      "Native error domain remains visible in the contextual failure")
        }
        try check(!session.active && !engine.isRunning && engine.inputNode.taps == 0,
                  "AVFAudio start failure cleans up session, engine and tap")
        engine.startError = nil
        session.omitMixOption = false
        session.resetConfigurationOnDeactivate = false
        try await recorder.arm(requireExistingPermission: true, mixWithOtherAudio: true)
        try check(session.active && engine.isRunning && engine.inputNode.taps == 1,
                  "Explicit retry succeeds after native AVFAudio failure")
        recorder.shutdown()
        let unchangedErrors: [any Error] = [CancellationError(), RecordingError.unavailableInput, NSError(domain: "UnrelatedFixtureError", code: 2003329396)]
        for originalError in unchangedErrors {
            engine.startError = originalError
            do {
                try await recorder.arm(requireExistingPermission: true)
                throw FixtureFailure.failed("Expected unchanged non-platform startup failure")
            } catch {
                let original = originalError as NSError
                let returned = error as NSError
                try check(original.domain == returned.domain && original.code == returned.code,
                          "Cancellation, typed recording errors and unrelated domains retain their identity")
            }
            try check(!session.active && !engine.isRunning && engine.inputNode.taps == 0,
                      "Unnormalized startup failure still cleans up microphone resources")
        }
        engine.startError = nil
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
            // End A and arm B before delivering A's queued event. A reset
            // requires new OS objects; ordinary interruptions reuse the lease.
            try await recorder.arm(requireExistingPermission: true)
            engine = AVAudioEngine.engines.last!
            recorder.beginCapture()
            let before = deliveredEvents
            post(name, info: info)
            _ = recorder.endCapture(keepEngineRunning: true)
            try await recorder.arm(requireExistingPermission: true)
            engine = AVAudioEngine.engines.last!
            recorder.beginCapture()
            let replacementGeneration = recorder.captureSnapshot.generation
            FixtureAudioCallbacks.drain()
            try check(deliveredEvents == before && recorder.captureSnapshot.generation == replacementGeneration && engine.isRunning,
                      "Late \(name.rawValue) from capture A cannot stop replacement B")

            post(name, info: info)
            FixtureAudioCallbacks.drain()
            try check(deliveredEvents == before + 1 && !engine.isRunning && recorder.captureSnapshot.generation == nil,
                      "Current \(name.rawValue) still stops B capture")

            try await recorder.arm(requireExistingPermission: true)
            engine = AVAudioEngine.engines.last!
            post(name, info: info)
            try await recorder.arm(requireExistingPermission: true)
            engine = AVAudioEngine.engines.last!
            recorder.beginCapture()
            FixtureAudioCallbacks.drain()
            try check(deliveredEvents == before + 1 && engine.isRunning && recorder.captureSnapshot.generation != nil,
                      "Queued idle-keyboard \(name.rawValue) cannot stop a newly begun capture")
            _ = recorder.endCapture(keepEngineRunning: true)

            post(name, info: info)
            FixtureAudioCallbacks.drain()
            try check(deliveredEvents == before + 2 && !engine.isRunning,
                      "Current idle-keyboard \(name.rawValue) still retires its microphone lease")

            try await recorder.arm(requireExistingPermission: true)
            engine = AVAudioEngine.engines.last!
            recorder.beginCapture()
            // The platform can post from an audio worker. Observe on that thread
            // before the MainActor hop, rather than first queueing observer delivery.
            DispatchQueue.global().sync {
                post(name, info: info)
            }
            recorder.shutdown()
            try await recorder.arm(requireExistingPermission: true)
            engine = AVAudioEngine.engines.last!
            recorder.beginCapture()
            FixtureAudioCallbacks.drain()
            try check(deliveredEvents == before + 2 && engine.isRunning && recorder.captureSnapshot.generation != nil,
                      "Shutdown invalidates queued \(name.rawValue) before replacement activation")
            recorder.shutdown()

            post(name, info: info)
            try await recorder.arm(requireExistingPermission: true)
            engine = AVAudioEngine.engines.last!
            recorder.beginCapture()
            FixtureAudioCallbacks.drain()
            try check(deliveredEvents == before + 2 && engine.isRunning,
                      "Unarmed \(name.rawValue) cannot become a future capture's event")
            recorder.shutdown()
        }
        let stoppedEngine = engine
        stoppedEngine.invalidated = true
        post(AVAudioSession.mediaServicesWereResetNotification, info: nil)
        FixtureAudioCallbacks.drain()
        let enginesBeforeRetry = AVAudioEngine.engines.count
        try check(!session.active && AVAudioEngine.engines.last === stoppedEngine,
                  "Unowned reset never activates or silently recreates recording")
        try await recorder.arm(requireExistingPermission: true, mixWithOtherAudio: true)
        engine = AVAudioEngine.engines.last!
        try check(engine !== stoppedEngine && AVAudioEngine.engines.count == enginesBeforeRetry + 1
                  && engine.isRunning && engine.inputNode.taps == 1,
                  "Explicit arm after an unowned reset constructs a fresh functioning engine")
        let warmActivationCount = session.activations
        try await recorder.arm(requireExistingPermission: true)
        try check(AVAudioEngine.engines.last === engine && session.activations == warmActivationCount,
                  "A valid running engine still takes the warm fast path")
        recorder.beginCapture()
        engine.inputNode.emitSamples()
        FixtureAudioCallbacks.drain()
        let buffered = recorder.captureSnapshot.bufferedSamples
        try check(buffered > 0, "Real converter deposits fixture PCM before media reset")
        let staleResetEngine = engine
        staleResetEngine.invalidated = true
        post(AVAudioSession.mediaServicesWereResetNotification, info: nil)
        try await recorder.arm(requireExistingPermission: true)
        engine = AVAudioEngine.engines.last!
        try check(engine !== staleResetEngine && engine.isRunning
                  && recorder.captureSnapshot.bufferedSamples == buffered,
                  "Pending reset invalidates even a running fast path without discarding captured PCM")
        let retainedSamples = recorder.endCapture(keepEngineRunning: true)
        recorder.beginCapture()
        let replacementGeneration = recorder.captureSnapshot.generation
        FixtureAudioCallbacks.drain()
        try check(retainedSamples.count == buffered && engine.isRunning
                  && recorder.captureSnapshot.generation == replacementGeneration,
                  "Queued pre-rebuild reset cannot interrupt its replacement capture")
        engine.inputNode.emitSamples()
        FixtureAudioCallbacks.drain()
        let replacementBuffered = recorder.captureSnapshot.bufferedSamples
        var finishedSamples: [Float] = []
        recorder.onInterruption = { finishedSamples = recorder.endCapture(keepEngineRunning: false) }
        let orphanedEngine = engine
        orphanedEngine.invalidated = true
        post(AVAudioSession.mediaServicesWereResetNotification, info: nil)
        FixtureAudioCallbacks.drain()
        try check(finishedSamples.count == replacementBuffered && replacementBuffered > 0 && !orphanedEngine.isRunning && orphanedEngine.inputNode.taps == 0,
                  "Reset interruption preserves every buffered sample for consumer finalization")
        try check(AVAudioEngine.engines.last === orphanedEngine && !session.active,
                  "Reset handling does not automatically restart capture")
        try await recorder.arm(requireExistingPermission: true)
        engine = AVAudioEngine.engines.last!
        try check(engine !== orphanedEngine && engine.isRunning && engine.inputNode.taps == 1,
                  "User retry after owned reset replaces orphaned audio objects")
        recorder.shutdown()
        print("PASS: \(checks) production AudioRecorder lifecycle checks")
    }
}
