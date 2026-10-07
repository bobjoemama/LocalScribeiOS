#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
UI_DIR="$(cd "$(dirname "$0")" && pwd)"
COLLECTOR_DIR="$(cd "$UI_DIR/../MetricsCompanion" && pwd)"
APP_DIR="$UI_DIR/out/LocalScribe Metrics.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$UI_DIR/Resources/LocalScribe.icns" "$APP_DIR/Contents/Resources/LocalScribe.icns"
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 -O "$UI_DIR/MetricsCompanion.swift" -o "$APP_DIR/Contents/MacOS/MetricsCompanion"
/usr/bin/python3 - "$APP_DIR/Contents/Info.plist" "$COLLECTOR_DIR" <<'PY'
import plistlib, sys
from pathlib import Path
path, collector = sys.argv[1:]
with open(path, 'wb') as output:
    plistlib.dump({
        'CFBundleIdentifier': 'com.devesh.localscribe.metrics',
        'CFBundleName': 'LocalScribe Metrics',
        'CFBundleDisplayName': 'LocalScribe Metrics',
        'CFBundleExecutable': 'MetricsCompanion',
        'CFBundleIconFile': 'LocalScribe',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '1.1',
        'CFBundleVersion': '2',
        'LSMinimumSystemVersion': '14.0',
        'NSHighResolutionCapable': True,
        'CollectorPython': str(Path(collector) / '.venv/bin/python'),
        'CollectorScript': str(Path(collector) / 'collector.py'),
        'TraceScript': str(Path(collector).parent / 'MetricsTrace/metrics_trace.py'),
    }, output)
PY
printf '%s\n' "$APP_DIR"
