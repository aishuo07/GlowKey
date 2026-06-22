#!/usr/bin/env sh
set -eu

if [ ! -x .build/debug/glowkey ] && [ ! -x .build/release/glowkey ]; then
  echo "GlowKey is not built yet. Run: swift build" >&2
  exit 1
fi

./bin/glowkey help >/dev/null
./bin/glowkey displays >/dev/null
./bin/glowkey doctor >/dev/null
./bin/glowkey status >/dev/null
./bin/glowkey daemon status >/dev/null
./bin/glowkey menubar status >/dev/null
./bin/glowkey hotkeys status >/dev/null
./bin/glowkey debug hardware-probe >/dev/null
./bin/glowkey debug ddc-probe >/dev/null
./bin/glowkey debug profiles >/dev/null
