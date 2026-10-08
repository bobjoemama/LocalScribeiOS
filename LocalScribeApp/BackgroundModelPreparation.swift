import Foundation
#if os(iOS)
@preconcurrency import BackgroundTasks
#endif

// A grant follows an explicit Prepare/Retry action. Automatic prewarming must
// never call begin: a saved preference is not a continued-processing gesture.
@MainActor
final class BackgroundModelPreparation {
    enum Status: Equatable, Sendable {
        case submitted
        case running
        case foregroundOnly(String)
        case ready
        case failed(String)
        case cancelled(String)
    }

    private final class Job {
        let ownerID: UUID
        let identifier: String
        let modelName: String
        let cancelOwned: @MainActor @Sendable () -> Void
        let onStatus: @MainActor @Sendable (Status) -> Void
        var operation: Task<Void, Never>?
        var submission: Task<Void, Never>?
        var grant: (any ModelPreparationGrant)?
        var acceptsGrant = false
        var phase = "Preparing model"
        var completedComponents = 0
        var totalComponents = 0

        init(ownerID: UUID, identifier: String, modelName: String,
             cancelOwned: @escaping @MainActor @Sendable () -> Void,
             onStatus: @escaping @MainActor @Sendable (Status) -> Void) {
            self.ownerID = ownerID
            self.identifier = identifier
            self.modelName = modelName
            self.cancelOwned = cancelOwned
            self.onStatus = onStatus
        }
    }

    private let scheduler: any ModelPreparationScheduling
    private let bundleIdentifier: String
    private var currentJob: Job?

    convenience init() {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.init(scheduler: NativeModelPreparationScheduler(), bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.devesh.localscribe.ios")
            return
        }
        #endif
        self.init(scheduler: ForegroundModelPreparationScheduler(), bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.devesh.localscribe.ios")
    }

    init(scheduler: any ModelPreparationScheduling, bundleIdentifier: String) {
        self.scheduler = scheduler
        self.bundleIdentifier = bundleIdentifier
    }

    // operation joins the controller's existing flight; it must not load a
    // second model. cancelOwned must fence that flight by this same ownerID.
    func begin(ownerID: UUID, modelName: String,
               operation: @escaping @MainActor @Sendable () async throws -> Void,
               cancelOwned: @escaping @MainActor @Sendable () -> Void,
               onStatus: @escaping @MainActor @Sendable (Status) -> Void) {
        guard currentJob?.ownerID != ownerID else { return }
        if let old = currentJob { cancel(job: old, reason: "Model preparation replaced.") }
        // Every new request gets a new full identifier: registering one twice
        // terminates the app. Only the wildcard belongs in Info.plist.
        let identifier = "\(bundleIdentifier).prepareModel.\(UUID().uuidString)"
        let job = Job(ownerID: ownerID, identifier: identifier, modelName: modelName,
                      cancelOwned: cancelOwned, onStatus: onStatus)
        currentJob = job

        if let unavailable = scheduler.unavailableReason {
            onStatus(.foregroundOnly(unavailable))
        } else if scheduler.register(identifier: identifier, launch: { [weak self] grant in
            guard let self else { grant.complete(success: false); return }
            self.attach(grant, identifier: identifier)
        }) {
            job.acceptsGrant = true
            onStatus(.submitted)
            job.submission = Task { [weak self, scheduler] in
                do {
                    try await scheduler.submit(identifier: identifier, modelName: modelName)
                    // Async submission may outlive Ready, a cancellation or a
                    // newer request. Retire only this identifier in that case.
                    guard let self, self.currentJob?.identifier == identifier else {
                        scheduler.cancel(identifier: identifier)
                        return
                    }
                } catch {
                    guard let self, self.currentJob?.identifier == identifier else { return }
                    scheduler.cancel(identifier: identifier)
                    job.acceptsGrant = false
                    if let grant = job.grant {
                        grant.complete(success: false)
                        job.grant = nil
                    }
                    onStatus(.foregroundOnly(scheduler.refusalMessage(for: error)))
                }
            }
        } else {
            onStatus(.foregroundOnly("Background preparation is not registered. Keep LocalScribe open until Ready."))
        }

        guard currentJob?.identifier == identifier else { return }
        job.operation = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
                self?.finish(identifier: identifier, status: .ready, success: true)
            } catch is CancellationError {
                guard let self, self.currentJob?.identifier == identifier else { return }
                self.cancel(ownerID: ownerID)
            } catch {
                self?.finish(identifier: identifier, status: .failed(error.localizedDescription), success: false)
            }
        }
    }

    func updateProgress(ownerID: UUID, phase: String, completedComponents: Int, totalComponents: Int) {
        guard let job = currentJob, job.ownerID == ownerID else { return }
        // Counts come only from completed engine components. A Core ML load
        // that has not returned must not receive fabricated progress/heartbeats.
        guard totalComponents > 0, completedComponents >= 0,
              completedComponents <= totalComponents else { return }
        job.phase = phase
        job.completedComponents = completedComponents
        job.totalComponents = totalComponents
        reportProgress(job)
    }

    func cancel(ownerID: UUID) {
        guard let job = currentJob, job.ownerID == ownerID else { return }
        cancel(job: job, reason: "Model preparation cancelled.")
    }

    private func attach(_ grant: any ModelPreparationGrant, identifier: String) {
        guard let job = currentJob, job.identifier == identifier, job.acceptsGrant, job.grant == nil else {
            grant.complete(success: false)
            return
        }
        job.grant = grant
        grant.setExpiration { [weak self] in
            guard let self, let current = self.currentJob, current.identifier == identifier else { return }
            self.cancel(job: current, reason: "iOS ended or cancelled background preparation. Retry while LocalScribe is open.")
        }
        reportProgress(job)
        job.onStatus(.running)
    }

    private func reportProgress(_ job: Job) {
        job.grant?.update(title: "Prepare \(job.modelName)", phase: job.phase,
                          completedComponents: job.completedComponents, totalComponents: job.totalComponents)
    }

    private func cancel(job: Job, reason: String) {
        guard currentJob?.identifier == job.identifier else { return }
        currentJob = nil
        scheduler.cancel(identifier: job.identifier)
        job.submission?.cancel()
        job.operation?.cancel()
        job.cancelOwned()
        job.grant?.complete(success: false)
        job.grant = nil
        job.onStatus(.cancelled(reason))
    }

    private func finish(identifier: String, status: Status, success: Bool) {
        guard let job = currentJob, job.identifier == identifier else { return }
        currentJob = nil
        scheduler.cancel(identifier: identifier)
        job.grant?.complete(success: success)
        job.grant = nil
        job.onStatus(status)
        // Ready references remain owned by the controller, not by this grant.
    }
}

@MainActor
protocol ModelPreparationGrant: AnyObject {
    func setExpiration(_ handler: @escaping @MainActor @Sendable () -> Void)
    func update(title: String, phase: String, completedComponents: Int, totalComponents: Int)
    func complete(success: Bool)
}

@MainActor
protocol ModelPreparationScheduling: AnyObject {
    var unavailableReason: String? { get }
    func register(identifier: String, launch: @escaping @MainActor @Sendable (any ModelPreparationGrant) -> Void) -> Bool
    func submit(identifier: String, modelName: String) async throws
    func cancel(identifier: String)
    func refusalMessage(for error: Error) -> String
}

@MainActor
private final class ForegroundModelPreparationScheduler: ModelPreparationScheduling {
    var unavailableReason: String? { "Background preparation requires iOS 26 or later. Keep LocalScribe open until Ready." }
    func register(identifier: String, launch: @escaping @MainActor @Sendable (any ModelPreparationGrant) -> Void) -> Bool { false }
    func submit(identifier: String, modelName: String) async throws {}
    func cancel(identifier: String) {}
    func refusalMessage(for error: Error) -> String { error.localizedDescription }
}

#if os(iOS)
@available(iOS 26.0, *)
@MainActor
private final class NativeModelPreparationScheduler: ModelPreparationScheduling {
    var unavailableReason: String? { nil }

    func register(identifier: String, launch: @escaping @MainActor @Sendable (any ModelPreparationGrant) -> Void) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                launch(NativeModelPreparationGrant(task: continued))
            }
        }
    }

    func submit(identifier: String, modelName: String) async throws {
        // iOS 27's submission API captures delayed refusal and must not be
        // invoked from the main thread. Build the request on the worker too.
        try await Task.detached(priority: .userInitiated) {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                title: "Prepare \(modelName)", subtitle: "Preparing model")
            request.strategy = .fail
            request.requiredResources = [] // CPU only; no GPU entitlement.
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
        }.value
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    func refusalMessage(for error: Error) -> String {
        let failure = error as NSError
        let reason: String
        if failure.domain == BGTaskScheduler.errorDomain {
            switch failure.code {
            case BGTaskScheduler.Error.Code.unavailable.rawValue:
                reason = "Background preparation is unavailable in the current system settings."
            case BGTaskScheduler.Error.Code.tooManyPendingTaskRequests.rawValue:
                reason = "iOS is already handling other background work."
            case BGTaskScheduler.Error.Code.notPermitted.rawValue:
                reason = "iOS did not permit background preparation."
            case BGTaskScheduler.Error.Code.immediateRunIneligible.rawValue:
                reason = "iOS cannot start background preparation under current system conditions."
            default:
                reason = "Background preparation was refused: \(failure.localizedDescription)"
            }
        } else {
            reason = "Background preparation was refused: \(failure.localizedDescription)"
        }
        return "\(reason) Keep LocalScribe open until Ready."
    }
}

@available(iOS 26.0, *)
@MainActor
private final class NativeModelPreparationGrant: ModelPreparationGrant {
    private let task: BGContinuedProcessingTask
    private var completed = false

    init(task: BGContinuedProcessingTask) { self.task = task }

    func setExpiration(_ handler: @escaping @MainActor @Sendable () -> Void) {
        task.expirationHandler = { Task { @MainActor in handler() } }
    }

    func update(title: String, phase: String, completedComponents: Int, totalComponents: Int) {
        guard !completed else { return }
        task.updateTitle(title, subtitle: phase)
        // Zero means the engine has not provided a component count yet.
        task.progress.totalUnitCount = Int64(totalComponents)
        task.progress.completedUnitCount = Int64(completedComponents)
    }

    func complete(success: Bool) {
        guard !completed else { return }
        completed = true
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
    }
}
#endif
