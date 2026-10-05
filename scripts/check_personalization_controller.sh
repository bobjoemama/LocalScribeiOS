#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-personalization-check.XXXXXX")"
cd "$project_root"
python3 - "$check_output/Fixtures.swift" <<'PY'
import sys
source = open('scripts/checks/AppControllerLifecycleCheck.swift').read().split('@main struct AppControllerLifecycleCheck')[0]
open(sys.argv[1], 'w').write(source)
PY
swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$check_output/libLocalScribeCore.dylib" -emit-module-path "$check_output/LocalScribeCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$check_output" -L "$check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$check_output" SharedKeyboard/KeyboardProtocol.swift LocalScribeApp/KeyboardSessionCoordinator.swift LocalScribeApp/AppController.swift "$check_output/Fixtures.swift" scripts/checks/PersonalizationControllerCheck.swift -o "$check_output/personalization-check"
"$check_output/personalization-check"
