#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-audio-recorder-check.XXXXXX")"
cd "$project_root"
swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$check_output/libLocalScribeCore.dylib" -emit-module-path "$check_output/LocalScribeCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$check_output" -L "$check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$check_output" LocalScribeApp/AudioRecorder.swift scripts/checks/AudioRecorderLifecycleCheck.swift -o "$check_output/audio-recorder-check"
"$check_output/audio-recorder-check"
