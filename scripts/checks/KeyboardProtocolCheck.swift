import Foundation

@main
struct KeyboardProtocolCheck {
    enum CheckFailure: Error { case failed(String) }
    static var count = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure.failed(message) }
        count += 1
    }

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let session = UUID()
        let utterance = UUID()
        let ready = KeyboardSessionStatus(sessionID: session, expiresAt: now.addingTimeInterval(300), heartbeatAt: now, phase: .ready)
        try check(ready.isLive(at: now), "Fresh armed session is live")
        try check(ready.isLive(at: now.addingTimeInterval(3)), "Heartbeat boundary is live")
        try check(!ready.isLive(at: now.addingTimeInterval(3.01)), "Stale heartbeat is inactive")
        try check(!ready.isLive(at: now.addingTimeInterval(-2)), "Future heartbeat is inactive")
        let expired = KeyboardSessionStatus(sessionID: session, expiresAt: now, heartbeatAt: now, phase: .ready)
        try check(!expired.isLive(at: now), "Expired lease is inactive")
        try check(!KeyboardSessionStatus().isLive(at: now), "Default status is inactive")
        let inactive = KeyboardSessionStatus(sessionID: session, expiresAt: now.addingTimeInterval(300), heartbeatAt: now, phase: .inactive)
        try check(!inactive.isLive(at: now), "Explicitly inactive status rejects commands")

        let start = KeyboardCommand(sessionID: session, utteranceID: utterance, action: .start, createdAt: now)
        let stop = KeyboardCommand(sessionID: session, utteranceID: utterance, action: .stop, createdAt: now)
        try check(start.isValid(for: ready, now: now), "Fresh start command accepted")
        try check(stop.isValid(for: ready, now: now), "Fresh stop command passes envelope validation")
        try check(start.id != stop.id, "Commands use independent IDs")
        try check(!start.isValid(for: expired, now: now), "Expired session rejects command")
        let delivery = KeyboardSessionStatus(sessionID: session, expiresAt: now, deliveryExpiresAt: now.addingTimeInterval(30), heartbeatAt: now, phase: .ready, utteranceID: utterance, transcript: "Final words")
        try check(delivery.isLive(at: now), "Result delivery remains available after microphone lease ends")
        try check(!delivery.canRecord(at: now), "Delivery grace never authorizes microphone capture")
        try check(!start.isValid(for: delivery, now: now), "Start rejected during delivery grace")
        try check(!stop.isValid(for: delivery, now: now), "Stop rejected after microphone lease ends")
        try check(delivery.hasDeliverableResult(at: now), "Final text is deliverable inside its own lease")
        let suspendedResult = KeyboardSessionStatus(sessionID: session, expiresAt: now, deliveryExpiresAt: now.addingTimeInterval(30), heartbeatAt: now.addingTimeInterval(-20), phase: .ready, utteranceID: utterance, transcript: "Final words")
        try check(suspendedResult.hasDeliverableResult(at: now), "App suspension cannot hide a completed result inside its lease")
        try check(!suspendedResult.isLive(at: now), "Suspended app does not have a live heartbeat")
        try check(!suspendedResult.canRecord(at: now), "Suspended result lease cannot authorize recording")
        try check(!start.isValid(for: suspendedResult, now: now), "Suspended app rejects fresh start commands")
        try check(!suspendedResult.hasDeliverableResult(at: now.addingTimeInterval(30)), "Suspended result expires exactly at delivery deadline")
        let emptyResult = KeyboardSessionStatus(sessionID: session, expiresAt: now, deliveryExpiresAt: now.addingTimeInterval(30), heartbeatAt: now, phase: .ready, utteranceID: utterance, transcript: " \n ")
        try check(!emptyResult.hasDeliverableResult(at: now), "Empty transcript cannot be delivered")
        let unleasedResult = KeyboardSessionStatus(sessionID: session, expiresAt: now.addingTimeInterval(300), heartbeatAt: now, phase: .ready, utteranceID: utterance, transcript: "Old words")
        try check(!unleasedResult.hasDeliverableResult(at: now), "Microphone lease does not substitute for a result delivery lease")
        let deliveryEnding = KeyboardSessionStatus(sessionID: session, expiresAt: now, deliveryExpiresAt: now, heartbeatAt: now, phase: .ready)
        try check(!deliveryEnding.isLive(at: now), "Delivery grace expires exactly at its deadline")
        try check(!KeyboardCommand(sessionID: UUID(), utteranceID: utterance, action: .start, createdAt: now).isValid(for: ready, now: now), "Wrong session rejected")
        try check(!KeyboardCommand(sessionID: session, utteranceID: utterance, action: .start, createdAt: now.addingTimeInterval(-10.01)).isValid(for: ready, now: now), "Stale command rejected")
        try check(!KeyboardCommand(sessionID: session, utteranceID: utterance, action: .start, createdAt: now.addingTimeInterval(1.01)).isValid(for: ready, now: now), "Future command rejected")

        let originalDocument = UUID()
        let otherDocument = UUID()
        var target = KeyboardAutoInsertionTarget()
        try check(!target.allows(utteranceID: utterance, documentIdentifier: originalDocument), "Unarmed target cannot auto-insert")
        target.arm(utteranceID: utterance, documentIdentifier: originalDocument)
        try check(target.allows(utteranceID: utterance, documentIdentifier: originalDocument), "Original utterance and document can auto-insert")
        try check(!target.allows(utteranceID: UUID(), documentIdentifier: originalDocument), "Another utterance cannot auto-insert")
        try check(!target.allows(utteranceID: utterance, documentIdentifier: otherDocument), "Another document cannot auto-insert")
        target.observeDocument(otherDocument)
        target.observeDocument(originalDocument)
        try check(!target.allows(utteranceID: utterance, documentIdentifier: originalDocument), "Switching away and back permanently disarms automatic insertion")
        target.arm(utteranceID: utterance, documentIdentifier: originalDocument)
        target.invalidate()
        try check(!target.allows(utteranceID: utterance, documentIdentifier: originalDocument), "Text/selection input change disarms even within the same document")
        target.arm(utteranceID: utterance, documentIdentifier: originalDocument)
        target.observeDocument(originalDocument)
        try check(target.allows(utteranceID: utterance, documentIdentifier: originalDocument), "Unchanged polling preserves the original target")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalScribeKeyboardCheck-\(UUID().uuidString)", isDirectory: true)
        let store = try SharedKeyboardStore(directory: directory)
        try check(try store.readStatus() == nil, "Missing status returns nil")
        try check(try store.readCommand() == nil, "Missing command returns nil")
        try check(try store.readReceipt() == nil, "Missing receipt returns nil")
        try store.writeStatus(ready)
        try check(try store.readStatus() == ready, "Atomic status round trip")
        let completed = KeyboardSessionStatus(sessionID: session, expiresAt: ready.expiresAt, heartbeatAt: now, phase: .ready, utteranceID: utterance, transcript: "A local dictation.")
        try store.writeStatus(completed)
        try check(try store.readStatus() == completed, "Atomic replacement includes new result")
        try store.writeCommand(start)
        try check(try store.readCommand() == start, "Atomic command round trip")
        try store.writeCommand(stop)
        try check(try store.readCommand() == stop, "Command replacement retains stop and utterance ID")
        let receipt = KeyboardDeliveryReceipt(utteranceID: utterance, consumedAt: now)
        try store.writeReceipt(receipt)
        try check(try store.readReceipt() == receipt, "Delivery receipt survives round trip")
        let restartedStore = try SharedKeyboardStore(directory: directory)
        try check(try restartedStore.readReceipt()?.utteranceID == utterance, "Receipt survives keyboard store recreation")
        try store.writeStatus(KeyboardSessionStatus())
        try check(try store.readStatus()?.transcript == nil, "Disarming overwrites pending transcript")

        let statusURL = directory.appendingPathComponent("KeyboardBridge/status.json")
        try Data("{corrupt".utf8).write(to: statusURL, options: .atomic)
        var rejectedCorruption = false
        do { _ = try store.readStatus() } catch { rejectedCorruption = true }
        try check(rejectedCorruption, "Corrupt status fails closed")
        print("PASS: \(count) keyboard protocol checks (lease, heartbeat, command freshness, session identity, atomic snapshots and delivery receipts)")
    }
}
