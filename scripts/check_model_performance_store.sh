#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-model-performance-check.XXXXXX")"
trap 'rm -rf "$check_output"' EXIT
cd "$project_root"
swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$check_output/libLocalScribeCore.dylib" -emit-module-path "$check_output/LocalScribeCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$check_output" -L "$check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$check_output" LocalScribeApp/LocalModelEngine.swift LocalScribeApp/PerformanceMetrics.swift LocalScribeApp/ModelIntegrity.swift LocalScribeApp/ModelPerformanceStore.swift scripts/checks/ModelPerformanceStoreCheck.swift -o "$check_output/store-check"
"$check_output/store-check"
