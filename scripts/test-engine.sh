#!/usr/bin/env bash
# Runs RouteEngine tests. With full Xcode installed plain `swift test` works;
# with only Command Line Tools, Swift Testing needs its framework paths spelled out.
set -euo pipefail
cd "$(dirname "$0")/../Packages/RouteEngine"
DEV="$(xcode-select -p)"
if [[ "$DEV" == *CommandLineTools* ]]; then
  F="$DEV/Library/Developer/Frameworks"
  L="$DEV/Library/Developer/usr/lib"
  exec swift test -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
