#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-audio-recorder-check.XXXXXX")"
trap 'rm -rf "$check_output"' EXIT
cd "$project_root"
# An isolated source copy allows a focused diagnostic mutation check without
# changing the production file. Normal runs always execute the real recorder.
recorder_source="${1:-LocalScribeApp/AudioRecorder.swift}"
swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$check_output/libLocalScribeCore.dylib" -emit-module-path "$check_output/LocalScribeCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$check_output" -L "$check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$check_output" "$recorder_source" scripts/checks/AudioRecorderLifecycleCheck.swift -o "$check_output/audio-recorder-check"
"$check_output/audio-recorder-check"

# Compile the exact production API usage against the installed iOS SDK; the
# executable above substitutes permission/session/engine boundaries only.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir "$check_output/ios"
xcrun --sdk iphoneos swiftc -swift-version 6 -target arm64-apple-ios27.0 -sdk "$ios_sdk" -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -emit-module-path "$check_output/ios/LocalScribeCore.swiftmodule"
xcrun --sdk iphoneos swiftc -swift-version 6 -target arm64-apple-ios27.0 -sdk "$ios_sdk" -parse-as-library -I "$check_output/ios" -typecheck "$recorder_source"
echo "PASS: iOS 27 native recorder typecheck"
