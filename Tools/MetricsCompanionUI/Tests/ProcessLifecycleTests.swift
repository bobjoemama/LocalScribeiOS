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
        model.refresh()
        await waitUntil("USB enumeration exit resets busy") { !model.busy }
        precondition(model.devices.first?.udid == "FIXTURE-USB", "Final stdout listing was lost")
        model.selected = "FIXTURE-USB"
        model.code = "exit"
        model.start()
        await waitUntil("immediate collector exit resets busy") { !model.busy }
        precondition(model.code.isEmpty)

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
        print("PASS: enumeration, immediate exit, Stop, generation restart, bounded Quit")
    }
}
