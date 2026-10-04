import Combine
import LocalScribeCore
import SwiftUI
import UIKit

@main
struct LocalScribeApplication: App {
    @StateObject private var context = AppContext()
    var body: some Scene {
        WindowGroup {
            ZStack {
                LocalScribeRootView(controller: context.controller).disabled(context.benchmarkStatus != nil)
                if let status = context.benchmarkStatus {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(status).font(.headline)
                        Text("Local device benchmark · microphone is off").font(.caption)
                    }
                    .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                }
            }
        }
    }
}

/// SwiftUI retains one object owning both sides of the app-to-keyboard bridge.
@MainActor
private final class AppContext: ObservableObject {
    let controller: AppController
    let keyboardCoordinator: KeyboardSessionCoordinator
    @Published private(set) var benchmarkStatus: String?
    private var benchmarkTask: Task<Void, Never>?
    init() {
        do {
            controller = AppController(engine: try LocalModelEngine())
        } catch {
            controller = AppController(engine: FailedModelEngine(message: error.localizedDescription))
            controller.errorMessage = error.localizedDescription
        }
        keyboardCoordinator = KeyboardSessionCoordinator(controller: controller)
        #if DEBUG
        do {
            if let runner = try BenchmarkRunner(arguments: ProcessInfo.processInfo.arguments) {
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
                    self?.benchmarkStatus = nil
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
