#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
telemetry_check_output=$(mktemp -d /tmp/localscribe-telemetry-check.XXXXXX)
trap 'rm -rf "$telemetry_check_output"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$telemetry_check_output/libLocalScribeCore.dylib" -emit-module-path "$telemetry_check_output/LocalScribeCore.swiftmodule"
xcrun swiftc -swift-version 6 -parse-as-library -I "$telemetry_check_output" -L "$telemetry_check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$telemetry_check_output" LocalScribeApp/PerformanceMetrics.swift LocalScribeApp/SystemResourceReader.swift LocalScribeApp/LivePerformanceMonitor.swift scripts/checks/LivePerformanceCheck.swift -o "$telemetry_check_output/live-performance-check"
"$telemetry_check_output/live-performance-check"

# Preserve the imported Dispatch callback boundary. Replace only source creation
# and adapt its user-data payload to pressure flags; signal callback completion.
python3 - "$telemetry_check_output/FixtureLivePerformanceMonitor.swift" <<'PYFIX'
from pathlib import Path
import sys
source = Path("LocalScribeApp/LivePerformanceMonitor.swift").read_text()
replacements = {
    "private var pressureSource: (any DispatchSourceMemoryPressure)?": "private var pressureSource: (any DispatchSourceUserDataAdd)?",
    "DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))": "FixturePressureFactory.makeSource(queue: .global(qos: .utility))",
    "guard let events = source?.data else { return }": "guard let rawEvents = source?.data else { return }\n            let events = DispatchSource.MemoryPressureEvent(rawValue: rawEvents)",
    "self.pressure = level\n            }\n        }": "self.pressure = level\n            }\n            FixturePressureFactory.didDeliver()\n        }"
}
for old, new in replacements.items():
    assert source.count(old) == 1, "Production pressure fixture boundary changed"
    source = source.replace(old, new, 1)
Path(sys.argv[1]).write_text(source)
PYFIX
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -parse-as-library -I "$telemetry_check_output" -L "$telemetry_check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$telemetry_check_output" LocalScribeApp/PerformanceMetrics.swift LocalScribeApp/SystemResourceReader.swift "$telemetry_check_output/FixtureLivePerformanceMonitor.swift" scripts/checks/LiveMemoryPressureCheck.swift -o "$telemetry_check_output/memory-pressure-check"
"$telemetry_check_output/memory-pressure-check"

# Negative control: remove only the production handler's explicit Sendable
# boundary. The same off-main event must reproduce the executor assertion trap.
python3 - "$telemetry_check_output/FixtureLivePerformanceMonitor.swift" "$telemetry_check_output/UnsafeLivePerformanceMonitor.swift" <<'PYNEG'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
needle = "source.setEventHandler { @Sendable"
assert source.count(needle) == 1, "Production pressure callback boundary changed"
Path(sys.argv[2]).write_text(source.replace(needle, "source.setEventHandler {", 1))
PYNEG
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -parse-as-library -I "$telemetry_check_output" -L "$telemetry_check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$telemetry_check_output" LocalScribeApp/PerformanceMetrics.swift LocalScribeApp/SystemResourceReader.swift "$telemetry_check_output/UnsafeLivePerformanceMonitor.swift" scripts/checks/LiveMemoryPressureCheck.swift -o "$telemetry_check_output/memory-pressure-negative-control"
python3 - "$telemetry_check_output/memory-pressure-negative-control" <<'PYRUN'
import resource
import signal
import subprocess
import sys
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
result = subprocess.run([sys.argv[1], "--negative-control"], capture_output=True, text=True, timeout=10)
assert result.returncode == -signal.SIGTRAP, (result.returncode, result.stdout, result.stderr)
print("PASS negative control: original inherited-MainActor pressure handler aborts with SIGTRAP on utility Dispatch callback")
PYRUN

# Match the generated Release project: Swift 6, complete checking, -O,
# default nonisolated declarations and iOS 18 deployment with the iOS 27 SDK.
ios_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir "$telemetry_check_output/ios"
xcrun --sdk iphoneos swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-ios18.0 -sdk "$ios_sdk" -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -emit-module-path "$telemetry_check_output/ios/LocalScribeCore.swiftmodule"
xcrun --sdk iphoneos swiftc -swift-version 6 -strict-concurrency=complete -O -target arm64-apple-ios18.0 -sdk "$ios_sdk" -parse-as-library -I "$telemetry_check_output/ios" -typecheck LocalScribeApp/PerformanceMetrics.swift LocalScribeApp/SystemResourceReader.swift LocalScribeApp/LivePerformanceMonitor.swift
printf '%s\n' 'PASS: native iOS Release telemetry typecheck'
