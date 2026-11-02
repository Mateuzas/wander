#!/usr/bin/env bash
# CI helper: switch to the newest Xcode installed on the runner and report it.
# Warns (GitHub annotation) when it is older than the version we develop with.
set -euo pipefail
WANT="${WANT_XCODE:-27.1}"

newest=""
newest_ver="0"
for app in /Applications/Xcode*.app; do
  [[ -d "$app" ]] || continue
  plist="$app/Contents/Info.plist"
  ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
  [[ -n "$ver" ]] || continue
  # sort -V keeps the highest version seen so far.
  if [[ "$(printf '%s\n%s\n' "$newest_ver" "$ver" | sort -V | tail -1)" == "$ver" && "$ver" != "$newest_ver" ]]; then
    newest="$app"
    newest_ver="$ver"
  fi
done

if [[ -z "$newest" ]]; then
  echo "::error::No Xcode found in /Applications"
  exit 1
fi

sudo xcode-select -s "$newest/Contents/Developer"
xcodebuild -version
swift --version

if [[ "$(printf '%s\n%s\n' "$WANT" "$newest_ver" | sort -V | head -1)" != "$WANT" ]]; then
  echo "::warning::Runner's newest Xcode is $newest_ver, older than $WANT used locally"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "version=$newest_ver" >> "$GITHUB_OUTPUT"
fi
