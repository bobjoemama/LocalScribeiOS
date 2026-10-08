#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
context_check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-context-check.XXXXXX")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$project_root"
# Exercise the production dense loader and reporting method against constructor
# recording fixtures. Only the MLModel boundary and timer are replaced.
python3 - "$context_check_output/EngineContextFixture.swift" <<'PY'
from pathlib import Path
import re, sys
source = Path('LocalScribeApp/LocalModelEngine.swift').read_text()
def method(name):
    start = source.index(name)
    opening = source.index('{', start)
    depth = 1
    index = opening + 1
    while depth:
        if source[index] == '{': depth += 1
        if source[index] == '}': depth -= 1
        index += 1
    return source[start:index].replace('private ', '', 1)
loader = method('private static func loadDensePhonon(')
loader = re.sub(r'\bMLModel\b', 'FixtureCoreMLModel', loader)
loader = loader.replace('EnginePreparationTimer', 'FixturePreparationTimer')
record = method('private func record(')
Path(sys.argv[1]).write_text('import Foundation\nimport CoreML\nimport LocalScribeCore\nfinal class EngineContextFixture {\nvar reports: [EnginePerformanceReport] = []\n' + loader + '\n' + record + '\n}\n')
PY
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -o "$context_check_output/libLocalScribeCore.dylib" -emit-module-path "$context_check_output/LocalScribeCore.swiftmodule"
xcrun swiftc -swift-version 6 -parse-as-library -I "$context_check_output" -L "$context_check_output" -lLocalScribeCore -Xlinker -rpath -Xlinker "$context_check_output" LocalScribeApp/LocalModelEngine.swift LocalScribeApp/PerformanceMetrics.swift LocalScribeApp/ModelIntegrity.swift "$context_check_output/EngineContextFixture.swift" scripts/checks/ModelExecutionContextCheck.swift -o "$context_check_output/context-check"
"$context_check_output/context-check"

# Optional native typecheck uses only already-built pinned dependency modules.
# Usage: check_model_execution_context.sh /path/to/DerivedDataDistribution
if (( $# > 0 )); then
    dependency_root="$1"
    native_products="$dependency_root/Build/Intermediates.noindex/ArchiveIntermediates/LocalScribe/BuildProductsPath/Release-iphoneos"
    ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
    mkdir -p "$context_check_output/ios"
    xcrun --sdk iphoneos swiftc -swift-version 6 -target arm64-apple-ios27.0 -sdk "$ios_sdk" -emit-module -module-name LocalScribeCore Sources/LocalScribeCore/*.swift -emit-module-path "$context_check_output/ios/LocalScribeCore.swiftmodule"
    xcrun --sdk iphoneos swiftc -swift-version 6 -target arm64-apple-ios27.0 -sdk "$ios_sdk" -parse-as-library -I "$context_check_output/ios" -I "$native_products" -I "$native_products/include" -I "$dependency_root/SourcePackages/checkouts/FluidAudio/Sources/FastClusterWrapper/include" -I "$dependency_root/SourcePackages/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include" -typecheck LocalScribeApp/LocalModelEngine.swift LocalScribeApp/ModelIntegrity.swift LocalScribeApp/PinnedModelDownloader.swift LocalScribeApp/MoonshineCPUAdapter.swift LocalScribeApp/PerformanceMetrics.swift
    echo "PASS: iOS 27 production engine/native Core ML typecheck with existing dependency modules"
fi
