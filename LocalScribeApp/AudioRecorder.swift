import AVFoundation
import Foundation
import LocalScribeCore

enum RecordingError: LocalizedError {
    case microphoneDenied, unavailableInput, converterUnavailable, noAudio
    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Enable it for LocalScribe in iPhone Settings."
        case .unavailableInput: "No microphone is available. Check your audio connection and try again."
        case .converterUnavailable: "The microphone audio format could not be prepared."
        case .noAudio: "No audio was captured. Try speaking closer to your microphone."
        }
    }
}

@MainActor
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let capture = CaptureBuffer()
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []
    var onLevel: ((Float) -> Void)?
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

    func arm() async throws {
        if engine.isRunning { return }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else { throw RecordingError.microphoneDenied }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setActive(true)
        do {
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecordingError.unavailableInput }
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inputFormat, to: format) else { throw RecordingError.converterUnavailable }
            let capture = capture
            // The audio tap serializes conversion. Reset on its queue at each utterance boundary,
            // avoiding converter carry-over and avoiding all conversion/allocation while idle.
            var convertedGeneration: UInt?
            input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
                guard let generation = capture.captureGeneration else { return }
                if generation != convertedGeneration {
                    converter.reset()
                    convertedGeneration = generation
                }
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate) + 32)
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
                var supplied = false
                var conversionError: NSError?
                converter.convert(to: output, error: &conversionError) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return buffer
                }
                guard conversionError == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
                let reachedLimit = capture.append(samples, generation: generation)
                let meanSquare = samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count)
                let level = min(1, max(0, sqrt(meanSquare) * 5))
                Task { @MainActor in
                    self?.onLevel?(level)
                    if reachedLimit { self?.onLimit?() }
                }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            shutdown()
            throw error
        }
    }

    func beginCapture() { capture.begin() }
    func endCapture(keepEngineRunning: Bool) -> [Float] {
        let samples = capture.finish()
        if !keepEngineRunning { shutdown() }
        return samples
    }
    func shutdown() {
        capture.discard()
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onLevel?(0)
    }
}
