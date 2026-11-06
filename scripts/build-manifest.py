#!/usr/bin/env python3
"""Write manifest.json for the published city files (ADR 013, CONTRACTS.md 3b; stdlib only).

usage: scripts/build-manifest.py <dir> [--base-url URL]

Reads every pois-<slug>.json in <dir> and writes <dir>/manifest.json:

  { "schema": 1, "generated": "<now, ISO 8601 UTC>",
    "cities": { "<slug>": { "url": "<base-url>pois-<slug>.json", "sha256": "<hex>",
                            "bytes": N, "pois": N, "generated": "<the file's own generated>" } } }

Exits 1 if <dir> has no city files or a file is not a POI file (no `pois` list or `generated`).
"""
import argparse
import datetime
import hashlib
import json
import re
import sys
from pathlib import Path

SCHEMA = 1
DEFAULT_BASE_URL = "https://mateuzas.github.io/wander/data/v1/"
NAME = re.compile(r"^pois-([a-z0-9-]+)\.json$")


def city_entry(path, base_url):
    raw = path.read_bytes()
    data = json.loads(raw)
    pois = data.get("pois") if isinstance(data, dict) else None
    generated = data.get("generated") if isinstance(data, dict) else None
    if not isinstance(pois, list) or not isinstance(generated, str):
        raise ValueError(f"{path}: not a POI file (needs a `pois` list and a `generated` string)")
    return {
        "url": base_url + path.name,
        "sha256": hashlib.sha256(raw).hexdigest(),
        "bytes": len(raw),
        "pois": len(pois),
        "generated": generated,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("dir", type=Path)
    ap.add_argument("--base-url", default=DEFAULT_BASE_URL)
    args = ap.parse_args()
    base_url = args.base_url if args.base_url.endswith("/") else args.base_url + "/"

    cities = {}
    for path in sorted(args.dir.glob("pois-*.json")):
        m = NAME.match(path.name)
        if not m:
            continue
        try:
            cities[m.group(1)] = city_entry(path, base_url)
        except (ValueError, json.JSONDecodeError) as e:
            print(f"build-manifest: {e}", file=sys.stderr)
            return 1
    if not cities:
        print(f"build-manifest: no pois-<city>.json in {args.dir}", file=sys.stderr)
        return 1

    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    manifest = {
        "schema": SCHEMA,
        "generated": now.isoformat().replace("+00:00", "Z"),
        "cities": cities,
    }
    out = args.dir / "manifest.json"
    out.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
