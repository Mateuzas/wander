#!/usr/bin/env bash
# Build Wander (Debug) for a paired iPhone (USB or Wi-Fi) and install it with devicectl.
#
#   scripts/install-device.sh [--device <udid|name>] [--launch]
#
#   --device <udid|name>  use this paired iPhone instead of the first reachable one
#                         (USB is preferred over Wi-Fi)
#   --launch              open the app after installing (a locked phone only warns)
#   -h, --help            show this help
#
# Needs full Xcode, a paired iPhone (Developer Mode on), and the signing team in
# App/Config/Signing.local.xcconfig (run `scripts/secrets.sh xcconfig`, see docs/SECRETS.md).
# Derived data goes to ~/Library/Caches/wander/DerivedData: ~/Desktop is iCloud-synced
# and the metadata iCloud adds breaks code signing. Runs from any directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${HOME}/Library/Caches/wander/DerivedData"
APP="$DERIVED/Build/Products/Debug-iphoneos/Wander.app"
BUNDLE_ID="com.mateuzas.wander"

die() { echo "install-device: error: $*" >&2; exit 1; }
warn() { echo "install-device: warning: $*" >&2; }
info() { echo "install-device: $*"; }
usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

device_arg=""
launch=0
while (($#)); do
  case "$1" in
    --device) [[ $# -ge 2 && -n "$2" ]] || die "--device needs a UDID or name"; device_arg="$2"; shift 2 ;;
    --device=*) device_arg="${1#--device=}"; [[ -n "$device_arg" ]] || die "--device needs a UDID or name"; shift ;;
    --launch) launch=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

command -v xcrun >/dev/null || die "xcrun not found; install Xcode"
command -v python3 >/dev/null || die "python3 not found; install Xcode or its Command Line Tools"

[[ -f "$ROOT/App/Config/Signing.local.xcconfig" ]] || die "App/Config/Signing.local.xcconfig is missing.
  Run \`scripts/secrets.sh xcconfig\` to write it (needs your age key, see docs/SECRETS.md)."

# --- Find the phone ---------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
xcrun devicectl list devices --quiet --json-output "$tmp/devices.json" >/dev/null 2>"$tmp/list.err" \
  || die "\`xcrun devicectl list devices\` failed:
$(cat "$tmp/list.err")"

# Prints "<udid>\t<name>\t<transport>" for the chosen phone, or an error code:
# none | not-connected | no-match.
#
# A phone is installable when it is paired and devicectl can reach it: tunnelState
# "connected" (State column "connected") or "disconnected" (State "available (paired)",
# i.e. reachable over USB or Wi-Fi, devicectl opens the tunnel on demand). "unavailable"
# means the Mac cannot see it. Among installable phones, USB ("wired") wins over Wi-Fi
# ("localNetwork"), then an open tunnel over one that still has to be opened.
pick="$(python3 - "$tmp/devices.json" "$device_arg" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
devices = json.load(open(path)).get("result", {}).get("devices", [])
TRANSPORT = {"wired": "USB", "localNetwork": "Wi-Fi", "network": "Wi-Fi"}
phones = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") != "physical" or not hw.get("udid"):
        continue
    conn = d.get("connectionProperties", {})
    tunnel = conn.get("tunnelState")
    paired = conn.get("pairingState", "paired") == "paired"
    transport = conn.get("transportType") or ""
    phones.append({
        "udid": hw["udid"],
        "name": d.get("deviceProperties", {}).get("name", "?"),
        "reachable": paired and tunnel in ("connected", "connecting", "disconnected"),
        "rank": (transport != "wired", tunnel != "connected"),
        "transport": TRANSPORT.get(transport, transport or "unknown transport"),
        "state": "connected" if tunnel == "connected" else "available (paired)",
    })
def out(p):
    print(f'{p["udid"]}\t{p["name"]}\t{p["transport"]}, {p["state"]}')
if want:
    match = [p for p in phones if want in (p["udid"], p["name"])]
    if not match:
        print("no-match\t" + ", ".join(f'{p["name"]} ({p["udid"]})' for p in phones))
    else:
        out(match[0])
    sys.exit(0)
if not phones:
    print("none\t"); sys.exit(0)
reachable = sorted((p for p in phones if p["reachable"]), key=lambda p: p["rank"])
if not reachable:
    print("not-connected\t" + ", ".join(f'{p["name"]} ({p["udid"]})' for p in phones)); sys.exit(0)
out(reachable[0])
PY
)"
udid="${pick%%$'\t'*}"
rest="${pick#*$'\t'}"
name="${rest%%$'\t'*}"
transport=""
[[ "$rest" == *$'\t'* ]] && transport="${rest#*$'\t'}"
case "$udid" in
  none) die "no iPhone is paired with this Mac.
  Connect it by USB, tap Trust on the phone, enable Developer Mode, then try again." ;;
  not-connected) die "no paired iPhone is connected right now (paired: $name).
  Plug it in by USB (or put it on the same Wi-Fi), unlock it, and try again,
  or pass --device <udid|name> to try a specific one anyway." ;;
  no-match) die "no paired iPhone matches '$device_arg' (paired: ${name:-none})." ;;
esac
info "device: $name ($udid) via ${transport:-unknown transport}"

# Explain failures that mention a locked phone; otherwise show devicectl's own output.
locked_hint() { grep -qi 'locked' "$1"; }

# --- Build ------------------------------------------------------------------
info "building Wander (Debug) into $DERIVED"
if ! xcodebuild -project "$ROOT/App/Wander.xcodeproj" -scheme Wander -configuration Debug \
    -destination "id=$udid" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
    -quiet build >"$tmp/build.log" 2>&1; then
  tail -n 40 "$tmp/build.log" >&2
  if locked_hint "$tmp/build.log"; then
    die "build failed: the phone is locked. Unlock it and run this again."
  fi
  die "xcodebuild failed (last 40 lines above). If it is a signing error, check
  App/Config/Signing.local.xcconfig and that Xcode is signed in to your Apple ID."
fi
[[ -d "$APP" ]] || die "build succeeded but $APP is missing"

# --- Install ----------------------------------------------------------------
info "installing on $name"
if ! xcrun devicectl device install app --device "$udid" "$APP" >"$tmp/install.log" 2>&1; then
  cat "$tmp/install.log" >&2
  if locked_hint "$tmp/install.log"; then
    die "install failed: the phone is locked. Unlock it and run this again."
  fi
  die "devicectl install failed (output above)."
fi
info "installed $BUNDLE_ID on $name"

# --- Launch (optional) ------------------------------------------------------
if ((launch)); then
  if xcrun devicectl device process launch --device "$udid" "$BUNDLE_ID" >"$tmp/launch.log" 2>&1; then
    info "launched $BUNDLE_ID"
  elif locked_hint "$tmp/launch.log"; then
    warn "installed, but not launched: the phone is locked. Unlock it and open Wander."
  else
    cat "$tmp/launch.log" >&2
    warn "installed, but launch failed (output above). Open Wander on the phone."
  fi
fi
