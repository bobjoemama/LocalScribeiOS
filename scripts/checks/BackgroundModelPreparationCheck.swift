import Foundation

@MainActor final class PreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class PreparationGrantFixture: ModelPreparationGrant {
    var expiration: (@MainActor @Sendable () -> Void)?
    var completed: [Bool] = []
    var progress: [(String, String, Int, Int)] = []
    func setExpiration(_ handler: @escaping @MainActor @Sendable () -> Void) { expiration = handler }
    func update(title: String, phase: String, completedComponents: Int, totalComponents: Int) {
        progress.append((title, phase, completedComponents, totalComponents))
    }
    func complete(success: Bool) { completed.append(success) }
}

@MainActor final class PreparationSchedulerFixture: ModelPreparationScheduling {
    var unavailableReason: String?
    var allowsRegistration = true
    var error: Error?
    var submitGate: PreparationGate?
    var registered: [String] = []
    var submitted: [String] = []
    var cancelled: [String] = []
    var handlers: [String: @MainActor @Sendable (any ModelPreparationGrant) -> Void] = [:]
    func register(identifier: String, launch: @escaping @MainActor @Sendable (any ModelPreparationGrant) -> Void) -> Bool {
        precondition(!registered.contains(identifier), "Duplicate registration would terminate a native app")
        registered.append(identifier)
        handlers[identifier] = launch
        return allowsRegistration
    }
    func submit(identifier: String, modelName: String) async throws {
        submitted.append(identifier)
        if let submitGate { await submitGate.wait() }
        if let error { throw error }
    }
    func cancel(identifier: String) { cancelled.append(identifier) }
    func refusalMessage(for error: Error) -> String { "System refused: \(error.localizedDescription). Keep LocalScribe open until Ready." }
    func grant(_ identifier: String) -> PreparationGrantFixture {
        let grant = PreparationGrantFixture()
        handlers[identifier]!(grant)
        return grant
    }
}

@main struct BackgroundModelPreparationCheck {
    @MainActor static func main() async {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
        }
        func eventually(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<1_000 {
                if condition() { return }
                await Task.yield()
            }
            preconditionFailure("Fixture did not reach expected actor state")
        }
        // No scheduler registration at construction. Repeated Prepare on the
        // same flight joins once; the launch grant never invokes operation.
        let scheduler = PreparationSchedulerFixture()
        let helper = BackgroundModelPreparation(scheduler: scheduler, bundleIdentifier: "com.fixture.app")
        check(scheduler.registered.isEmpty, "initialization does not schedule prewarm")
        var statuses: [BackgroundModelPreparation.Status] = []
        var joins = 0
        var cancels = 0
        let owner = UUID()
        let operationGate = PreparationGate()
        let operation: @MainActor @Sendable () async throws -> Void = {
            joins += 1
            await operationGate.wait()
        }
        let onStatus: @MainActor @Sendable (BackgroundModelPreparation.Status) -> Void = { statuses.append($0) }
        let cancelOwned: @MainActor @Sendable () -> Void = { cancels += 1 }
        helper.begin(ownerID: owner, modelName: "Phonon 2", operation: operation, cancelOwned: cancelOwned, onStatus: onStatus)
        helper.begin(ownerID: owner, modelName: "Phonon 2", operation: operation, cancelOwned: cancelOwned, onStatus: onStatus)
        await eventually { operationGate.entered && scheduler.submitted.count == 1 }
        check(joins == 1 && scheduler.registered.count == 1, "same flight registers and joins once")
        let identifier = scheduler.registered[0]
        check(identifier.hasPrefix("com.fixture.app.prepareModel."), "identifier uses actual bundle and semantic context")
        check(UUID(uuidString: String(identifier.split(separator: ".").last!)) != nil, "full identifier has UUID suffix")
        helper.updateProgress(ownerID: owner, phase: "Loading encoder", completedComponents: 2, totalComponents: 5)
        let grant = scheduler.grant(identifier)
        check(joins == 1, "grant attaches to existing flight")
        check(statuses == [.submitted, .running], "request vs granted state distinguished")
        check(grant.progress.last?.2 == 2 && grant.progress.last?.3 == 5, "grant catches up to actual components")
        check(grant.progress.last?.1 == "Loading encoder" && grant.progress.last?.0 == "Prepare Phonon 2", "real phase and frozen model shown")
        helper.updateProgress(ownerID: UUID(), phase: "Wrong model", completedComponents: 5, totalComponents: 5)
        helper.updateProgress(ownerID: owner, phase: "Invalid count", completedComponents: 6, totalComponents: 5)
        check(grant.progress.count == 1, "foreign and invalid progress ignored")
        let staleExpiration = grant.expiration
        operationGate.release()
        await eventually { statuses.last == .ready }
        check(grant.completed == [true], "Ready ends grant exactly once")
        check(cancels == 0, "Ready retains controller model")
        staleExpiration?()
        helper.cancel(ownerID: owner)
        check(grant.completed == [true] && cancels == 0, "expiry and cancel after Ready are inert")

        // Replacing one request must not let its expiry/completion cancel the
        // next preparation, even if a caller accidentally reuses an owner ID.
        let firstGate = PreparationGate()
        let nextGate = PreparationGate()
        var firstCancelled = 0
        var nextCancelled = 0
        var firstStates: [BackgroundModelPreparation.Status] = []
        var nextStates: [BackgroundModelPreparation.Status] = []
        helper.begin(ownerID: owner, modelName: "Old", operation: { await firstGate.wait() }, cancelOwned: { firstCancelled += 1 }, onStatus: { firstStates.append($0) })
        await eventually { firstGate.entered }
        let firstID = scheduler.registered.last!
        let firstGrant = scheduler.grant(firstID)
        let firstExpiration = firstGrant.expiration!
        helper.cancel(ownerID: owner)
        helper.begin(ownerID: owner, modelName: "New", operation: { await nextGate.wait() }, cancelOwned: { nextCancelled += 1 }, onStatus: { nextStates.append($0) })
        await eventually { nextGate.entered }
        let nextID = scheduler.registered.last!
        let nextGrant = scheduler.grant(nextID)
        check(nextID != firstID, "repeat action never re-registers a full identifier")
        firstExpiration()
        firstGate.release()
        await Task.yield()
        check(firstCancelled == 1 && nextCancelled == 0, "old expiration and operation completion cannot cancel new flight")
        check(firstGrant.completed == [false] && nextGrant.completed.isEmpty, "old completion never completes new grant")
        nextGrant.expiration?()
        nextGrant.expiration?()
        check(nextCancelled == 1 && nextGrant.completed == [false], "expiration cancels only owned flight and completes once")
        check(nextStates.last == .cancelled("iOS ended or cancelled background preparation. Retry while LocalScribe is open."), "expiry reason remains readable")
        nextGate.release()
        let lateGrant = scheduler.grant(firstID)
        check(lateGrant.completed == [false], "late launch of obsolete request is retired")

        // A new owner replaces the current one and old user cancellation is inert.
        let replacementGate = PreparationGate()
        let replacementOwner = UUID()
        var replacementCancelled = 0
        helper.begin(ownerID: owner, modelName: "Replace me", operation: { await replacementGate.wait() }, cancelOwned: { firstCancelled += 1 }, onStatus: { _ in })
        await eventually { replacementGate.entered }
        helper.begin(ownerID: replacementOwner, modelName: "Replacement", operation: {}, cancelOwned: { replacementCancelled += 1 }, onStatus: { _ in })
        helper.cancel(ownerID: owner)
        replacementGate.release()
        await Task.yield()
        check(firstCancelled == 2 && replacementCancelled == 0, "replacement cancellation is fenced by owner")

        // Refusal keeps the existing foreground operation alive without claiming
        // a background grant. Error descriptions come from the scheduler.
        let refusedScheduler = PreparationSchedulerFixture()
        refusedScheduler.error = NSError(domain: "Fixture", code: 4, userInfo: [NSLocalizedDescriptionKey: "Busy"])
        let refused = BackgroundModelPreparation(scheduler: refusedScheduler, bundleIdentifier: "com.fixture.app")
        let refusalGate = PreparationGate()
        var refusedStates: [BackgroundModelPreparation.Status] = []
        var refusedCancellation = 0
        refused.begin(ownerID: UUID(), modelName: "CPU", operation: { await refusalGate.wait() }, cancelOwned: { refusedCancellation += 1 }, onStatus: { refusedStates.append($0) })
        await eventually { refusedStates.contains(.foregroundOnly("System refused: Busy. Keep LocalScribe open until Ready.")) && refusalGate.entered }
        check(refusedCancellation == 0, "refusal preserves foreground flight")
        let refusedLateGrant = refusedScheduler.grant(refusedScheduler.registered[0])
        check(refusedLateGrant.completed == [false], "rejected request cannot acquire a late grant")
        refusalGate.release()
        await eventually { refusedStates.last == .ready }
        check(refusedScheduler.submitted.count == 1, "refusal does not queue or retry request")

        let unavailableScheduler = PreparationSchedulerFixture()
        unavailableScheduler.unavailableReason = "Requires iOS 26. Keep open until Ready."
        let unavailable = BackgroundModelPreparation(scheduler: unavailableScheduler, bundleIdentifier: "com.fixture.app")
        var unavailableStates: [BackgroundModelPreparation.Status] = []
        unavailable.begin(ownerID: UUID(), modelName: "CPU", operation: {}, cancelOwned: {}, onStatus: { unavailableStates.append($0) })
        await eventually { unavailableStates.last == .ready }
        check(unavailableScheduler.registered.isEmpty && unavailableScheduler.submitted.isEmpty, "old OS does not register or submit")
        check(unavailableStates.first == .foregroundOnly("Requires iOS 26. Keep open until Ready."), "old OS clearly requires foreground")

        let unregisteredScheduler = PreparationSchedulerFixture()
        unregisteredScheduler.allowsRegistration = false
        let unregistered = BackgroundModelPreparation(scheduler: unregisteredScheduler, bundleIdentifier: "com.fixture.app")
        var unregisteredStates: [BackgroundModelPreparation.Status] = []
        unregistered.begin(ownerID: UUID(), modelName: "CPU", operation: {}, cancelOwned: {}, onStatus: { unregisteredStates.append($0) })
        await eventually { unregisteredStates.last == .ready }
        check(unregisteredScheduler.submitted.isEmpty, "failed registration cannot submit")
        check(unregisteredStates.first == .foregroundOnly("Background preparation is not registered. Keep LocalScribe open until Ready."), "registration fallback is visible")

        let failingScheduler = PreparationSchedulerFixture()
        let failing = BackgroundModelPreparation(scheduler: failingScheduler, bundleIdentifier: "com.fixture.app")
        let failGate = PreparationGate()
        var failStates: [BackgroundModelPreparation.Status] = []
        failing.begin(ownerID: UUID(), modelName: "Broken", operation: {
            await failGate.wait()
            throw NSError(domain: "Fixture", code: 8, userInfo: [NSLocalizedDescriptionKey: "Load failed"])
        }, cancelOwned: {}, onStatus: { failStates.append($0) })
        await eventually { failGate.entered }
        let failGrant = failingScheduler.grant(failingScheduler.registered[0])
        failGate.release()
        await eventually { failStates.last == .failed("Load failed") }
        check(failGrant.completed == [false], "engine failure ends grant once with false")

        // iOS 27 may resolve submission after foreground work finishes.
        let delayedScheduler = PreparationSchedulerFixture()
        let delayedSubmit = PreparationGate()
        delayedScheduler.submitGate = delayedSubmit
        let delayed = BackgroundModelPreparation(scheduler: delayedScheduler, bundleIdentifier: "com.fixture.app")
        var delayedStates: [BackgroundModelPreparation.Status] = []
        delayed.begin(ownerID: UUID(), modelName: "Fast", operation: {}, cancelOwned: {}, onStatus: { delayedStates.append($0) })
        await eventually { delayedStates.last == .ready && delayedSubmit.entered }
        let delayedID = delayedScheduler.registered[0]
        delayedSubmit.release()
        await eventually { delayedScheduler.cancelled.filter { $0 == delayedID }.count == 2 }
        check(delayedStates == [.submitted, .ready], "late submission does not overwrite Ready")
        check(delayedScheduler.grant(delayedID).completed == [false], "late grant does not restart work")

        let lateErrorScheduler = PreparationSchedulerFixture()
        let lateErrorGate = PreparationGate()
        lateErrorScheduler.submitGate = lateErrorGate
        lateErrorScheduler.error = NSError(domain: "Fixture", code: 4)
        let lateError = BackgroundModelPreparation(scheduler: lateErrorScheduler, bundleIdentifier: "com.fixture.app")
        var lateErrorStates: [BackgroundModelPreparation.Status] = []
        lateError.begin(ownerID: UUID(), modelName: "Fast", operation: {}, cancelOwned: {}, onStatus: { lateErrorStates.append($0) })
        await eventually { lateErrorStates.last == .ready && lateErrorGate.entered }
        lateErrorGate.release()
        await Task.yield()
        await Task.yield()
        check(lateErrorStates == [.submitted, .ready], "late submission refusal does not overwrite Ready")
        print("PASS: \(checks) model preparation coordinator checks")
    }
}
