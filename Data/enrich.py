"""Step 2: add fame and photo-density signals to each POI (PLAN.md 5.2).

    python3 enrich.py lodz

- Wikidata: sitelink count ("how famous is this") and English label for POIs with a `wikidata` tag.
- Wikimedia Commons: number of geotagged files within 50 m ("do people photograph this"),
  counted locally from all geotagged files in the city box (fetched by tile).

Results are cached per city, so re-runs only fetch what's missing.
Reads cache/<city>/osm.json, writes cache/<city>/enriched.json.
"""
import json
import sys
import time

from common import cache_dir, http_json, load_city, metres

WIKIDATA = "https://www.wikidata.org/w/api.php"
COMMONS = "https://commons.wikimedia.org/w/api.php"
COMMONS_RADIUS_M = 50
PAUSE_S = 2.0      # be polite: Wikimedia rate-limits anonymous scripts
TILE_LIMIT = 500   # max results per geosearch call
TILE_DEG = 0.01    # starting tile height (~1.1 km); width scaled for latitude


def load_cache(path):
    return json.loads(path.read_text()) if path.exists() else {}


def fetch_wikidata(qids, cache, path):
    """Sitelink count and English label per Wikidata id."""
    missing = sorted({q for q in qids if not isinstance(cache.get(q), dict)})
    for i in range(0, len(missing), 50):
        batch = missing[i:i + 50]
        res = http_json(WIKIDATA, params={
            "action": "wbgetentities", "ids": "|".join(batch), "props": "sitelinks|labels",
            "languages": "en", "format": "json",
        })
        for qid in batch:
            entity = res.get("entities", {}).get(qid, {})
            cache[qid] = {
                "sitelinks": len(entity.get("sitelinks", {})),
                "label_en": entity.get("labels", {}).get("en", {}).get("value"),
            }
        path.write_text(json.dumps(cache))
        print(f"  wikidata {min(i + 50, len(missing))}/{len(missing)}")


def commons_tile(s, w, n, e, attempts=5):
    for attempt in range(attempts):
        res = http_json(COMMONS, params={
            "action": "query", "list": "geosearch", "gsbbox": f"{n}|{w}|{s}|{e}",
            "gslimit": TILE_LIMIT, "gsnamespace": 6, "format": "json",
        })
        if "error" not in res:
            break
        if attempt == attempts - 1 or "too-busy" not in res["error"].get("code", ""):
            raise RuntimeError(res["error"])
        print(f"  search busy, retry in {20 * (attempt + 1)}s", flush=True)
        time.sleep(20 * (attempt + 1))
    return [(g["lat"], g["lon"]) for g in res.get("query", {}).get("geosearch", [])]


def fetch_commons_points(bbox, cache, path):
    """All geotagged Commons files in the city box, fetched tile by tile.

    A tile that hits the API's 500-result cap is split into four until none do.
    Far fewer requests than one geosearch per POI, which matters: Wikimedia rate-limits hard.
    """
    s0, w0, n0, e0 = bbox
    rows = max(1, round((n0 - s0) / TILE_DEG))
    cols = max(1, round((e0 - w0) / (TILE_DEG * 1.6)))
    queue = [(s0 + (n0 - s0) * r / rows, w0 + (e0 - w0) * c / cols,
              s0 + (n0 - s0) * (r + 1) / rows, w0 + (e0 - w0) * (c + 1) / cols)
             for r in range(rows) for c in range(cols)]
    requests = 0
    while queue:
        s, w, n, e = queue.pop()
        key = f"{s:.5f},{w:.5f},{n:.5f},{e:.5f}"
        if key not in cache:
            cache[key] = commons_tile(s, w, n, e)
            requests += 1
            path.write_text(json.dumps(cache))
            time.sleep(PAUSE_S)
        if len(cache[key]) >= TILE_LIMIT:
            ml, mo = (s + n) / 2, (w + e) / 2
            queue += [(s, w, ml, mo), (s, mo, ml, e), (ml, w, n, mo), (ml, mo, n, e)]
            continue
        print(f"  tile {key}: {len(cache[key])} files", flush=True)
    print(f"  {requests} Commons requests made")
    # Keep only leaf tiles (those under the cap) so split parents don't double count.
    points = set()
    for files in cache.values():
        if len(files) < TILE_LIMIT:
            points.update(map(tuple, files))
    return list(points)


def count_near(pois, points, radius_m):
    """Number of points within radius_m of each POI, using a coarse grid index."""
    cell = 0.001  # ~111 m of latitude; radius is 50 m so neighbouring cells suffice
    grid = {}
    for lat, lon in points:
        grid.setdefault((int(lat / cell), int(lon / cell)), []).append((lat, lon))
    counts = {}
    for p in pois:
        ci, cj = int(p["lat"] / cell), int(p["lon"] / cell)
        n = 0
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for lat, lon in grid.get((ci + di, cj + dj), ()):
                    if metres(p["lat"], p["lon"], lat, lon) <= radius_m:
                        n += 1
        counts[p["id"]] = n
    return counts


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: python3 enrich.py <city>")
    d = cache_dir(sys.argv[1])
    data = json.loads((d / "osm.json").read_text())
    pois = data["pois"]

    wd_path, cm_path = d / "wikidata_cache.json", d / "commons_tiles.json"
    wd, tiles = load_cache(wd_path), load_cache(cm_path)

    qids = [p["tags"]["wikidata"] for p in pois if p["tags"].get("wikidata", "").startswith("Q")]
    print(f"Wikidata: {len(qids)} POIs with an id")
    fetch_wikidata(qids, wd, wd_path)
    print("Commons: fetching geotagged files by tile")
    points = fetch_commons_points(load_city(sys.argv[1])["bbox"], tiles, cm_path)
    print(f"  {len(points)} geotagged files in the city box")
    cm = count_near(pois, points, COMMONS_RADIUS_M)

    for p in pois:
        entry = wd.get(p["tags"].get("wikidata", ""), {})
        p["sitelinks"] = entry.get("sitelinks", 0)
        p["wikidata_label_en"] = entry.get("label_en")
        p["commons"] = cm.get(p["id"], 0)
    (d / "enriched.json").write_text(json.dumps(data, ensure_ascii=False, indent=1))
    print(f"Wrote enriched.json ({len(pois)} POIs)")


if __name__ == "__main__":
    main()
