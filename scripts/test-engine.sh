#!/usr/bin/env bash
# Runs RouteEngine tests. With full Xcode installed plain `swift test` works;
# with only Command Line Tools, Swift Testing needs its framework paths spelled out.
# Build output lives outside the repo: ~/Desktop is iCloud-synced, and the
# Finder metadata iCloud adds makes ad-hoc code signing of the test bundle fail.
set -euo pipefail
cd "$(dirname "$0")/../Packages/RouteEngine"
SCRATCH="${HOME}/Library/Caches/wander/RouteEngine"
DEV="$(xcode-select -p)"
if [[ "$DEV" == *CommandLineTools* ]]; then
  F="$DEV/Library/Developer/Frameworks"
  L="$DEV/Library/Developer/usr/lib"
  exec swift test --scratch-path "$SCRATCH" -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test --scratch-path "$SCRATCH" "$@"
