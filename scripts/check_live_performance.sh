#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
telemetry_check_output=$(mktemp -d /tmp/localscribe-telemetry-check.XXXXXX)
trap 'rm -rf "$telemetry_check_output"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$telemetry_check_output/libLocalScribeCore.dylib" -emit-module-path "$telemetry_check_output/LocalScribeCore.swiftmodule"
xcrun swiftc -swift-version 6 -parse-as-library -I "$telemetry_check_output" -L "$telemetry_check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$telemetry_check_output" LocalScribeApp/PerformanceMetrics.swift LocalScribeApp/LivePerformanceMonitor.swift scripts/checks/LivePerformanceCheck.swift -o "$telemetry_check_output/live-performance-check"
"$telemetry_check_output/live-performance-check"
