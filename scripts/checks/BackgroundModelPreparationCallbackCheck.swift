import Foundation
import BackgroundPreparationCallbackFixture

@main struct BackgroundModelPreparationCallbackCheck {
    @MainActor static func main() async {
        let task = ImportedPreparationTask()
        let fixture = CallbackMethodFixture(task: task)
        var callbackCount = 0
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { preconditionFailure("Off-main expiration never reached MainActor") }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            fixture.setExpiration {
                MainActor.assertIsolated()
                callbackCount += 1
                continuation.resume()
            }
            task.fireExpirationOffMain()
        }
        timeout.cancel()
        precondition(task.expirationWasOffMain, "Imported Objective-C block must execute off the main queue")
        precondition(callbackCount == 1, "Expiration must arrive once on MainActor")
        print("PASS: production expiration callback survives imported Objective-C off-main delivery and hops to MainActor")
    }
}
