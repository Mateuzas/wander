"""Shared helpers for the POI pipeline. Standard library only."""
import json
import math
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

DATA = Path(__file__).resolve().parent
ROOT = DATA.parent
RESOURCES = ROOT / "App" / "Wander" / "Resources"
USER_AGENT = "WanderMVP/0.1 (personal walking-route prototype)"


def load_city(slug):
    cities = json.loads((DATA / "cities.json").read_text())
    if slug not in cities:
        sys.exit(f"Unknown city '{slug}'. Known: {', '.join(cities)}")
    return cities[slug]


def cache_dir(slug):
    d = DATA / "cache" / slug
    d.mkdir(parents=True, exist_ok=True)
    return d


def http_json(url, params=None, data=None, retries=6, timeout=180):
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    body = urllib.parse.urlencode(data).encode() if data else None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, data=body, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.load(resp)
        except Exception as exc:  # network errors, 429, 504
            if attempt == retries - 1:
                raise
            wait = 5 * (attempt + 1)
            retry_after = getattr(exc, "headers", None) and exc.headers.get("Retry-After")
            if retry_after and retry_after.isdigit():
                wait = max(wait, int(retry_after))
            print(f"  retry in {wait}s after: {exc}", file=sys.stderr)
            time.sleep(wait)


def metres(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6_371_000 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
