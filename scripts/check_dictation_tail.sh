#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
tail_check_output=$(mktemp -d /tmp/localscribe-tail-check.XXXXXX)
swiftc -swift-version 6 -parse-as-library SharedActivity/DictationTranscriptTail.swift scripts/checks/DictationTranscriptTailCheck.swift -o "$tail_check_output/tail-check"
"$tail_check_output/tail-check"
