#!/bin/sh
# Standalone regressions: no model, microphone, accessibility grant or live app.
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/giga-regression.XXXXXXXX)
cleanup() {
    case "$test_dir" in /tmp/giga-regression.????????) rm -rf -- "$test_dir" ;; esac
}
trap cleanup EXIT HUP INT TERM
for optimization in debug optimized; do
    flags=""
    [ "$optimization" = debug ] || flags="-O"
    swiftc $flags -parse-as-library swift/RecordingStart.swift scripts/test-recording-start.swift -o "$test_dir/start"
    "$test_dir/start"
    swiftc $flags -parse-as-library swift/Clipboard.swift scripts/test-clipboard.swift -o "$test_dir/clipboard"
    "$test_dir/clipboard"
    swiftc $flags -parse-as-library swift/Mic.swift scripts/test-mic-lifecycle.swift -o "$test_dir/mic"
    "$test_dir/mic"
    swiftc $flags -parse-as-library swift/BrainCheck.swift scripts/test-brain-check.swift -o "$test_dir/brain-check"
    "$test_dir/brain-check"
    swiftc $flags -parse-as-library swift/WavePanel.swift scripts/test-ax-budget.swift -o "$test_dir/ax"
    "$test_dir/ax"
    swiftc $flags -parse-as-library swift/Dictionary.swift swift/WordForms.swift scripts/test-dictionary.swift -o "$test_dir/dictionary"
    "$test_dir/dictionary"
    swiftc $flags -parse-as-library swift/Dictionary.swift cli/giga-dict.swift -o "$test_dir/giga-dict"
    mkdir "$test_dir/dict-$optimization"
    sh scripts/test-giga-dict.sh "$test_dir/giga-dict" "$test_dir/dict-$optimization"
done
git diff --check
git diff | shasum -a 256
