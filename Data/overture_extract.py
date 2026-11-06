"""Monthly: extract Overture Maps Places for a city into a compact JSON file (ADR 014).

    pip install -r Data/requirements-overture.txt      # duckdb only, in a throwaway venv
    python3 Data/overture_extract.py vilnius [--release latest|2026-10-21.0] \
        --out Data/sources/overture/vilnius.json

Reads the GeoParquet files of the Overture places theme from the public S3 bucket (anonymous
access, no credentials) for the city's `bbox` in Data/cities.json, keeps places with confidence
>= MIN_CONFIDENCE, and writes a deterministic JSON file: `release`, `generated` and `places`
(sorted by id). The nightly pipeline (score.py) reads that file with the standard library only and
applies the stricter selection there, so it can be tuned without re-extracting.

"latest" is the newest release folder under s3://overturemaps-us-west-2/release/, found by listing
the bucket (S3 ListObjectsV2 over HTTPS with delimiter "/", folder names like 2026-10-21.0, the
largest one wins). This is the only script in Data/ that needs a non-stdlib package (duckdb).
"""
import argparse
import datetime
import json
import re
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

from common import USER_AGENT, load_city

BUCKET = "overturemaps-us-west-2"
REGION = "us-west-2"
MIN_CONFIDENCE = 0.5   # loose here; score.py applies the real threshold
RELEASE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})\.(\d+)$")
INSTAGRAM_RE = re.compile(r"instagram\.com/([A-Za-z0-9._]{1,30})/?(?:[?#].*)?$", re.I)
NOT_HANDLES = {"p", "reel", "reels", "explore", "stories", "accounts", "tv"}


def releases():
    """Release folder names in the bucket, e.g. ['2026-09-23.0', '2026-10-21.0']."""
    names, token = [], None
    while True:
        params = {"list-type": "2", "prefix": "release/", "delimiter": "/"}
        if token:
            params["continuation-token"] = token
        url = f"https://{BUCKET}.s3.amazonaws.com/?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=60) as resp:
            root = ET.fromstring(resp.read())
        ns = {"s3": root.tag.split("}")[0].strip("{")} if root.tag.startswith("{") else {}
        q = (lambda tag: f"s3:{tag}") if ns else (lambda tag: tag)
        for prefix in root.iterfind(f"{q('CommonPrefixes')}/{q('Prefix')}", ns):
            name = prefix.text.split("/")[1]
            if RELEASE_RE.match(name):
                names.append(name)
        truncated = root.findtext(q("IsTruncated"), default="false", namespaces=ns)
        token = root.findtext(q("NextContinuationToken"), namespaces=ns)
        if truncated != "true" or not token:
            break
    return sorted(names, key=lambda n: tuple(int(x) for x in RELEASE_RE.match(n).groups()))


def instagram_handle(socials):
    for url in socials or ():
        m = INSTAGRAM_RE.search(url or "")
        if m and m.group(1).lower() not in NOT_HANDLES:
            return m.group(1)
    return None


def brand_value(brand):
    """Brand name, True for a brand known only by its Wikidata id, False for none."""
    if not brand:
        return False
    name = (brand.get("names") or {}).get("primary")
    return name or bool(brand.get("wikidata"))


def updated(sources):
    """Newest update date (YYYY-MM-DD) among the place's source records. Overture's own
    confidence-calculation record is skipped: it is refreshed for every place in every release."""
    dates = [s["update_time"][:10] for s in sources or ()
             if s.get("update_time") and (s.get("dataset") or "").lower() != "overture"]
    return max(dates, default=None)


def place(row):
    (pid, names, bbox, confidence, websites, socials, phones, brand, addresses, status,
     basic, taxonomy, sources) = row
    names = names or {}
    name = (names.get("primary") or "").strip()
    if not name:
        return None
    common = dict(names.get("common") or {})
    out = {
        "id": pid,
        "name": name,
        "lat": round((bbox["ymin"] + bbox["ymax"]) / 2, 6),
        "lon": round((bbox["xmin"] + bbox["xmax"]) / 2, 6),
        "confidence": round(confidence, 3),
    }
    local = (common.get("lt") or "").strip()
    if local and local != name:
        out["local_name"] = local
    if basic:
        out["basic_category"] = basic
    if taxonomy and taxonomy.get("primary"):
        out["taxonomy"] = {"primary": taxonomy["primary"], "hierarchy": list(taxonomy.get("hierarchy") or [])}
    out["brand"] = brand_value(brand)
    website = next((w for w in websites or () if re.match(r"https?://", w or "")), None)
    if website:
        out["website"] = website
    if handle := instagram_handle(socials):
        out["instagram"] = handle
    if phones:
        out["phone"] = True
    address = next((a["freeform"] for a in addresses or () if a.get("freeform")), None)
    if address:
        out["address"] = address
    if status:
        out["operating_status"] = status
    datasets = sorted({s["dataset"] for s in sources or ()
                       if s.get("dataset") and s["dataset"].lower() != "overture"})
    if datasets:
        out["datasets"] = datasets
    if date := updated(sources):
        out["updated"] = date
    return out


def extract(bbox, release):
    import duckdb  # the one non-stdlib dependency (requirements-overture.txt)

    south, west, north, east = bbox
    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute(f"SET s3_region = '{REGION}';")
    path = f"s3://{BUCKET}/release/{release}/theme=places/type=place/*"
    rows = con.execute(f"""
        SELECT id, names, bbox, confidence, websites, socials, phones, brand, addresses,
               operating_status, basic_category, taxonomy, sources
        FROM read_parquet('{path}', hive_partitioning = 1)
        WHERE bbox.xmin <= ? AND bbox.xmax >= ? AND bbox.ymin <= ? AND bbox.ymax >= ?
          AND confidence >= ?
    """, [east, west, north, south, MIN_CONFIDENCE]).fetchall()
    places = [p for p in map(place, rows) if p]
    return sorted(places, key=lambda p: p["id"])


def main():
    parser = argparse.ArgumentParser(description="Extract Overture Maps Places for a city (ADR 014).")
    parser.add_argument("city")
    parser.add_argument("--release", default="latest", help="'latest' (default) or a release like 2026-10-21.0")
    parser.add_argument("--out", required=True, type=Path, help="e.g. Data/sources/overture/<city>.json")
    args = parser.parse_args()
    city = load_city(args.city)
    release = args.release
    if release == "latest":
        found = releases()
        if not found:
            sys.exit("overture_extract: no releases found in the bucket listing")
        release = found[-1]
    elif not RELEASE_RE.match(release):
        sys.exit(f"overture_extract: bad release '{release}' (expected latest or YYYY-MM-DD.N)")
    print(f"Overture release {release}, {city['name']} bbox {city['bbox']}", flush=True)
    places = extract(city["bbox"], release)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    # One place per line: compact, and a monthly refresh reads as a reviewable diff.
    lines = [json.dumps(p, ensure_ascii=False, sort_keys=True, separators=(",", ":")) for p in places]
    header = json.dumps({"release": release, "generated": datetime.date.today().isoformat(),
                         "city": args.city, "license": "CDLA-Permissive-2.0 (Overture Maps Foundation)"},
                        ensure_ascii=False, separators=(",", ":"))
    args.out.write_text(header[:-1] + ',"places":[\n' + ",\n".join(lines) + "\n]}\n", encoding="utf-8")
    print(f"  {len(places)} places with confidence >= {MIN_CONFIDENCE}; wrote {args.out} "
          f"({args.out.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
