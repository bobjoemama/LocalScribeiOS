#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-controller-check.XXXXXX")"
cd "$project_root"
swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$check_output/libLocalScribeCore.dylib" -emit-module-path "$check_output/LocalScribeCore.swiftmodule"
# Suspend production lifecycle Tasks at their scheduling boundaries. Keep captured
# ownership, guards and stop/cancel implementations unchanged for A -> B replay.
python3 - "$check_output/AppController.swift" <<'PYFIXTURE'
from pathlib import Path
import sys
source = Path("LocalScribeApp/AppController.swift").read_text()
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
PYFIXTURE
swiftc -swift-version 6 -parse-as-library -I "$check_output" -L "$check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$check_output" LocalScribeApp/LocalModelEngine.swift LocalScribeApp/PerformanceMetrics.swift LocalScribeApp/ModelIntegrity.swift LocalScribeApp/ModelPerformanceStore.swift LocalScribeApp/BackgroundModelPreparation.swift SharedKeyboard/KeyboardProtocol.swift LocalScribeApp/KeyboardSessionCoordinator.swift "$check_output/AppController.swift" scripts/checks/AppControllerLifecycleCheck.swift -o "$check_output/controller-check"
"$check_output/controller-check"
