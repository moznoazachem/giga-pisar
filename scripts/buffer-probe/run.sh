#!/bin/sh
# Does another process raising a device's IO buffer reach our AUHAL callback?
#   sh scripts/buffer-probe/run.sh "MacBook Pro Microphone" 4096
# rec records 5 s and prints, every 0.5 s, the device buffer it sees, its
# MaximumFramesPerSlice and a histogram of callback frames/AudioUnitRender status.
# 1.2 s in, setbuf (a separate process) sets the device buffer and holds it 2 s.
set -eu
cd "$(dirname "$0")"
device=${1:-"MacBook Pro Microphone"}
frames=${2:-4096}
out=$(mktemp -d /tmp/buffer-probe.XXXXXXXX)
swiftc -O -o "$out/rec" common.swift rec/main.swift
swiftc -O -o "$out/setbuf" common.swift setbuf/main.swift
"$out/rec" "$device" &
rec=$!
sleep 1.2
"$out/setbuf" "$device" "$frames"
wait $rec
