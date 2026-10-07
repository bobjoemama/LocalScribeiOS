#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
activity_check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-activity-check.XXXXXX")"
cd "$project_root"
swiftc -swift-version 6 -emit-library -emit-module -module-name ActivityKit scripts/checks/ActivityKitFixture.swift -o "$activity_check_output/libActivityKit.dylib" -emit-module-path "$activity_check_output/ActivityKit.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$activity_check_output" -L "$activity_check_output" -lActivityKit -Xlinker -rpath -Xlinker "$activity_check_output" SharedActivity/DictationActivityAttributes.swift SharedActivity/DictationTranscriptTail.swift LocalScribeApp/DictationLiveActivity.swift scripts/checks/DictationActivityCheck.swift -o "$activity_check_output/activity-check"
"$activity_check_output/activity-check"
