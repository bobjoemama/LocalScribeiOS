#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-diagnostics-check.XXXXXX")"
cd "$project_root"
python3 - "$check_output/PlatformFixtures.swift" "$check_output/Runtime.swift" "$check_output/ActivityFixtures.swift" <<'PY'
import sys
s=open('scripts/checks/AppControllerLifecycleCheck.swift').read().split('@main struct AppControllerLifecycleCheck')[0]
s=s.replace('static let didReceiveMemoryWarningNotification', 'enum State { case active, background }\n    var applicationState = State.active\n    static let didBecomeActiveNotification = Notification.Name("DiagnosticFixtureForeground")\n    static let didReceiveMemoryWarningNotification')
open(sys.argv[1], 'w').write(s)
r=open('SharedActivity/StopLiveDictationIntent.swift').read().replace(': LiveActivityIntent, AudioRecordingIntent {', ': AudioRecordingIntent {')
open(sys.argv[2], 'w').write(r)
open(sys.argv[3], 'w').write(open('scripts/checks/ActionShortcutCheck.swift').read().split('@main struct ActionShortcutCheck')[0])
PY
swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$check_output/libLocalScribeCore.dylib" -emit-module-path "$check_output/LocalScribeCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$check_output" -L "$check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$check_output" LocalScribeApp/LocalModelEngine.swift LocalScribeApp/PerformanceMetrics.swift LocalScribeApp/ModelIntegrity.swift LocalScribeApp/ModelPerformanceStore.swift LocalScribeApp/BackgroundModelPreparation.swift SharedKeyboard/KeyboardProtocol.swift LocalScribeApp/KeyboardSessionCoordinator.swift LocalScribeApp/AppController.swift "$check_output/Runtime.swift" LocalScribeApp/DictationShortcuts.swift LocalScribeApp/DictationActionBridge.swift "$check_output/PlatformFixtures.swift" "$check_output/ActivityFixtures.swift" scripts/checks/ActionDiagnosticsCheck.swift -o "$check_output/diagnostics-check"
"$check_output/diagnostics-check"
