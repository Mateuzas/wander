#!/usr/bin/env python3
"""Fake the connected iPhone's location so Wander can be tested away from the pilot city.

    scripts/fake-location.py list                     # named places
    scripts/fake-location.py manufaktura              # put the phone at a place
    scripts/fake-location.py walk fabryczna manufaktura [--speed 1.4]
                                                      # walk a real street route
    scripts/fake-location.py clear                    # back to real GPS

Places live in Data/test-places/<city>.json (default city: lodz, override with --city).
`walk` gets a foot route from the public OSM router (routing.openstreetmap.de); only the two
coordinates are sent. Uses `xcrun devicectl`, so the phone must be paired with this Mac.
"""
import argparse
import json
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FOOT_ROUTER = "https://routing.openstreetmap.de/routed-foot/route/v1/foot"
USER_AGENT = "WanderMVP/0.1 (personal walking-route prototype)"


def load_places(city):
    path = ROOT / "Data" / "test-places" / f"{city}.json"
    if not path.exists():
        sys.exit(f"No test places for '{city}' ({path.relative_to(ROOT)})")
    return json.loads(path.read_text())["places"]


def phone_id():
    """UDID of the first paired physical iPhone."""
    with tempfile.NamedTemporaryFile(suffix=".json") as f:
        subprocess.run(["xcrun", "devicectl", "list", "devices", "--quiet", "--json-output", f.name],
                       check=True, capture_output=True)
        devices = json.load(open(f.name))["result"]["devices"]
    for d in devices:
        props, hw = d.get("deviceProperties", {}), d.get("hardwareProperties", {})
        if hw.get("platform") == "iOS" and hw.get("reality") == "physical":
            return hw.get("udid") or d["identifier"]
    sys.exit("No paired iPhone found. Plug it in, unlock it, and trust this Mac.")


def devicectl(*args):
    subprocess.run(["xcrun", "devicectl", "device", "simulate", "location", *args], check=True)


def place(places, key):
    if key not in places:
        sys.exit(f"Unknown place '{key}'. Run: scripts/fake-location.py list")
    return places[key]


def foot_route(a, b):
    url = f"{FOOT_ROUTER}/{a['lon']},{a['lat']};{b['lon']},{b['lat']}?overview=full&geometries=geojson"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        route = json.load(resp)["routes"][0]
    return route, [(lat, lon) for lon, lat in route["geometry"]["coordinates"]]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", help="list | clear | walk | <place>")
    ap.add_argument("places", nargs="*", help="for walk: <from> <to>")
    ap.add_argument("--city", default="lodz")
    ap.add_argument("--speed", type=float, default=1.4, help="walking speed in m/s (default 1.4)")
    args = ap.parse_args()
    places = load_places(args.city)

    if args.command == "list":
        for key, p in places.items():
            print(f"  {key:20} {p['name']}")
        return
    device = phone_id()
    if args.command == "clear":
        devicectl("clear", "--device", device)
        print("Location simulation cleared; the phone uses real GPS again.")
    elif args.command == "walk":
        if len(args.places) != 2:
            sys.exit("usage: scripts/fake-location.py walk <from> <to>")
        a, b = place(places, args.places[0]), place(places, args.places[1])
        route, points = foot_route(a, b)
        minutes = route["distance"] / args.speed / 60
        print(f"Walking {a['name']} → {b['name']}: {route['distance']:.0f} m, "
              f"about {minutes:.0f} min at {args.speed} m/s. Stop with: scripts/fake-location.py clear", flush=True)
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"mode": "distance", "distance": 5.0, "speed": args.speed,
                       "waypoints": [{"latitude": lat, "longitude": lon} for lat, lon in points]}, f)
        devicectl("route", "--device", device, "--route-file", f.name)
    else:
        p = place(places, args.command)
        devicectl("coordinate", "--device", device, "--latitude", str(p["lat"]), "--longitude", str(p["lon"]))
        print(f"Phone is now at {p['name']}. Run 'scripts/fake-location.py clear' to undo.")


if __name__ == "__main__":
    main()
