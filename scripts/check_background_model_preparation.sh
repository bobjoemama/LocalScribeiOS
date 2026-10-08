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
# Exercise the exact production setter through a plain Objective-C block
# property, delivered on a real worker queue. Native BGTask cannot be created on
# a host; the native SDK SIL check below separately verifies its real ABI/isolation.
cat > "$check_output/BackgroundPreparationCallbackFixture.h" <<'OBJCH'
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface ImportedPreparationTask : NSObject
@property (copy, nullable) void (^expirationHandler)(void);
@property (atomic, readonly) BOOL expirationWasOffMain;
- (void)fireExpirationOffMain;
@end
NS_ASSUME_NONNULL_END
OBJCH
cat > "$check_output/BackgroundPreparationCallbackFixture.m" <<'OBJCM'
#import "BackgroundPreparationCallbackFixture.h"
@interface ImportedPreparationTask ()
@property (atomic, readwrite) BOOL expirationWasOffMain;
@end
@implementation ImportedPreparationTask
- (void)fireExpirationOffMain {
    void (^callback)(void) = self.expirationHandler;
    NSCAssert(callback != nil, @"No expiration callback installed");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_assert_queue_not(dispatch_get_main_queue());
        self.expirationWasOffMain = YES;
        callback();
    });
}
@end
OBJCM
cat > "$check_output/module.modulemap" <<'MODULE'
module BackgroundPreparationCallbackFixture {
    header "BackgroundPreparationCallbackFixture.h"
    export *
}
MODULE
python3 - "$check_output/CallbackMethodFixture.swift" <<'EXTRACT'
from pathlib import Path
import sys
source = Path('LocalScribeApp/BackgroundModelPreparation.swift').read_text()
start = source.index('    func setExpiration(', source.index('private final class NativeModelPreparationGrant'))
opening = source.index('{', start)
depth, end = 1, opening + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end]
Path(sys.argv[1]).write_text('import Foundation\nimport BackgroundPreparationCallbackFixture\n@MainActor final class CallbackMethodFixture {\nlet task: ImportedPreparationTask\ninit(task: ImportedPreparationTask) { self.task = task }\n' + method + '\n}\n')
EXTRACT
xcrun clang -fobjc-arc -fmodules -c "$check_output/BackgroundPreparationCallbackFixture.m" -o "$check_output/CallbackFixture.o"
xcrun swiftc -swift-version 6 -enable-actor-data-race-checks -parse-as-library -I "$check_output" "$check_output/CallbackMethodFixture.swift" scripts/checks/BackgroundModelPreparationCallbackCheck.swift "$check_output/CallbackFixture.o" -o "$check_output/callback-check"
"$check_output/callback-check"

# Check the compiled production closure at the actual native iOS boundary,
# including debug runtime actor checks. The outer imported callback must be
# nonisolated; only its asynchronous inner Task may require MainActor.
xcrun --sdk iphoneos swiftc -swift-version 6 -enable-actor-data-race-checks -target arm64-apple-ios27.0 -sdk "$ios_sdk" -parse-as-library -Onone -emit-sil LocalScribeApp/BackgroundModelPreparation.swift -o "$check_output/native.sil"
python3 - "$check_output/UnsafeCallback.swift" <<'UNSAFE'
from pathlib import Path
import sys
source = Path('LocalScribeApp/BackgroundModelPreparation.swift').read_text()
safe = 'task.expirationHandler = { @Sendable in Task { @MainActor in handler() } }'
assert source.count(safe) == 1
Path(sys.argv[1]).write_text(source.replace(safe, 'task.expirationHandler = { Task { @MainActor in handler() } }'))
UNSAFE
xcrun --sdk iphoneos swiftc -swift-version 6 -enable-actor-data-race-checks -target arm64-apple-ios27.0 -sdk "$ios_sdk" -parse-as-library -Onone -emit-sil "$check_output/UnsafeCallback.swift" -o "$check_output/unsafe-native.sil"
python3 - "$check_output/native.sil" "$check_output/unsafe-native.sil" <<'SIL'
from pathlib import Path
import sys
sil = Path(sys.argv[1]).read_text()
def closure(name, source=sil):
    marker = '// ' + name + '\n'
    start = source.index(marker)
    end = source.index('} // end sil function', start)
    return source[start:end]
outer = closure('closure #1 in NativeModelPreparationGrant.setExpiration(_:)')
assert '// Isolation: nonisolated' in outer
assert '@convention(thin) @Sendable' in outer
assert 'swift_task_isCurrentExecutor' not in outer
assert '_checkExpectedExecutor' not in outer
inner = closure('closure #1 in closure #1 in NativeModelPreparationGrant.setExpiration(_:)')
assert '// Isolation: global_actor. type: MainActor' in inner
assert 'hop_to_executor' in inner
unsafe = closure('closure #1 in NativeModelPreparationGrant.setExpiration(_:)', Path(sys.argv[2]).read_text())
assert '// Isolation: global_actor. type: MainActor' in unsafe
assert 'swift_task_isCurrentExecutor' in unsafe
print('PASS: actual iOS SDK SIL proves expiration outer block nonisolated and inner Task hops to MainActor')
print('PASS: native SDK SIL negative control detects inherited MainActor check when @Sendable is removed')
SIL

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
