#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-note-session-check.XXXXXX")"
trap 'rm -rf "$check_output"' EXIT
cd "$project_root"

# Reuse the established platform/audio/engine fixtures, then exercise the actual
# private session class in the same generated file. No microphone APIs are linked.
python3 - "$check_output/NoteDictationSessionCheck.swift" <<'PY'
from pathlib import Path
import sys
fixtures = Path('scripts/checks/AppControllerLifecycleCheck.swift').read_text().split('@main struct AppControllerLifecycleCheck', 1)[0]
source = Path('LocalScribeApp/NotesView.swift').read_text()
marker = '@MainActor\nprivate final class NoteDictationSession:'
assert source.count(marker) == 1, 'Production Notes session declaration changed; update this check extractor.'
session = marker + source.split(marker, 1)[1]
checks = Path('scripts/checks/NoteDictationSessionCheck.swift').read_text()
Path(sys.argv[1]).write_text(fixtures + '\n' + session + '\n' + checks)
PY

swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$check_output/libLocalScribeCore.dylib" -emit-module-path "$check_output/LocalScribeCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$check_output" -L "$check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$check_output" SharedKeyboard/KeyboardProtocol.swift LocalScribeApp/KeyboardSessionCoordinator.swift LocalScribeApp/AppController.swift LocalScribeApp/NotesController.swift "$check_output/NoteDictationSessionCheck.swift" -o "$check_output/note-session-check"
"$check_output/note-session-check"
