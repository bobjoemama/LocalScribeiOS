#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-controller-check.XXXXXX")"
cd "$project_root"
swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$check_output/libLocalScribeCore.dylib" -emit-module-path "$check_output/LocalScribeCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$check_output" -L "$check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$check_output" SharedKeyboard/KeyboardProtocol.swift LocalScribeApp/KeyboardSessionCoordinator.swift LocalScribeApp/AppController.swift scripts/checks/AppControllerLifecycleCheck.swift -o "$check_output/controller-check"
"$check_output/controller-check"
