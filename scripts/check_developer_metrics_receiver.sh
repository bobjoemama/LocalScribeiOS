#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
metrics_check_dir=$(mktemp -d /tmp/localscribe-metrics-receiver.XXXXXX)
trap 'rm -rf "$metrics_check_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$metrics_check_dir/libLocalScribeCore.dylib" -emit-module-path "$metrics_check_dir/LocalScribeCore.swiftmodule"
xcrun swiftc -swift-version 6 -parse-as-library -I "$metrics_check_dir" -L "$metrics_check_dir" -lLocalScribeCore -Xlinker -rpath -Xlinker "$metrics_check_dir" LocalScribeApp/DeveloperMetricsReceiver.swift Tests/Fixtures/DeveloperMetricsReceiverIntegration.swift -o "$metrics_check_dir/receiver-check"
"$metrics_check_dir/receiver-check"
