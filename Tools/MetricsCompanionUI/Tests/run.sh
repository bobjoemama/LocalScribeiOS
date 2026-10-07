#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_WORK="$(mktemp -d)"
trap 'rm -rf "$TEST_WORK"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 -D METRICS_MODEL_TEST "$TEST_DIR/../MetricsCompanion.swift" "$TEST_DIR/ProcessLifecycleTests.swift" -o "$TEST_WORK/process-tests"
"$TEST_WORK/process-tests" "$TEST_DIR/collector_fixture.py"
