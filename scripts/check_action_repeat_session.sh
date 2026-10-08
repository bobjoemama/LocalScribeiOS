#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-action-repeat-check.XXXXXX")"
trap 'rm -rf "$check_output"' EXIT
cd "$project_root"
# Reuse platform fixtures; exclude the existing controller check's @main runner.
python3 - "$check_output/PlatformFixtures.swift" "$check_output/Runtime.swift" "$check_output/ActivityFixtures.swift" <<'PY'
import sys
s=open('scripts/checks/AppControllerLifecycleCheck.swift').read().split('@main struct AppControllerLifecycleCheck')[0]
s=s.replace('static let didReceiveMemoryWarningNotification', 'enum State { case active, background }\n    var applicationState = State.active\n    static let didBecomeActiveNotification = Notification.Name("ShortcutFixtureForeground")\n    static let didReceiveMemoryWarningNotification')
open(sys.argv[1], 'w').write(s)
# ActivityKit's intent marker is iOS-only; its perform/runtime code stays unchanged.
r=open('SharedActivity/StopLiveDictationIntent.swift').read().replace(': LiveActivityIntent, AudioRecordingIntent {', ': AudioRecordingIntent {')
open(sys.argv[2], 'w').write(r)
open(sys.argv[3], 'w').write(open('scripts/checks/ActionShortcutCheck.swift').read().split('@main struct ActionShortcutCheck')[0])
PY
swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$check_output/libLocalScribeCore.dylib" -emit-module-path "$check_output/LocalScribeCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$check_output" -L "$check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$check_output" LocalScribeApp/LocalModelEngine.swift LocalScribeApp/PerformanceMetrics.swift LocalScribeApp/ModelIntegrity.swift LocalScribeApp/ModelPerformanceStore.swift LocalScribeApp/BackgroundModelPreparation.swift SharedKeyboard/KeyboardProtocol.swift LocalScribeApp/KeyboardSessionCoordinator.swift LocalScribeApp/AppController.swift "$check_output/Runtime.swift" LocalScribeApp/DictationShortcuts.swift LocalScribeApp/DictationActionBridge.swift "$check_output/PlatformFixtures.swift" "$check_output/ActivityFixtures.swift" scripts/checks/ActionRepeatSessionCheck.swift -o "$check_output/action-check"
"$check_output/action-check"

# Typecheck the real iOS 27 branches and native intent protocols without building,
# signing, installing or executing the phone app.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir "$check_output/ios"
python3 - "$check_output" <<'PYIOS'
from pathlib import Path
import sys
out=Path(sys.argv[1])
s=(out/'PlatformFixtures.swift').read_text().replace('case active, background', 'case active, background, inactive')
(out/'ios/PlatformFixtures.swift').write_text(s)
s=(out/'ActivityFixtures.swift').read_text()
s=s.replace('protocol LiveActivityIntent: AppIntent {}\n', '')
s=s.replace('@MainActor enum AppContext { static let shared = 0 }', '@MainActor final class AppContext { static let shared = AppContext(); var actionBridge: DictationActionBridge { fatalError("Typecheck fixture") } }')
(out/'ios/ActivityFixtures.swift').write_text(s)
PYIOS
xcrun --sdk iphoneos swiftc -swift-version 6 -target arm64-apple-ios27.0 -sdk "$ios_sdk" -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -emit-module-path "$check_output/ios/LocalScribeCore.swiftmodule"
xcrun --sdk iphoneos swiftc -swift-version 6 -target arm64-apple-ios27.0 -sdk "$ios_sdk" -parse-as-library -I "$check_output/ios" -typecheck LocalScribeApp/LocalModelEngine.swift LocalScribeApp/PerformanceMetrics.swift LocalScribeApp/ModelIntegrity.swift LocalScribeApp/ModelPerformanceStore.swift LocalScribeApp/BackgroundModelPreparation.swift SharedKeyboard/KeyboardProtocol.swift LocalScribeApp/KeyboardSessionCoordinator.swift LocalScribeApp/AppController.swift SharedActivity/StopLiveDictationIntent.swift LocalScribeApp/DictationShortcuts.swift LocalScribeApp/DictationActionBridge.swift "$check_output/ios/PlatformFixtures.swift" "$check_output/ios/ActivityFixtures.swift"
echo "PASS: iOS 27 native intent/runtime/bridge/controller typecheck"
