import Foundation

@main
struct ProcessLifecycleTests {
    @MainActor
    static func waitUntil(_ label: String, timeout: TimeInterval = 3, condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        precondition(condition(), "Timed out: \(label)")
    }

    @MainActor
    static func main() async {
        let fixture = CommandLine.arguments[1]
        let model = CompanionModel(pythonPath: "/usr/bin/python3", collectorPath: fixture)
        precondition(USBDevice(udid: "PRIVATE-1234", name: "iPhone").displayName == "iPhone (serial …1234)")
        precondition(CompanionDiagnostic.safeMessage("Phone authentication failed. Keep LocalScribe open and copy a fresh pairing code.")?.contains("connection code") == true)
        precondition(CompanionDiagnostic.safeMessage("Import failed: xctrace export failed; check the trace in Instruments locally.") != nil)
        precondition(CompanionDiagnostic.safeMessage("Import failed: [Errno 13] /Users/private/private.trace") == nil)
        precondition(CompanionDiagnostic.safeMessage("token=LSM1-SECRET private transcript") == nil)
        precondition(CompanionDiagnostic.safeMessage(String(repeating: "X", count: 1025)) == nil)
        model.refresh()
        await waitUntil("USB enumeration exit resets busy") { !model.busy }
        precondition(model.devices.first?.udid == "FIXTURE-USB", "Final stdout listing was lost")
        model.selected = "FIXTURE-USB"
        model.code = "exit"
        model.start()
        await waitUntil("immediate collector exit resets busy") { !model.busy }
        precondition(model.code.isEmpty)

        model.code = "diagnostic"
        model.start()
        await waitUntil("failed collector drain") { !model.busy }
        precondition(model.diagnostic?.contains("rejected") == true, "Allowlisted final stderr diagnostic was lost")
        precondition(model.statusTone == .failed)

        model.code = "private-diagnostic"
        model.start()
        await waitUntil("private dependency diagnostic drain") { !model.busy }
        precondition(model.diagnostic == nil, "Private dependency output was retained")
        precondition(!model.status.contains("SECRET"))

        model.code = "oversized-diagnostic"
        model.start()
        await waitUntil("oversized dependency diagnostic drain") { !model.busy }
        precondition(model.diagnostic?.contains("invalid") == true, "Valid diagnostic after oversized line was lost")

        model.code = "graphics-unavailable"
        model.start()
        await waitUntil("partial GPU availability") { model.status.contains("GPU metrics unavailable") }
        precondition(model.statusTone == .warning)
        model.stop()
        await waitUntil("partial measurement Stop") { !model.busy }

        model.code = "sleep"
        model.start()
        await waitUntil("status received") { model.status.contains("usable counters") }
        model.stop()
        await waitUntil("SIGTERM resets busy") { !model.busy }

        // A second run checks that queued callbacks cannot alter a new generation.
        model.code = "ignore-term"
        model.start()
        await waitUntil("second generation running") { model.status.contains("usable counters") }
        var quitCompleted = false
        let started = Date()
        model.prepareToQuit { quitCompleted = true }
        await waitUntil("quit completes after bounded SIGKILL", timeout: 7) { quitCompleted && !model.busy }
        precondition(Date().timeIntervalSince(started) < 7)
        print("PASS: enumeration, immediate exit, bounded/redacted diagnostics, partial GPU status, Stop, generation restart, bounded Quit")
    }
}
