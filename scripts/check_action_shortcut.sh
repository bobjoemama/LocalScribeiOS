#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-action-check.XXXXXX")"
cd "$project_root"
# Reuse platform fixtures; exclude the existing controller check's @main runner.
python3 - "$check_output/PlatformFixtures.swift" "$check_output/Runtime.swift" <<'PY'
import sys
s=open('scripts/checks/AppControllerLifecycleCheck.swift').read().split('@main struct AppControllerLifecycleCheck')[0]
s=s.replace('static let didReceiveMemoryWarningNotification', 'enum State { case active, background }\n    var applicationState = State.active\n    static let didBecomeActiveNotification = Notification.Name("ShortcutFixtureForeground")\n    static let didReceiveMemoryWarningNotification')
open(sys.argv[1], 'w').write(s)
# ActivityKit's intent marker is iOS-only; its perform/runtime code stays unchanged.
r=open('SharedActivity/StopLiveDictationIntent.swift').read().replace(': LiveActivityIntent, AudioRecordingIntent {', ': AudioRecordingIntent {')
open(sys.argv[2], 'w').write(r)
PY
swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$check_output/libLocalScribeCore.dylib" -emit-module-path "$check_output/LocalScribeCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$check_output" -L "$check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$check_output" SharedKeyboard/KeyboardProtocol.swift LocalScribeApp/KeyboardSessionCoordinator.swift LocalScribeApp/AppController.swift "$check_output/Runtime.swift" LocalScribeApp/DictationShortcuts.swift LocalScribeApp/DictationActionBridge.swift "$check_output/PlatformFixtures.swift" scripts/checks/ActionShortcutCheck.swift -o "$check_output/action-check"
"$check_output/action-check"
