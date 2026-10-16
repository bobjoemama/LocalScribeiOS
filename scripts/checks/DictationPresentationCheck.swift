import Foundation

@main struct DictationPresentationCheck {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { print("FAIL: \(message)"); exit(1) }
            checks += 1
        }
        func status(enabled: Bool = true, denied: Bool = false, starting: Bool = false,
                    downloaded: Bool = true, session: Bool = false, loaded: Bool = true,
                    phase: DictationPhase = .idle, error: Bool = false, downloading: Bool = false) -> String {
            BackgroundDictationPresentation.status(enabled: enabled, microphoneDenied: denied,
                starting: starting, downloaded: downloaded, sessionActive: session, modelLoaded: loaded,
                phase: phase, hasError: error, downloading: downloading)
        }
        check(BackgroundDictationPresentation.modelState(loaded: true, loading: false) == "Model loaded", "A loaded model never promises Action Button readiness")
        check(BackgroundDictationPresentation.modelState(loaded: false, loading: true) == "Loading model…", "A pending model is distinct from a microphone startup")
        check(BackgroundDictationPresentation.modelState(loaded: false, loading: false) == "Not loaded for background", "An absent runtime stays distinct from paused capture")
        check(status(enabled: false) == "Paused · Mic off", "Loaded plus paused does not claim microphone readiness")
        check(status(session: true) == "Ready · Mic on", "An active microphone lease with a loaded model is ready")
        check(status(error: true) == "Interrupted · Mic off", "Automatic failure is interrupted rather than a persisted pause")
        check(status(denied: true) == "Microphone access is off", "Permission recovery overrides readiness")
        check(status(enabled: false, denied: true) == "Microphone access is off", "Permission denial is actionable even while paused")
        check(status(enabled: false, phase: .recording) == "Recording · Mic on", "Explicit recording while standby is paused must not claim the microphone is off")
        check(status(enabled: false, session: true) == "Ready · Mic on", "A separately enabled session remains accurately visible when standby is paused")
        check(status(phase: .transcribing) == "Finishing · Mic off", "Finalization does not imply an idle microphone remains on")
        check(status(session: true, phase: .transcribing) == "Finishing · Mic on", "Finalization preserves an independently active lease")
        check(status(session: true, loaded: false) == "Loading model · Mic on", "Model preparation and microphone ownership are independent")
        check(status(starting: true, loaded: false) == "Starting…", "Automatic startup remains distinct from failure")
        check(status(downloaded: false, loaded: false) == "Choose a downloaded model", "Missing-model recovery stays visible")
        check(status(downloading: true) == "Waiting for download", "Download blocking remains visible")
        print("PASS: \(checks) dictation presentation checks")
    }
}
