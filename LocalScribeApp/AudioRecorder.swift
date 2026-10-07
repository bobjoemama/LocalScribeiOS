import AVFoundation
import Foundation
import LocalScribeCore

enum RecordingError: LocalizedError {
    case microphoneDenied, unavailableInput, converterUnavailable, conversionFailed, noAudio
    case audioSessionFailed(code: Int)
    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Enable it for LocalScribe in iPhone Settings."
        case .unavailableInput: "No microphone is available. Check your audio connection and try again."
        case .converterUnavailable: "The microphone audio format could not be prepared."
        case .conversionFailed: "Microphone audio conversion failed. Recording stopped to avoid losing more speech."
        case .noAudio: "No audio was captured. Try speaking closer to your microphone."
        case let .audioSessionFailed(code):
            switch code {
            case AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue:
                "iOS could not activate the microphone from the background. Open LocalScribe and try again. Audio error: \(code) (!int)."
            case AVAudioSession.ErrorCode.cannotStartRecording.rawValue:
                "iOS did not permit microphone recording. Start recording with LocalScribe onscreen. Audio error: \(code) (!rec)."
            case AVAudioSession.ErrorCode.insufficientPriority.rawValue:
                "Another app controls the audio session. Finish its call or recording, then try again. Audio error: \(code) (!pri)."
            case AVAudioSession.ErrorCode.siriIsRecording.rawValue:
                "Siri is using the microphone. Wait for Siri to finish, then try again. Audio error: \(code)."
            default:
                "The microphone could not start. Audio error: \(code)."
            }
        }
    }
}

@MainActor
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let capture = CaptureBuffer()
    private var tapInstalled = false
    private var activationRevision: UInt = 0
    private var observers: [NSObjectProtocol] = []
    var preferBuiltInMicrophone = false
    var hapticFeedbackEnabled = false
    var onLevel: ((Float) -> Void)?
    /// Actual lost samples due to consumer backpressure, not a duration limit.
    var onOverflow: ((Int) -> Void)?
    var onCaptureFailure: ((RecordingError) -> Void)?
    /// Compatibility fallback for consumers that have not adopted onOverflow yet.
    var onLimit: (() -> Void)?
    var onInterruption: (() -> Void)?

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: value) == .began else { return }
            Task { @MainActor in self?.onInterruption?() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: value) == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.onInterruption?() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onInterruption?() }
        })
    }

    var microphonePermissionGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }

    func arm(requireExistingPermission: Bool = false, mixWithOtherAudio: Bool = false) async throws {
        if engine.isRunning { return }
        let revision = activationRevision
        let allowed: Bool
        if requireExistingPermission { allowed = microphonePermissionGranted }
        else { allowed = await AVAudioApplication.requestRecordPermission() }
        // Permission can outlive Cancel/backgrounding. Fence before touching the
        // audio session or input tap, rather than repairing a stale activation later.
        guard revision == activationRevision else { throw CancellationError() }
        try Task.checkCancellation()
        guard allowed else { throw RecordingError.microphoneDenied }
        if engine.isRunning { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // A nonmixable .record session cannot activate from the background.
            // .playAndRecord supports mixing; no playback or silent keepalive is added.
            try session.setCategory(mixWithOtherAudio ? .playAndRecord : .record, mode: .measurement,
                                    options: mixWithOtherAudio ? [.allowBluetoothHFP, .mixWithOthers] : [.allowBluetoothHFP])
            try session.setAllowHapticsAndSystemSoundsDuringRecording(hapticFeedbackEnabled)
            try session.setActive(true)
            if preferBuiltInMicrophone, let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(microphone)
            } else {
                try session.setPreferredInput(nil)
            }
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecordingError.unavailableInput }
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inputFormat, to: format) else { throw RecordingError.converterUnavailable }
            let processor = AudioCaptureTapProcessor(capture: capture, converter: converter, format: format,
                                                     inputSampleRate: inputFormat.sampleRate) { @Sendable [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self, self.capture.captureGeneration == event.generation else { return }
                    switch event {
                    case let .samples(level, droppedSamples, _):
                        self.onLevel?(level)
                        if droppedSamples > 0 {
                            if let onOverflow = self.onOverflow { onOverflow(droppedSamples) }
                            else { self.onLimit?() }
                        }
                    case .failure:
                        if let onCaptureFailure = self.onCaptureFailure { onCaptureFailure(.conversionFailed) }
                        else { self.onInterruption?() }
                    }
                }
            }
            // AVFAudio may call this block off the main thread. Explicit @Sendable plus
            // a nonisolated processor prevents a Swift 6 inherited-MainActor runtime trap.
            input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { @Sendable [processor] buffer, _ in
                processor.process(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            shutdown()
            let systemError = error as NSError
            if systemError.domain == NSOSStatusErrorDomain {
                throw RecordingError.audioSessionFailed(code: systemError.code)
            }
            throw error
        }
    }

    func beginCapture() { capture.begin() }
    var captureSnapshot: CaptureBufferSnapshot { capture.snapshot }
    func drainCapture(minimumSamples: Int = 0, maximumSamples: Int = CaptureBuffer.sampleRate * 8) -> [Float] {
        capture.drain(minimumSamples: minimumSamples, maximumSamples: maximumSamples)
    }
    func endCapture(keepEngineRunning: Bool) -> [Float] {
        let samples = capture.finish()
        if !keepEngineRunning { shutdown() }
        return samples
    }
    func shutdown() {
        activationRevision &+= 1
        capture.discard()
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onLevel?(0)
    }
}

/// Mutable converter state belongs to this nonisolated audio helper, never to the UI actor.
/// The lock serializes processing even if a provider invokes its tap concurrently.
private final class AudioCaptureTapProcessor: @unchecked Sendable {
    enum Event: Sendable {
        case samples(level: Float, droppedSamples: Int, generation: UInt)
        case failure(generation: UInt)
        var generation: UInt {
            switch self {
            case let .samples(_, _, generation), let .failure(generation): generation
            }
        }
    }

    private let lock = NSLock()
    private let capture: CaptureBuffer
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let inputSampleRate: Double
    private let report: @Sendable (Event) -> Void
    private var convertedGeneration: UInt?

    nonisolated init(capture: CaptureBuffer, converter: AVAudioConverter, format: AVAudioFormat,
                     inputSampleRate: Double, report: @escaping @Sendable (Event) -> Void) {
        self.capture = capture
        self.converter = converter
        self.format = format
        self.inputSampleRate = inputSampleRate
        self.report = report
    }

    nonisolated func process(_ buffer: AVAudioPCMBuffer) {
        let event: Event? = lock.withLock {
            guard let generation = capture.captureGeneration else { return nil }
            if generation != convertedGeneration {
                converter.reset()
                convertedGeneration = generation
            }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * Double(CaptureBuffer.sampleRate) / inputSampleRate) + 32)
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                return recordFailure(generation: generation)
            }
            let supply = AudioTapInputSupply(buffer: buffer)
            var conversionError: NSError?
            let conversionStatus = converter.convert(to: output, error: &conversionError) { @Sendable [supply] _, status in
                supply.next(status)
            }
            guard conversionError == nil, conversionStatus != .error else { return recordFailure(generation: generation) }
            // A converter may buffer a short input without producing output yet.
            guard output.frameLength > 0 else { return nil }
            guard let channel = output.floatChannelData?[0] else { return recordFailure(generation: generation) }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            let before = capture.snapshot
            guard before.generation == generation else { return nil }
            capture.append(samples, generation: generation)
            let after = capture.snapshot
            guard after.generation == generation else { return nil }
            let droppedSamples = Int(after.overflowSamples - before.overflowSamples)
            let meanSquare = samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count)
            let level = min(1, max(0, sqrt(meanSquare) * 5))
            return .samples(level: level, droppedSamples: droppedSamples, generation: generation)
        }
        if let event { report(event) }
    }

    nonisolated private func recordFailure(generation: UInt) -> Event? {
        capture.markProcessingFailure(generation: generation) ? .failure(generation: generation) : nil
    }
}

/// AVAudioConverter invokes its input block synchronously inside the processor's lock.
/// Boxing the state makes that explicitly Sendable block independent of actor inference.
private final class AudioTapInputSupply: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false
    nonisolated init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    nonisolated func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}
