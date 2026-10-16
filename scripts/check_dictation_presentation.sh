#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-presentation-check.XXXXXX")"
trap 'rm -rf "$check_output"' EXIT
cd "$project_root"
# Execute the production pure presentation boundary without microphone, UI or model work.
python3 - "$check_output/Presentation.swift" "${1:-LocalScribeApp/DictateView.swift}" <<'PYFIXTURE'
from pathlib import Path
import sys
source = Path(sys.argv[2]).read_text()
start = source.index('enum BackgroundDictationPresentation {')
end = source.index('\n/// Keep a single replacing transcript.', start)
models = Path('Sources/LocalScribeCore/Models.swift').read_text()
phase = models[models.index('public enum DictationPhase:'):models.index('\npublic protocol LocalTranscriptionEngine:')]
Path(sys.argv[1]).write_text(phase + '\n' + source[start:end])
PYFIXTURE
swiftc -swift-version 6 -parse-as-library "$check_output/Presentation.swift" scripts/checks/DictationPresentationCheck.swift -o "$check_output/presentation-check"
"$check_output/presentation-check"
