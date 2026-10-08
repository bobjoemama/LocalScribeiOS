import Combine
import Foundation
import LocalScribeCore

@MainActor final class PreparationGrantFixture: ModelPreparationGrant {
    var expiration: (@MainActor @Sendable () -> Void)?
    var updates: [(String, Int, Int)] = []
    var completions: [Bool] = []
    func setExpiration(_ handler: @escaping @MainActor @Sendable () -> Void) { expiration = handler }
    func update(title: String, phase: String, completedComponents: Int, totalComponents: Int) {
        updates.append((phase, completedComponents, totalComponents))
    }
    func complete(success: Bool) { completions.append(success) }
}

@MainActor final class PreparationSchedulerFixture: ModelPreparationScheduling {
    var unavailableReason: String? { nil }
    var launches: [String: @MainActor @Sendable (any ModelPreparationGrant) -> Void] = [:]
    var submitted: [String] = []
    var cancelled: [String] = []
    var grants: [PreparationGrantFixture] = []
    func register(identifier: String, launch: @escaping @MainActor @Sendable (any ModelPreparationGrant) -> Void) -> Bool {
        launches[identifier] = launch; return true
    }
    func submit(identifier: String, modelName: String) async throws {
        submitted.append(identifier)
        let grant = PreparationGrantFixture()
        grants.append(grant)
        launches[identifier]?(grant)
    }
    func cancel(identifier: String) { cancelled.append(identifier) }
    func refusalMessage(for error: Error) -> String { error.localizedDescription }
}

actor ReportingPreparationEngine: StreamingLocalTranscriptionEngine, ContextualLocalTranscriptionEngine,
    ComponentPreparationReportingEngine, PerformanceReportingEngine {
    let engine = LifecycleEngine()
    private var stage: ModelPreparationStage?
    private var progress: EnginePreparationProgress?
    private var reports: [EnginePerformanceReport] = []
    private var fail = false
    private var holdCapability = false
    private var capabilityContinuation: CheckedContinuation<Void, Never>?
    func holdNextCapability() { holdCapability = true }
    func capabilityHeld() -> Bool { capabilityContinuation != nil }
    func releaseCapability() { capabilityContinuation?.resume(); capabilityContinuation = nil }
    func failNextPreparation() { fail = true }
    func setProgress(_ value: EnginePreparationProgress) { progress = value }
    func performanceReports() async -> [EnginePerformanceReport] { reports }
    func preparationStage() async -> ModelPreparationStage? { stage }
    func preparationProgress() async -> EnginePreparationProgress? { progress }
    func isInstalled(_ model: SpeechModel) async -> Bool { await engine.isInstalled(model) }
    func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws { try await engine.download(model, progress: progress) }
    func supportsBackgroundInference(for model: SpeechModel, context: ModelExecutionContext) async -> Bool {
        if holdCapability {
            holdCapability = false
            await withCheckedContinuation { capabilityContinuation = $0 }
        }
        return context == .backgroundCapable || model == .parakeetRealtimeEOU || model == .moonshineSmall
    }
    func prepare(_ model: SpeechModel) async throws { try await prepare(model, context: .foreground) }
    func prepare(_ model: SpeechModel, context: ModelExecutionContext) async throws {
        stage = .loadingCoreML
        progress = .init(phase: .encoderLoad, completedComponents: 1, totalComponents: 5)
        do {
            if fail { fail = false; throw LifecycleEngine.Failure.expected }
            try await engine.prepare(model)
            try Task.checkCancellation()
            record(model, context: context, success: true)
            stage = .ready; progress = nil
        } catch {
            record(model, context: context, success: false)
            stage = nil; progress = nil
            throw error
        }
    }
    private func record(_ model: SpeechModel, context: ModelExecutionContext, success: Bool) {
        let resources = PerformanceReport(elapsedSeconds: 12, audioSeconds: nil, processCPUSeconds: nil,
            initialPhysicalFootprintBytes: nil, sampledPeakPhysicalFootprintBytes: nil, finalPhysicalFootprintBytes: nil,
            initialProcessLifetimePeakPhysicalFootprintBytes: nil, finalProcessLifetimePeakPhysicalFootprintBytes: nil,
            memorySampleCount: 0, memorySamplingIntervalSeconds: 0.05, initialThermalState: .unknown, finalThermalState: .unknown)
        reports.append(.init(id: UUID(), date: Date(), model: model, stage: .modelLoad, successful: success,
            resources: resources, requestedBackend: "Fixture CPU only", preparationPhases: [.init(phase: .encoderLoad,
                elapsedSeconds: 12, completed: success)], executionContext: context.normalized(for: model)))
    }
    func beginStreaming(onUpdate: @escaping @Sendable (SpeechTranscriptUpdate) -> Void) async throws { try await engine.beginStreaming(onUpdate: onUpdate) }
    func appendStreaming(samples: [Float]) async throws { try await engine.appendStreaming(samples: samples) }
    func finishStreaming() async throws -> String { try await engine.finishStreaming() }
    func cancelStreaming() async { await engine.cancelStreaming() }
    func transcribe(samples: [Float]) async throws -> String { "Unused" }
    func unload() async { await engine.unload() }
}

@main struct ModelPreparationControllerCheck {
    enum Failure: Error { case check(String) }
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.check(message) }; checks += 1
    }
    @MainActor static func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<300 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw Failure.check("Controller fixture transition timed out")
    }
    @MainActor static func fixture(_ engine: any LocalTranscriptionEngine, keepLoaded: Bool = true,
                                   root: URL? = nil, helper: BackgroundModelPreparation? = nil) async -> AppController {
        let directory = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ModelPreparationController-\(UUID())")
        let defaults = UserDefaults(suiteName: "ModelPreparationController-\(UUID())")!
        defaults.set(SpeechModel.parakeetPhonon.rawValue, forKey: "selectedModel")
        defaults.set(keepLoaded, forKey: "keepModelLoaded")
        defaults.set(false, forKey: "saveHistory")
        let controller = AppController(engine: engine, defaults: defaults, historyURL: directory.appendingPathComponent("history.json"),
            backgroundModelPreparation: helper)
        await controller.refreshInstalledModels()
        return controller
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ModelPreparationControllerPersistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ReportingPreparationEngine()
        let scheduler = PreparationSchedulerFixture()
        let helper = BackgroundModelPreparation(scheduler: scheduler, bundleIdentifier: "fixture.localscribe")
        let controller = await fixture(engine, root: directory, helper: helper)
        let recorder = AudioRecorder.latest!
        var statuses: [String?] = []
        let statusSubscription = controller.$modelStatus.sink { statuses.append($0) }
        try await eventually { await engine.engine.counts().0 == 1 && controller.modelPreparationProgress != nil }
        try check(scheduler.submitted.isEmpty, "Automatic prewarming never requests a native continuation")
        let statusCount = statuses.count
        try await Task.sleep(for: .milliseconds(750))
        try check(statuses.count == statusCount, "Repeated unchanged engine stage does not republish status at polling frequency")
        controller.prepareSelectedModelInBackground()
        try await eventually { !scheduler.grants.isEmpty && controller.backgroundModelPreparationActive }
        let grant = scheduler.grants[0]
        try check(grant.updates.last?.1 == 1 && grant.updates.last?.2 == 5,
                  "Continue in Background catches up to real component progress already reported by the shared flight")
        let joinedCounts = await engine.engine.counts()
        try check(joinedCounts.0 == 1 && recorder.armCalls == 0 && !recorder.recording,
                  "Explicit continuation joins one selected CPU flight without microphone activation")
        await engine.setProgress(.init(phase: .preprocessorLoad, completedComponents: 2, totalComponents: 5))
        try await eventually { grant.updates.last?.1 == 2 }
        try check(controller.modelStatus?.contains("audio preprocessor") == true && grant.updates.last?.2 == 5,
                  "Changed component phase publishes actual progress rather than fabricated elapsed work")
        controller.setForeground(false)
        await engine.engine.releasePreparation()
        try await eventually { controller.actionButtonModelReady && !controller.backgroundModelPreparationActive && controller.modelPreparationReports.count == 1 }
        try check(controller.backgroundModelPreparationStatus == .ready && grant.completions == [true],
                  "A granted CPU preparation completes Ready in background and releases its execution grant")
        try check(controller.modelPreparationReports[0].executionContext == .backgroundCapable
                  && controller.modelPreparationReports[0].resources.elapsedSeconds == 12
                  && controller.modelPreparationReports[0].resources.sampledPeakPhysicalFootprintBytes == nil,
                  "Completed summaries preserve measured backend, elapsed values and unavailable RAM")
        let restored = await fixture(LifecycleEngine(), keepLoaded: false, root: directory)
        try await eventually { restored.modelPreparationReports.count == 1 }
        try check(restored.preparedModel == nil && restored.modelPreparationReports[0].id == controller.modelPreparationReports[0].id,
                  "A recreated controller restores historical measurements without claiming its runtime is Ready")
        withExtendedLifetime(statusSubscription) {}

        let sharingEngine = ReportingPreparationEngine()
        let sharingScheduler = PreparationSchedulerFixture()
        let sharingHelper = BackgroundModelPreparation(scheduler: sharingScheduler, bundleIdentifier: "fixture.localscribe")
        let sharing = await fixture(sharingEngine, helper: sharingHelper)
        let sharingRecorder = AudioRecorder.latest!
        try await eventually { await sharingEngine.engine.counts().0 == 1 }
        sharing.prepareSelectedModelInBackground()
        try await eventually { !sharingScheduler.grants.isEmpty }
        await sharing.startRecording()
        let recordingID = sharing.currentRecordingID
        sharingScheduler.grants[0].expiration?()
        try check(!sharing.backgroundModelPreparationActive && sharing.phase == .recording
                  && sharing.currentRecordingID == recordingID && sharingRecorder.recording,
                  "Expiring the preparation request cannot cancel newer recording ownership sharing its flight")
        await sharingEngine.engine.releasePreparation()
        try await eventually { sharing.actionButtonModelReady }
        sharingRecorder.feed(8_000)
        await sharing.stopRecording()
        let sharingCounts = await sharingEngine.engine.counts()
        try check(sharingCounts.0 == 1 && sharingCounts.2 == 0 && sharing.transcript == "Captured words.",
                  "The replacement capture finishes through its same uncancelled CPU runtime")

        let cancelledEngine = ReportingPreparationEngine()
        let cancelledScheduler = PreparationSchedulerFixture()
        let cancelledHelper = BackgroundModelPreparation(scheduler: cancelledScheduler, bundleIdentifier: "fixture.localscribe")
        let cancelled = await fixture(cancelledEngine, helper: cancelledHelper)
        try await eventually { await cancelledEngine.engine.counts().0 == 1 }
        cancelled.prepareSelectedModelInBackground()
        try await eventually { !cancelledScheduler.grants.isEmpty }
        let oldExpiry = cancelledScheduler.grants[0].expiration
        cancelled.selectedModel = .parakeetPhononG4
        try check(!cancelled.backgroundModelPreparationActive && cancelled.backgroundModelPreparationStatus == nil,
                  "Changing selection retires the old background request and its status")
        cancelled.prepareSelectedModelInBackground()
        try await eventually { cancelledScheduler.grants.count == 2 }
        oldExpiry?()
        try check(cancelled.backgroundModelPreparationActive && cancelled.selectedModel == .parakeetPhononG4,
                  "An old grant's expiry cannot retire the replacement model's preparation request")
        await cancelledEngine.engine.releasePreparation()
        try await eventually { cancelled.actionButtonModelReady && !cancelled.backgroundModelPreparationActive }
        let preparations = await cancelledEngine.engine.preparations()
        try check(preparations == [.parakeetPhonon, .parakeetPhononG4],
                  "Owned cancellation serializes the old flight before preparing the newly selected model exactly once")

        let failedEngine = ReportingPreparationEngine()
        await failedEngine.failNextPreparation()
        let failedScheduler = PreparationSchedulerFixture()
        let failedHelper = BackgroundModelPreparation(scheduler: failedScheduler, bundleIdentifier: "fixture.localscribe")
        let failed = await fixture(failedEngine, helper: failedHelper)
        try await eventually { failed.modelPreparationReports.count == 1 }
        try check(!failed.modelPreparationReports[0].successful && !failed.actionButtonModelReady,
                  "Failed measured preparation persists as a failure rather than fake Ready or zero resource values")
        let off = await fixture(LifecycleEngine(), keepLoaded: false, helper: failedHelper)
        off.prepareSelectedModelInBackground()
        try check(!off.backgroundModelPreparationActive && !off.keepModelLoaded,
                  "Explicit background loading does not silently change the Off preference")
        let ownedEngine = ReportingPreparationEngine()
        let ownedScheduler = PreparationSchedulerFixture()
        let ownedHelper = BackgroundModelPreparation(scheduler: ownedScheduler, bundleIdentifier: "fixture.localscribe")
        let owned = await fixture(ownedEngine, helper: ownedHelper)
        let ownedRecorder = AudioRecorder.latest!
        try await eventually { await ownedEngine.engine.counts().0 == 1 }
        owned.prepareSelectedModelInBackground()
        try await eventually { !ownedScheduler.grants.isEmpty }
        owned.cancelSelectedModelPreparation()
        try check(!owned.backgroundModelPreparationActive && ownedRecorder.armCalls == 0
                  && ownedScheduler.grants[0].completions == [false],
                  "Explicit Cancel retires only its idle loading request and grant without touching audio")
        await ownedEngine.engine.releasePreparation()
        try await eventually { owned.modelPreparationReports.count == 1 }
        try check(!owned.actionButtonModelReady && !owned.modelPreparationReports[0].successful,
                  "An owned cancelled load cannot publish late Ready and its unsuccessful measurement remains inspectable")

        let corruptRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ModelPreparationControllerCorrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        let corruptFile = corruptRoot.appendingPathComponent("ModelPerformance/load-reports.json")
        try FileManager.default.createDirectory(at: corruptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corruptBytes = Data("{unreadable prior measurement".utf8)
        try corruptBytes.write(to: corruptFile)
        let corruptEngine = ReportingPreparationEngine()
        await corruptEngine.engine.releasePreparation()
        let corruptController = await fixture(corruptEngine, root: corruptRoot)
        let corruptRecorder = AudioRecorder.latest!
        try await eventually { corruptController.actionButtonModelReady && corruptController.modelPreparationReportError != nil }
        try check(corruptController.errorMessage == nil && (try Data(contentsOf: corruptFile)) == corruptBytes,
                  "Unreadable measurement storage is a secondary warning and cannot fail otherwise successful model preparation")
        await corruptController.startRecording()
        corruptRecorder.feed(8_000)
        await corruptController.stopRecording()
        try check(corruptController.transcript == "Captured words." && corruptController.errorMessage == nil
                  && corruptController.modelPreparationReportError != nil && (try Data(contentsOf: corruptFile)) == corruptBytes,
                  "Dictation succeeds while invalid saved measurements stay preserved and read-only")

        let reboundEngine = ReportingPreparationEngine()
        let reboundScheduler = PreparationSchedulerFixture()
        let reboundHelper = BackgroundModelPreparation(scheduler: reboundScheduler, bundleIdentifier: "fixture.localscribe")
        let rebound = await fixture(reboundEngine, keepLoaded: false, helper: reboundHelper)
        await reboundEngine.holdNextCapability()
        rebound.keepModelLoaded = true
        rebound.prepareSelectedModelInBackground()
        try await eventually { await reboundEngine.capabilityHeld() }
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await eventually { await reboundEngine.engine.counts().2 >= 1 }
        await reboundEngine.releaseCapability()
        try await eventually { await reboundEngine.engine.counts().0 == 1 }
        let unloadsBeforeCancel = await reboundEngine.engine.counts().2
        rebound.cancelSelectedModelPreparation()
        await reboundEngine.engine.releasePreparation()
        try await eventually {
            let unloads = await reboundEngine.engine.counts().2
            return rebound.modelPreparationReports.count == 1 && unloads > unloadsBeforeCancel
        }
        try check(!rebound.backgroundModelPreparationActive && !rebound.actionButtonModelReady
                  && !rebound.modelPreparationReports[0].successful,
                  "Cancellation binds the actual started flight even when memory release advances revision during capability discovery")

        print("PASS: \(checks) model preparation controller checks")
    }
}
