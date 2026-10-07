import Combine
import LocalScribeCore
import SwiftUI
import UIKit

@main
struct LocalScribeApplication: App {
    init() {
        #if DEBUG && targetEnvironment(simulator)
        if DesignPreviewConfiguration.current != nil { return }
        #endif
        // OS-run Live Activity intents need services even before a scene appears.
        _ = AppContext.shared
    }
    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if let preview = DesignPreviewConfiguration.current {
                DesignPreviewRootView(configuration: preview)
            } else {
                LocalScribeApplicationContent()
            }
            #else
            LocalScribeApplicationContent()
            #endif
        }
    }
}

private struct LocalScribeApplicationContent: View {
    @StateObject private var context = AppContext.shared

    var body: some View {
        ZStack {
            LocalScribeRootView(controller: context.controller, notes: context.notesController)
                .disabled(context.benchmarkStatus != nil)
            if let status = context.benchmarkStatus {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(status).font(.headline)
                    Text(context.developerRunDescription).font(.caption)
                }
                .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
    }
}

/// SwiftUI retains one object owning both sides of the app-to-keyboard bridge.
@MainActor
final class AppContext: ObservableObject {
    static let shared = AppContext()
    let controller: AppController
    let notesController = NotesController()
    let keyboardCoordinator: KeyboardSessionCoordinator
    let actionBridge: DictationActionBridge
    @Published private(set) var benchmarkStatus: String?
    @Published private(set) var developerRunDescription = "Local device benchmark · microphone is off"
    private var benchmarkTask: Task<Void, Never>?
    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        let engine: any LocalTranscriptionEngine
        var startupError: String?
        do { engine = try LocalModelEngine() }
        catch { engine = FailedModelEngine(message: error.localizedDescription); startupError = error.localizedDescription }
        #if DEBUG
        let developerRun = arguments.contains("--verify-dictation") || arguments.contains("--benchmark-models")
        #else
        let developerRun = false
        #endif
        controller = AppController(engine: engine, verificationMode: developerRun)
        if let startupError { controller.errorMessage = startupError }
        keyboardCoordinator = KeyboardSessionCoordinator(controller: controller)
        actionBridge = DictationActionBridge(controller: controller)
        #if DEBUG
        do {
            if let verification = try RecordingVerificationRunner(arguments: arguments) {
                benchmarkStatus = "Preparing dictation verification"
                developerRunDescription = arguments.contains("--verify-long-microphone") ? "Five-second Stop check and 125-second microphone check, discarded; public speech fixture recognition" : "Five seconds of microphone capture, discarded; public speech fixture recognition"
                benchmarkTask = Task { [weak self] in
                    let originalIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
                    UIApplication.shared.isIdleTimerDisabled = true
                    defer { UIApplication.shared.isIdleTimerDisabled = originalIdleTimerSetting }
                    do {
                        let output = try await verification.run(engine: engine) { [weak self] status in
                            Task { @MainActor in self?.benchmarkStatus = status }
                        }
                        self?.benchmarkStatus = "Verification saved locally: \(output.lastPathComponent)"
                        self?.developerRunDescription = "Relaunch LocalScribe normally to dictate"
                    } catch {
                        self?.benchmarkStatus = "Verification failed: \(error.localizedDescription)"
                        self?.developerRunDescription = "Relaunch LocalScribe normally to dictate"
                    }
                }
            } else if let runner = try BenchmarkRunner(arguments: arguments) {
                benchmarkStatus = "Preparing benchmark"
                benchmarkTask = Task { [weak self] in
                    let originalIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
                    UIApplication.shared.isIdleTimerDisabled = true
                    defer { UIApplication.shared.isIdleTimerDisabled = originalIdleTimerSetting }
                    do {
                        let output = try await runner.run { [weak self] status in
                            Task { @MainActor in
                                if self?.benchmarkStatus != nil { self?.benchmarkStatus = status }
                            }
                        }
                        self?.controller.errorMessage = "Benchmark saved locally: \(output.lastPathComponent)"
                    } catch { self?.controller.errorMessage = "Benchmark failed: \(error.localizedDescription)" }
                    self?.benchmarkStatus = "Benchmark finished. Relaunch LocalScribe normally to dictate."
                    await self?.controller.refreshInstalledModels()
                }
            }
        } catch { controller.errorMessage = error.localizedDescription }
        #endif
    }
}

private actor FailedModelEngine: LocalTranscriptionEngine {
    let message: String
    init(message: String) { self.message = message }
    func isInstalled(_ model: SpeechModel) async -> Bool { false }
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws { throw Failure(message: message) }
    func prepare(_ model: SpeechModel) async throws { throw Failure(message: message) }
    func transcribe(samples: [Float]) async throws -> String { throw Failure(message: message) }
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
}
