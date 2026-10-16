#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-controller-check.XXXXXX")"
trap 'rm -rf "$check_output"' EXIT
cd "$project_root"
swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$check_output/libLocalScribeCore.dylib" -emit-module-path "$check_output/LocalScribeCore.swiftmodule"
# Suspend production lifecycle Tasks at their scheduling boundaries. Keep captured
# ownership, guards and stop/cancel implementations unchanged for A -> B replay.
python3 - "$check_output/AppController.swift" "$check_output/LifecycleCheck.swift" "$@" <<'PYFIXTURE'
from pathlib import Path
import sys
import os
source = Path(os.environ.get("LOCALSCRIBE_CONTROLLER_SOURCE", "LocalScribeApp/AppController.swift")).read_text()
needle = """        Task { @MainActor [weak self] in
            guard let self, self.recordingID == id, self.phase == .recording else { return }
            await self.stopRecording(endKeyboardSession: endKeyboardSession)
"""
assert source.count(needle) == 1, "Production recording-stop scheduling boundary changed"
source = source.replace(needle, needle.replace("            guard let self", "            await FixtureAudioEventGate.wait()\n            guard let self"))
preparation_needle = """        Task { @MainActor [weak self] in
            guard let self, self.microphoneRevision == revision, self.phase == .preparing else { return }
            await self.cancelPreparation()
"""
assert source.count(preparation_needle) == 1, "Production preparation scheduling boundary changed"
source = source.replace(preparation_needle, preparation_needle.replace("            guard let self", "            await FixtureAudioEventGate.wait()\n            guard let self"))
prewarm_needle = """        Task { [weak self] in
            guard let self, self.keepModelLoaded, self.foreground, self.phase == .idle,
"""
assert source.count(prewarm_needle) == 1, "Production prewarm scheduling boundary changed"
source = source.replace(prewarm_needle, prewarm_needle.replace("            guard let self", "            await FixturePrewarmGate.wait()\n            guard let self"))
Path(sys.argv[1]).write_text(source)
fixture = Path("scripts/checks/AppControllerLifecycleCheck.swift").read_text()
if sys.argv[3:] == ["--late-microphone-warning"]:
    # Keep the actual boundary doubles and selected production-controller test;
    # unrelated large async scenarios need no constraint-solving for this check.
    main = fixture.index("@main struct AppControllerLifecycleCheck {")
    header_end = fixture.index("    @MainActor static func eventually", main)
    def method(name, following):
        start = fixture.index("    @MainActor static func " + name + "(")
        end = fixture.index("    @MainActor static func " + following + "(", start)
        return fixture[start:end]
    fixture = (fixture[:header_end]
        + method("fixture", "checkExplicitMicrophoneActionCycles")
        + method("waitForMicrophoneEnd", "checkDefaultBackgroundDictation")
        + method("checkLateMicrophoneWarnings", "main")
        + r"""    @MainActor static func main() async {
        do {
            try await checkLateMicrophoneWarnings()
            print("PASS: \(checks) late microphone warning checks")
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
""")
Path(sys.argv[2]).write_text(fixture)
PYFIXTURE
swiftc -swift-version 6 -parse-as-library -I "$check_output" -L "$check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$check_output" LocalScribeApp/LocalModelEngine.swift LocalScribeApp/PerformanceMetrics.swift LocalScribeApp/ModelIntegrity.swift LocalScribeApp/ModelPerformanceStore.swift LocalScribeApp/BackgroundModelPreparation.swift SharedKeyboard/KeyboardProtocol.swift LocalScribeApp/KeyboardSessionCoordinator.swift "$check_output/AppController.swift" "$check_output/LifecycleCheck.swift" -o "$check_output/controller-check"
"$check_output/controller-check" "$@"
