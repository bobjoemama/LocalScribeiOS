#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-background-preparation-check.XXXXXX")"
trap 'rm -rf "$check_output"' EXIT
cd "$project_root"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 6 -parse-as-library LocalScribeApp/BackgroundModelPreparation.swift scripts/checks/BackgroundModelPreparationCheck.swift -o "$check_output/check"
"$check_output/check"
ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
for ios_version in 18.0 26.0 27.0; do
    xcrun --sdk iphoneos swiftc -swift-version 6 -target "arm64-apple-ios${ios_version}" -sdk "$ios_sdk" -parse-as-library -typecheck LocalScribeApp/BackgroundModelPreparation.swift
    echo "PASS: iOS ${ios_version} native background preparation typecheck"
done
python3 - <<'PY'
import plistlib
from pathlib import Path
info = plistlib.loads(Path('Configuration/App-Info.plist').read_bytes())
assert info['BGTaskSchedulerPermittedIdentifiers'] == ['$(PRODUCT_BUNDLE_IDENTIFIER).prepareModel.*']
assert info['UIBackgroundModes'] == ['audio', 'processing']
entitlements = plistlib.loads(Path('Configuration/App.entitlements').read_bytes())
assert not any('continued-processing' in key for key in entitlements)
print('PASS: wildcard processing configuration and no GPU entitlement')
PY
