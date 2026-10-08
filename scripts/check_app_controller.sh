#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-controller-check.XXXXXX")"
cd "$project_root"
swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$check_output/libLocalScribeCore.dylib" -emit-module-path "$check_output/LocalScribeCore.swiftmodule"
# Suspend only the production event Task's scheduling boundary. Keep its captured
# recording ID, guard and stop implementation unchanged for deterministic A -> B replay.
python3 - "$check_output/AppController.swift" <<'PYFIXTURE'
from pathlib import Path
import sys
source = Path("LocalScribeApp/AppController.swift").read_text()
needle = """        Task { @MainActor [weak self] in
            guard let self, self.recordingID == id, self.phase == .recording else { return }
            await self.stopRecording(endKeyboardSession: true)
"""
assert source.count(needle) == 1, "Production audio-event scheduling boundary changed"
source = source.replace(needle, needle.replace("            guard let self", "            await FixtureAudioEventGate.wait()\n            guard let self"))
Path(sys.argv[1]).write_text(source)
PYFIXTURE
swiftc -swift-version 6 -parse-as-library -I "$check_output" -L "$check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$check_output" SharedKeyboard/KeyboardProtocol.swift LocalScribeApp/KeyboardSessionCoordinator.swift "$check_output/AppController.swift" scripts/checks/AppControllerLifecycleCheck.swift -o "$check_output/controller-check"
"$check_output/controller-check"
