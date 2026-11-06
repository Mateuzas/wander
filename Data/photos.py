"""Step 4a: a photo for every place (ADR 015, BE-14). Standard library only.

    python3 photos.py vilnius [--max-age-days 30] [--diagnose-mapillary N]

For every candidate place (score.candidates: after curation, de-duplication and the floors) it
looks for, in priority order:

1. Commons: the place's own image (`commonsImage` logic, curation `image` included), then a file
   from its Commons category. A thumbnail URL at most THUMB_WIDTH wide, from an original at least
   COMMONS_MIN_WIDTH wide, with the author and licence from the Commons API.
2. Mapillary (only with MAPILLARY_TOKEN in the environment): the image a mapper put in the OSM
   `mapillary` tag, else, from the coverage tiles, the image within MAPILLARY_RADIUS_M that has the
   place most central in its frame and is closest (facing_tolerance(), see the Mapillary section),
   checked again on its corrected position and compass. Never panoramas.
3. The website preview image (`og:image` / `twitter:image`) from the place's own homepage, where
   robots.txt allows it; never an svg, a likely logo (square-ish under LOGO_MAX px or "logo" in
   the file name) or a tiny image.

Commons wins whenever it has a usable file. Between Mapillary and the website preview: food, shops
and venues take a large (at least WEBSITE_LARGE px wide) website photo first; sights take Mapillary
first (choose()).

Writes cache/<city>/photos.json: per place id the input key, the date checked and the photo (or
null), plus the per-source lookups (Commons files and categories, Mapillary searches, image
probes). Entries are re-checked after --max-age-days; Mapillary thumbnail URLs are signed and
expire, so they are refreshed when their expiry is within MAPILLARY_REFRESH_DAYS (see README).
score.py reads only this file: a place whose inputs changed since the last run has no photo.
"""
import argparse
import concurrent.futures
import datetime
import gzip
import hashlib
import html
import json
import math
import os
import re
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import website
from common import USER_AGENT, cache_dir, http_json, metres

COMMONS_API = "https://commons.wikimedia.org/w/api.php"
THUMB_WIDTH = 1280
COMMONS_MIN_WIDTH = 800
CATEGORY_SAMPLE = 40         # files read from a Commons category to pick one
MAX_IMAGE_SHARES = 3         # a Commons file used by this many places is too generic (as in score.py)
MAPILLARY_API = "https://graph.mapillary.com"
MAPILLARY_TILES = "https://tiles.mapillary.com/maps/vtp/mly1_public/2"
TILE_ZOOM = 14               # the coverage tiles' `image` layer exists at z14 only
MAPILLARY_RADIUS_M = 60
MAPILLARY_MIN_M = 3          # closer than this, GPS error makes the bearing to the place meaningless
HALF_FOV_DEG = 35            # half a typical phone or action camera's horizontal field of view
FACADE_HALF_M = 8            # half the width of a typical shop front or small building
MAX_FACING_DEG = 70
MAPILLARY_VERIFY = 3         # best candidates looked up by id and checked on corrected values
MAPILLARY_RULES = 2          # bump when the search or selection changes: older cached searches are redone
DIAG_ROWS = 12
MAPILLARY_REFRESH_DAYS = 7   # refresh a signed thumbnail URL this long before it expires
MAPILLARY_FIELDS = "id,thumb_1024_url,compass_angle,computed_compass_angle,captured_at,creator,geometry," \
                   "computed_geometry,is_pano"
MAPILLARY_LICENSE = "CC BY-SA 4.0"
WEBSITE_LARGE = 800          # website photo this wide beats Mapillary for food, shops and venues
WEBSITE_MIN_WIDTH = 300      # anything narrower is useless as a card photo
LOGO_MAX = 400               # square-ish (ratio 0.8-1.25) and smaller than this: a logo
LOGO_WORDS = re.compile(r"logo|favicon|icon|placeholder|default|brand|blank|sprite", re.I)
COMMONS_SKIP = re.compile(r"\b(map|plan|scheme|logo|coat of arms|herb|seal|stamp|postcard|signature|diagram|"
                          r"document|scan|flag)\b", re.I)
VENUE_TYPES = {"stadium", "theatre", "concert_hall", "zoo", "aquarium", "theme_park", "arts_centre",
               "events_venue", "sports_hall", "sports_centre", "music_venue", "gallery"}
WORKERS = 8


def cache_path(slug):
    return cache_dir(slug) / "photos.json"


def load(slug):
    path = cache_path(slug)
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    for k in ("places", "commons_files", "commons_categories", "mapillary", "images", "verified"):
        data.setdefault(k, {})
    for k in ("commons_files", "commons_categories"):  # repair Commons URLs cached before BE-17
        for entry in data[k].values():
            if (entry or {}).get("photo"):
                entry["photo"]["url"] = clean_commons_url(entry["photo"]["url"])
    return data


def save(slug, data):
    cache_path(slug).write_text(json.dumps(data, ensure_ascii=False, sort_keys=True, indent=0), encoding="utf-8")


def inputs(p):
    """Everything the photo choice for a place depends on (besides the sources' own data)."""
    return {"commons_file": p.get("commons_file"), "commons_cat": p.get("commons_cat"),
            "website": p.get("site_url"), "lat": round(p["lat"], 6), "lon": round(p["lon"], 6),
            "mapillary": p["tags"].get("mapillary"), "category": p["category"], "type": p.get("type")}


def input_key(p):
    return hashlib.sha256(json.dumps(inputs(p), sort_keys=True).encode()).hexdigest()[:16]


def photo_for(p, cache):
    """(photo or None, fresh): the cached photo when the place's inputs are unchanged."""
    entry = cache["places"].get(p["id"])
    if not entry or entry.get("key") != input_key(p):
        return None, False
    return entry.get("photo"), True


# ---- Commons ------------------------------------------------------------------------------

def strip_html(text):
    return " ".join(html.unescape(re.sub(r"<[^>]+>", " ", text or "")).split())


def commons_info(page):
    """A photo candidate from a Commons API page with imageinfo, or None if unusable."""
    info = (page.get("imageinfo") or [None])[0]
    if not info:
        return None
    mime = info.get("mime", "")
    if mime not in ("image/jpeg", "image/png", "image/webp"):
        return None
    if info.get("width", 0) < COMMONS_MIN_WIDTH:
        return None
    meta = info.get("extmetadata") or {}
    credit = strip_html(meta.get("Artist", {}).get("value")) or strip_html(meta.get("Credit", {}).get("value"))
    credit = (credit or "Wikimedia Commons")[:120]
    url = thumb_url(info.get("url"), info.get("width", 0))
    if not url:
        return None
    out = {"url": url, "source": "commons", "credit": credit, "page": info.get("descriptionurl"),
           "width": info.get("width"), "height": info.get("height"), "title": page.get("title")}
    lic = strip_html(meta.get("LicenseShortName", {}).get("value"))
    if lic:
        out["license"] = lic
    return out


def clean_commons_url(url):
    """An upload.wikimedia.org URL without any query or fragment. imageinfo URLs carry tracking
    parameters (`?utm_source=commons.wikimedia.org&...`); a thumbnail built from such a URL had the
    query in the middle of its path and returned HTTP 400 (BE-17). Also repairs those stored URLs."""
    return re.sub(r"[?#][^/]*", "", url) if url else url


def thumb_url(url, width):
    """The standard Commons thumbnail THUMB_WIDTH wide for an original upload URL (the original
    when it is not wider). Built from the URL instead of asking the API (`iiurlwidth`), which
    renders thumbnails and is rate limited."""
    prefix = "https://upload.wikimedia.org/wikipedia/commons/"
    url = clean_commons_url(url)
    if not url or not url.startswith(prefix):
        return None
    if width <= THUMB_WIDTH:
        return url
    rest = url[len(prefix):]  # a/ab/Name.jpg
    name = rest.rsplit("/", 1)[-1]
    return f"{prefix}thumb/{rest}/{THUMB_WIDTH}px-{name}"


IMAGEINFO = {"prop": "imageinfo", "iiprop": "url|size|mime|extmetadata",
             "iiextmetadatafilter": "Artist|Credit|LicenseShortName", "format": "json", "formatversion": "2"}


def fetch_commons_files(names):
    """{file name: candidate or None} for Commons file names (no "File:" prefix), 50 per request."""
    out = {}
    names = sorted(set(names))
    for i in range(0, len(names), 50):
        chunk = names[i:i + 50]
        data = http_json(COMMONS_API, {"action": "query", "titles": "|".join("File:" + n for n in chunk), **IMAGEINFO})
        q = data.get("query", {})
        alias = {n["to"]: n["from"] for n in q.get("normalized", [])}
        for page in q.get("pages", []):
            title = page.get("title", "")
            original = alias.get(title, title)
            name = original[len("File:"):] if original.startswith("File:") else original
            out[name] = None if page.get("missing") else commons_info(page)
        for n in chunk:
            out.setdefault(n, None)
    return out


def category_pick(files):
    """The best candidate from a category's files: no maps, plans, scans or logos; landscape first,
    then the largest; ties by title (deterministic)."""
    usable = [f for f in files if f and not COMMONS_SKIP.search(f["title"])]
    usable.sort(key=lambda f: (f["width"] < f["height"], -min(f["width"] * f["height"], 24_000_000), f["title"]))
    return usable[0] if usable else None


def fetch_commons_category(cat):
    data = http_json(COMMONS_API, {"action": "query", "generator": "categorymembers", "gcmtitle": "Category:" + cat,
                                   "gcmtype": "file", "gcmlimit": CATEGORY_SAMPLE, **IMAGEINFO})
    return category_pick([commons_info(p) for p in data.get("query", {}).get("pages", [])])


# ---- Mapillary ----------------------------------------------------------------------------
#
# Finding images (BE-17): the coverage vector tiles (z14 `image` layer: every image's id, position,
# compass and is_pano), one request per tile for the whole city, which is how Mapillary's own SDK
# searches an area. The Graph API bbox search returned nothing usable on the first nightly (695
# searches, 0 photos), so it is only the fallback for a tile that fails. The few best candidates are
# then looked up by id (thumbnail URL, creator and the SfM-corrected position and compass) and
# checked again on those corrected values.
#
# Choosing one: the place must be in the frame. A camera sees about HALF_FOV_DEG either side of its
# compass, and a place's front is about 2 * FACADE_HALF_M wide, so from d metres it is in view when
# the bearing differs by at most HALF_FOV_DEG + atan(FACADE_HALF_M / d) (capped at MAX_FACING_DEG):
# about 70° at 10 m, 57° at 20 m, 46° at 40 m and 43° at 60 m. The old flat ±50° within 40 m
# rejected the close, oblique shots street-level imagery mostly has (cameras face along the street;
# a shop beside it is at 60-90°). Among the images in view, the most central and closest wins.
# Panoramas are never published: the thumbnail is the whole equirectangular sphere, which a card
# crop shows as a distorted strip; they are counted in the diagnostics.

def bearing(lat1, lon1, lat2, lon2):
    """Initial compass bearing in degrees from point 1 to point 2."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    x = math.sin(dl) * math.cos(p2)
    y = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(x, y)) + 360) % 360


def angle_diff(a, b):
    """The smallest difference between two compass angles, 0-180 (359° and 1° differ by 2°)."""
    return abs((a - b + 180) % 360 - 180)


def facing_tolerance(d):
    """How far (degrees) the camera may point away from the place's centre at distance d metres."""
    return min(MAX_FACING_DEG, HALF_FOV_DEG + math.degrees(math.atan2(FACADE_HALF_M, max(d, 0.1))))


def thumb_expiry(url):
    """Epoch seconds when a signed Mapillary thumbnail URL expires (`oe` is hex), or None."""
    oe = urllib.parse.parse_qs(urllib.parse.urlsplit(url or "").query).get("oe")
    try:
        return int(oe[0], 16) if oe else None
    except ValueError:
        return None


def mapillary_get(path, params, token):
    """A Graph API GET. The token goes in `access_token` (percent-encoded, `MLY%7C...`), as for the
    tiles: with only `Authorization: OAuth <token>` the first nightlies got HTTP 400 on every image
    lookup and empty bbox searches (BE-17, run 42298394117), while the tiles answered."""
    url = f"{MAPILLARY_API}/{urllib.parse.quote(str(path))}?{urllib.parse.urlencode({**params, 'access_token': token})}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def error_text(exc, token):
    """An exception as loggable text, with the first 300 bytes of an HTTP error body; token redacted."""
    body = ""
    if isinstance(exc, urllib.error.HTTPError):
        try:
            body = " " + exc.read(300).decode("utf-8", "replace")
        except Exception:
            pass
    return redact(f"{type(exc).__name__}: {exc}{body}", token)


def image_point(img):
    geo = img.get("computed_geometry") or img.get("geometry") or {}
    c = geo.get("coordinates")
    return (c[1], c[0]) if c else None


def image_compass(img):
    c = img.get("computed_compass_angle")
    return c if c is not None else img.get("compass_angle")


def assess(lat, lon, img):
    """How an image relates to the place: distance, compass, bearing to the place, their difference,
    the tolerance at that distance and a verdict ("ok" or why not)."""
    pt, compass = image_point(img), image_compass(img)
    if not pt:
        return {"img": img, "verdict": "no position"}
    d = metres(pt[0], pt[1], lat, lon)
    row = {"img": img, "d": d, "compass": compass, "pano": bool(img.get("is_pano"))}
    if compass is None:
        return {**row, "verdict": "no compass"}
    b = bearing(pt[0], pt[1], lat, lon)
    row.update(bearing=b, diff=angle_diff(compass, b), tol=facing_tolerance(d))
    if d > MAPILLARY_RADIUS_M:
        verdict = "too far"
    elif d < MAPILLARY_MIN_M:
        verdict = "too close (bearing unreliable)"
    elif row["pano"]:
        verdict = "panorama"  # every direction is in it; the card would show a distorted sphere
    elif row["diff"] > row["tol"]:
        verdict = "faces away"
    else:
        verdict = "ok"
    return {**row, "verdict": verdict}


def mapillary_ranked(lat, lon, images):
    """The usable images for a place, best first: the place most central in the frame (bearing
    difference relative to the tolerance) and the camera closest, then the newest, then by id."""
    rows = [a for a in (assess(lat, lon, img) for img in images) if a["verdict"] == "ok"]
    rows.sort(key=lambda a: (round(a["diff"] / a["tol"] + a["d"] / MAPILLARY_RADIUS_M, 3),
                             -(a["img"].get("captured_at") or 0), str(a["img"]["id"])))
    return rows


def mapillary_pick(lat, lon, images):
    """(image, distance) of the best usable image for (lat, lon), or (None, None)."""
    rows = mapillary_ranked(lat, lon, images)
    return (rows[0]["img"], rows[0]["d"]) if rows else (None, None)


def mapillary_candidate(img, distance=None):
    creator = (img.get("creator") or {}).get("username") or "Mapillary contributor"
    out = {"url": img["thumb_1024_url"], "source": "mapillary", "credit": f"{creator} / Mapillary",
           "license": MAPILLARY_LICENSE, "page": f"https://www.mapillary.com/app/?pKey={img['id']}",
           "id": str(img["id"]), "expires": thumb_expiry(img["thumb_1024_url"])}
    if distance is not None:
        out["distance_m"] = round(distance, 1)
    return out


# -- Coverage vector tiles (Mapbox Vector Tile protobuf, decoded with the standard library) --

def tile_xy(lat, lon, z=TILE_ZOOM):
    n = 2 ** z
    x = int((lon + 180) / 360 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return x, y


def tile_lonlat(z, fx, fy):
    """(lon, lat) of fractional tile coordinates."""
    n = 2 ** z
    return fx / n * 360 - 180, math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * fy / n))))


def tiles_around(lat, lon, radius=MAPILLARY_RADIUS_M):
    dlat = radius * 1.2 / 111_320
    dlon = dlat / max(0.2, math.cos(math.radians(lat)))
    (x0, y0), (x1, y1) = tile_xy(lat + dlat, lon - dlon), tile_xy(lat - dlat, lon + dlon)
    return {(TILE_ZOOM, x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)}


def _varint(buf, i):
    out = shift = 0
    while True:
        b = buf[i]
        i += 1
        out |= (b & 0x7F) << shift
        if b < 0x80:
            return out, i
        shift += 7


def _fields(buf):
    """(field number, wire type, value) of a protobuf message; length-delimited values are views."""
    i, n = 0, len(buf)
    while i < n:
        key, i = _varint(buf, i)
        wire = key & 7
        if wire == 0:
            v, i = _varint(buf, i)
        elif wire == 1:
            v, i = buf[i:i + 8], i + 8
        elif wire == 2:
            size, i = _varint(buf, i)
            v, i = buf[i:i + size], i + size
        elif wire == 5:
            v, i = buf[i:i + 4], i + 4
        else:
            raise ValueError(f"protobuf wire type {wire}")
        yield key >> 3, wire, v


def _packed(buf):
    out, i = [], 0
    while i < len(buf):
        v, i = _varint(buf, i)
        out.append(v)
    return out


def _zigzag(n):
    return (n >> 1) ^ -(n & 1)


def _mvt_value(buf):
    for f, _, v in _fields(buf):
        if f == 1:
            return bytes(v).decode("utf-8", "replace")
        if f == 2:
            return struct.unpack("<f", v)[0]
        if f == 3:
            return struct.unpack("<d", v)[0]
        if f == 4:
            return v - (1 << 64) if v >= 1 << 63 else v
        if f == 5:
            return v
        if f == 6:
            return _zigzag(v)
        if f == 7:
            return bool(v)
    return None


def mvt_points(data, layer_name, z, x, y):
    """[(properties, lat, lon)] for the point features of one layer of a vector tile."""
    buf = memoryview(gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data)
    out = []
    for f, _, layer in _fields(buf):
        if f != 3:
            continue
        name, keys, values, feats, extent = None, [], [], [], 4096
        for lf, _, lv in _fields(layer):
            if lf == 1:
                name = bytes(lv).decode()
            elif lf == 2:
                feats.append(lv)
            elif lf == 3:
                keys.append(bytes(lv).decode())
            elif lf == 4:
                values.append(_mvt_value(lv))
            elif lf == 5:
                extent = lv
        if name != layer_name:
            continue
        for feat in feats:
            tags, geom, gtype = [], [], 0
            for ff, fw, fv in _fields(feat):
                if ff == 2:
                    tags += _packed(fv) if fw == 2 else [fv]
                elif ff == 3:
                    gtype = fv
                elif ff == 4:
                    geom = _packed(fv) if fw == 2 else [fv]
            if gtype != 1 or not geom or geom[0] & 7 != 1:
                continue  # not a point
            props = {keys[tags[k]]: values[tags[k + 1]] for k in range(0, len(tags) - 1, 2)}
            px = py = 0
            for k in range(geom[0] >> 3):  # MoveTo count: one point, or several for a multipoint
                px += _zigzag(geom[1 + 2 * k])
                py += _zigzag(geom[2 + 2 * k])
                lon, lat = tile_lonlat(z, x + px / extent, y + py / extent)
                out.append((props, lat, lon))
    return out


def tile_images(data, z, x, y):
    """Images (Graph-API-shaped dicts) from a coverage tile's `image` layer."""
    out = []
    for props, lat, lon in mvt_points(data, "image", z, x, y):
        if props.get("id") is None:
            continue
        out.append({"id": str(int(props["id"])), "compass_angle": props.get("compass_angle"),
                    "is_pano": bool(props.get("is_pano")), "captured_at": props.get("captured_at"),
                    "geometry": {"type": "Point", "coordinates": [lon, lat]}, "from_tile": True})
    return out


def fetch_tile(tile, token):
    z, x, y = tile
    url = f"{MAPILLARY_TILES}/{z}/{x}/{y}?{urllib.parse.urlencode({'access_token': token})}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return tile_images(resp.read(), z, x, y)


def bbox_images(p, token, fields=MAPILLARY_FIELDS):
    """The Graph API bbox search around a place (minLon,minLat,maxLon,maxLat): the fallback."""
    dlat = MAPILLARY_RADIUS_M * 1.2 / 111_320
    dlon = dlat / max(0.2, math.cos(math.radians(p["lat"])))
    bbox = f"{p['lon'] - dlon:.6f},{p['lat'] - dlat:.6f},{p['lon'] + dlon:.6f},{p['lat'] + dlat:.6f}"
    return mapillary_get("images", {"fields": fields, "bbox": bbox, "limit": 500}, token).get("data", [])


def fetch_mapillary(p, token, images=None, stats=None):
    """A Mapillary candidate for a place, or None. `images` are the candidates from the coverage
    tiles (None: search with the Graph API). `stats` counts how far places get (diagnostics)."""
    stats = stats if stats is not None else {}

    def count(k):
        stats[k] = stats.get(k, 0) + 1
    tagged = p["tags"].get("mapillary", "").strip()
    if tagged.isdigit():
        img = mapillary_get(tagged, {"fields": MAPILLARY_FIELDS}, token)
        if img.get("thumb_1024_url") and not img.get("is_pano"):
            count("picked (OSM mapillary tag)")
            return mapillary_candidate(img)
    if images is None:
        images = bbox_images(p, token)
        count("searched with the Graph API (tile failed)")
    rows = [assess(p["lat"], p["lon"], img) for img in images]
    near = [r for r in rows if r.get("d", 1e9) <= MAPILLARY_RADIUS_M]
    if near:
        count("any image within radius")
    if any(not r["pano"] for r in near):
        count("a non-panorama within radius")
    if any(r["verdict"] == "panorama" for r in near):
        count("a panorama within radius")
    ranked = mapillary_ranked(p["lat"], p["lon"], images)
    if ranked:
        count("a non-panorama facing it (tile data)")
    for r in ranked[:MAPILLARY_VERIFY]:
        img = r["img"]
        if img.get("from_tile") or not img.get("thumb_1024_url"):
            img = {**{k: v for k, v in img.items() if k != "from_tile"},
                   **mapillary_get(str(img["id"]), {"fields": MAPILLARY_FIELDS}, token)}
        again = assess(p["lat"], p["lon"], img)  # on the corrected position and compass
        if again["verdict"] == "ok" and img.get("thumb_1024_url"):
            count("picked")
            return mapillary_candidate(img, again["d"])
        count("rejected on corrected position/compass or no thumbnail")
    return None


def refresh_mapillary_url(cand, token):
    img = mapillary_get(cand["id"], {"fields": "id,thumb_1024_url"}, token)
    if img.get("thumb_1024_url"):
        cand = {**cand, "url": img["thumb_1024_url"], "expires": thumb_expiry(img["thumb_1024_url"])}
    return cand


def redact(text, token):
    text = str(text)
    if token:
        for form in (token, urllib.parse.quote(token, safe=""), urllib.parse.quote_plus(token)):
            text = text.replace(form, "***")
    return text


def diagnose_mapillary(sample, tile_cache, token):
    """Markdown: for each sample place, the raw candidates from the coverage tiles and from the
    Graph API bbox search (id, distance, compass, bearing difference, tolerance, is_pano, verdict)."""
    lines = [f"## Mapillary diagnostics ({len(sample)} places)", "",
             f"Rules: radius {MAPILLARY_RADIUS_M} m, min {MAPILLARY_MIN_M} m, facing within "
             f"min({MAX_FACING_DEG}°, {HALF_FOV_DEG}° + atan({FACADE_HALF_M} m / d)), no panoramas.", ""]

    def table(rows):
        rows = sorted(rows, key=lambda r: (r["verdict"] != "ok", r.get("d", 1e9)))[:DIAG_ROWS]
        out = ["| id | dist m | compass | bearing | diff | tol | pano | thumb | verdict |",
               "|---|---|---|---|---|---|---|---|---|"]
        for r in rows:
            f = lambda k, fmt="{:.0f}": fmt.format(r[k]) if r.get(k) is not None else "-"  # noqa: E731
            out.append(f"| {r['img'].get('id')} | {f('d', '{:.1f}')} | {f('compass')} | {f('bearing')} | "
                       f"{f('diff')} | {f('tol')} | {r.get('pano', '-')} | "
                       f"{'yes' if r['img'].get('thumb_1024_url') else 'no'} | {r['verdict']} |")
        return out
    for p in sample:
        lines.append(f"### {p['name']} ({p['id']}, {p['category']}, {p['lat']:.6f},{p['lon']:.6f})")
        tiles = tiles_around(p["lat"], p["lon"])
        if all(t in tile_cache and tile_cache[t] is not None for t in tiles):
            imgs = [i for t in tiles for i in tile_cache[t]]
            rows = [assess(p["lat"], p["lon"], i) for i in imgs]
            near = [r for r in rows if r.get("d", 1e9) <= MAPILLARY_RADIUS_M * 1.5]
            lines += [f"Tiles: {len(imgs)} images in {len(tiles)} tile(s), {len(near)} within "
                      f"{MAPILLARY_RADIUS_M * 1.5:.0f} m:", ""] + table(near) + [""]
        else:
            lines += ["Tiles: not available (fetch failed)", ""]
        try:
            raw = bbox_images(p, token)
            rows = [assess(p["lat"], p["lon"], i) for i in raw]
            lines += [f"Graph API bbox search: {len(raw)} images returned"
                      + (f"; fields on the first: {sorted(raw[0])}" if raw else ""), ""] + table(rows) + [""]
        except Exception as exc:
            lines += [f"Graph API bbox search failed: {error_text(exc, token)}", ""]
        try:
            stats = {}
            imgs = [i for t in tiles for i in (tile_cache.get(t) or [])] if all(tile_cache.get(t) is not None
                                                                                for t in tiles) else None
            cand = fetch_mapillary(p, token, imgs, stats)
            lines += [f"Result: {cand['page'] + ' at ' + str(cand.get('distance_m')) + ' m' if cand else 'none'} "
                      f"{stats}", ""]
        except Exception as exc:
            lines += [f"Result: error {error_text(exc, token)}", ""]
    return "\n".join(lines) + "\n"


# ---- Website preview ------------------------------------------------------------------------

def looks_like_logo(url, probe):
    if url.lower().split("?")[0].endswith(".svg") or LOGO_WORDS.search(urllib.parse.urlsplit(url).path):
        return True
    w, h = probe.get("width"), probe.get("height")
    if w and h:
        if w < WEBSITE_MIN_WIDTH:
            return True
        if 0.8 <= w / h <= 1.25 and max(w, h) < LOGO_MAX:
            return True
    return False


def website_candidate(p, site_entry, images, shared=frozenset()):
    """The first usable preview image of the place's homepage, or None. `images` caches probes;
    `shared` images appear on several places' sites (a booking platform's or a chain's card)."""
    if not site_entry or not website.about_place(site_entry, p["site_url"], (p["name"], p.get("original_name"))):
        return None
    for url in site_entry.get("images", []):
        if url in shared:
            continue
        probe = images.get(url, {}).get("probe")
        if probe is None:
            continue  # not probed yet (photos.py probes first)
        if probe.get("ok") and not looks_like_logo(url, probe):
            out = {"url": website.strip_tracking(url), "source": "website", "credit": website.domain(p["site_url"]), "page": p["site_url"]}
            if probe.get("width"):
                out["width"], out["height"] = probe["width"], probe.get("height")
            return out
    return None


# ---- Choice -----------------------------------------------------------------------------

def ranked(p, commons, mapillary, site):
    """The photo candidates in the order to publish them (ADR 015): Commons first; then food, shops
    and venues prefer a large website photo over Mapillary, and sights prefer Mapillary."""
    venue_like = p["category"] in ("food", "shop") or p.get("type") in VENUE_TYPES
    large_site = site if site and (site.get("width") or 0) >= WEBSITE_LARGE else None
    order = [commons] + ([large_site, mapillary, site] if venue_like else [mapillary, site])
    out = []
    for c in order:
        if c and c not in out:
            out.append(c)
    return out


def choose(p, commons, mapillary, site, ok=lambda c: True):
    """The first candidate whose URL passes `ok` (verify_url), or None."""
    return next((c for c in ranked(p, commons, mapillary, site) if ok(c)), None)


# ---- Verification before publishing ---------------------------------------------------------

VERIFY_DAYS = 7
VERIFY_WORKERS = 4


def verify_url(url, attempts=4):
    """{ok, why?, transient?}: a ranged GET of the first bytes must answer 200/206 with an image/*
    type. 429 and 5xx are retried with backoff (Retry-After honoured); if they persist the result
    is transient: not a broken URL, checked again next run."""
    if not url or not url.startswith("https://"):
        return {"ok": False, "why": "not https"}
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Range": "bytes=0-1023"})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                ctype = resp.headers.get("Content-Type", "").split(";")[0].strip().lower()
                resp.read(1024)
            break
        except urllib.error.HTTPError as exc:
            if exc.code != 429 and exc.code < 500:
                return {"ok": False, "why": f"HTTP {exc.code}"}
            if attempt == attempts - 1:
                return {"ok": False, "why": f"HTTP {exc.code}", "transient": True}
            wait = exc.headers.get("Retry-After", "") if exc.headers else ""
            time.sleep(min(30, int(wait)) if wait.isdigit() else 2 * 3 ** attempt)
        except Exception as exc:
            if attempt == attempts - 1:
                return {"ok": False, "why": f"error: {type(exc).__name__}", "transient": True}
            time.sleep(2 * 3 ** attempt)
    if not ctype.startswith("image/"):
        return {"ok": False, "why": f"type {ctype or 'none'}"}
    return {"ok": True}


def verify_all(urls, cache, today, check=None):
    """Check every URL not verified in the last VERIFY_DAYS (cache: {url: {checked, ok, why?}})."""
    check = check or verify_url
    limit = (today - datetime.timedelta(days=VERIFY_DAYS)).isoformat()
    todo = sorted({u for u in urls if u and (cache.get(u) or {}).get("checked", "") < limit})
    if todo:
        print(f"  verifying {len(todo)} photo URLs", flush=True)
        with concurrent.futures.ThreadPoolExecutor(VERIFY_WORKERS) as pool:
            for url, res in zip(todo, pool.map(check, todo)):
                if res.get("transient"):
                    # Rate limited or down: keep an earlier verdict, else unverified (retried next run).
                    cache[url] = cache.get(url) or {"checked": "", "ok": False, "why": res.get("why")}
                else:
                    cache[url] = {"checked": today.isoformat(), **res}
    return cache


def public(photo):
    """The `photo` object as published (CONTRACTS §1): url, source, credit, license?, page?."""
    if not photo:
        return None
    return {k: photo[k] for k in ("url", "source", "credit", "license", "page") if photo.get(k)}


def run(ctx, max_age_days, token, today=None, diagnose=0, check=None):
    slug, pois = ctx.slug, ctx.pois
    today = today or datetime.date.today()
    stale = (today - datetime.timedelta(days=max_age_days)).isoformat()
    data = load(slug)

    def old(entry):
        return not entry or entry.get("checked", "") < stale

    # Commons: a file used by MAX_IMAGE_SHARES+ places stands for a series, not this place.
    uses = {}
    for p in pois:
        if p.get("commons_file"):
            uses[p["commons_file"]] = uses.get(p["commons_file"], 0) + 1
    files = sorted({p["commons_file"] for p in pois if p.get("commons_file")
                    and uses[p["commons_file"]] < MAX_IMAGE_SHARES and old(data["commons_files"].get(p["commons_file"]))})
    if files:
        print(f"  commons: {len(files)} files", flush=True)
        for name, cand in fetch_commons_files(files).items():
            data["commons_files"][name] = {"checked": today.isoformat(), "photo": cand}
    cats = sorted({p["commons_cat"] for p in pois if p.get("commons_cat") and old(data["commons_categories"].get(p["commons_cat"]))})
    if cats:
        print(f"  commons: {len(cats)} categories", flush=True)
        for cat in cats:  # one at a time, politely: Commons answers bursts with 429
            data["commons_categories"][cat] = {"checked": today.isoformat(), "photo": fetch_commons_category(cat)}
            time.sleep(0.5)

    # Website preview images: homepage metadata (shared with hooks.py), then a range GET per image.
    sites = website.refresh(slug, [p["site_url"] for p in pois])
    probe = sorted({u for p in pois if p.get("site_url") for u in sites.get(p["site_url"], {}).get("images", [])[:2]
                    if old(data["images"].get(u))})
    if probe:
        print(f"  website images: probing {len(probe)}", flush=True)
        with concurrent.futures.ThreadPoolExecutor(website.WORKERS) as pool:
            for url, res in zip(probe, pool.map(website.probe_image, probe)):
                data["images"][url] = {"checked": today.isoformat(), "probe": res}

    # Mapillary: only for places Commons does not already cover.
    def commons_for(p):
        f = p.get("commons_file")
        if f and uses[f] < MAX_IMAGE_SHARES:
            c = (data["commons_files"].get(f) or {}).get("photo")
            if c:
                return c
        return (data["commons_categories"].get(p.get("commons_cat") or "") or {}).get("photo")

    def mkey(p):
        return f"{p['id']}@{p['lat']:.6f},{p['lon']:.6f},{p['tags'].get('mapillary', '')}"

    mly_note, mly_report, mly_report_head = None, "", []
    if token:
        need = [p for p in pois if not commons_for(p)]
        soon = (datetime.datetime.combine(today, datetime.time()) +
                datetime.timedelta(days=MAPILLARY_REFRESH_DAYS)).timestamp()

        def mold(entry):  # searched with older rules (BE-17: the 40 m / ±50° bbox search found nothing)
            return old(entry) or entry.get("rules") != MAPILLARY_RULES
        todo = [p for p in need if mold(data["mapillary"].get(mkey(p)))]
        refresh = [p for p in need if p not in todo and (data["mapillary"][mkey(p)].get("photo") or {}).get("expires")
                   and data["mapillary"][mkey(p)]["photo"]["expires"] < soon]
        sample = sorted(need, key=lambda p: hashlib.sha256(p["id"].encode()).hexdigest())[:diagnose]
        tiles = sorted({t for p in todo + sample for t in tiles_around(p["lat"], p["lon"])})
        print(f"  mapillary: {len(todo)} searches in {len(tiles)} coverage tiles, {len(refresh)} URL refreshes",
              flush=True)
        errors, bodies = {}, []

        def note(exc):
            msg = redact(f"{type(exc).__name__}: {exc}", token)[:120]
            errors[msg] = errors.get(msg, 0) + 1
            if isinstance(exc, urllib.error.HTTPError) and len(bodies) < 3:
                bodies.append(error_text(exc, token)[:400])

        def get_tile(t):
            try:
                return fetch_tile(t, token)
            except Exception as exc:
                note(exc)
                return None
        tile_cache = {}
        with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
            for t, imgs in zip(tiles, pool.map(get_tile, tiles)):
                tile_cache[t] = imgs
        failed_tiles = sum(v is None for v in tile_cache.values())
        stats = {}

        def search(p):
            ts = tiles_around(p["lat"], p["lon"])
            imgs = None if any(tile_cache.get(t) is None for t in ts) else [i for t in ts for i in tile_cache[t]]
            mine = {}
            try:
                return fetch_mapillary(p, token, imgs, mine), None, mine
            except Exception as exc:  # leave it unchecked; tried again next run
                return None, exc, mine
        with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
            for p, (cand, exc, mine) in zip(todo, pool.map(search, todo)):
                for k, v in mine.items():
                    stats[k] = stats.get(k, 0) + v
                if exc:
                    note(exc)
                    continue
                data["mapillary"][mkey(p)] = {"checked": today.isoformat(), "photo": cand, "rules": MAPILLARY_RULES}
            for p in refresh:
                try:
                    data["mapillary"][mkey(p)]["photo"] = refresh_mapillary_url(data["mapillary"][mkey(p)]["photo"], token)
                except Exception as exc:
                    note(exc)
        n_img = sum(len(v) for v in tile_cache.values() if v)
        print(f"  mapillary: {n_img} images in {len(tiles) - failed_tiles}/{len(tiles)} tiles; of {len(todo)} "
              f"places: " + ", ".join(f"{k} {v}" for k, v in sorted(stats.items())), flush=True)
        if errors:
            print(f"  ! mapillary: {sum(errors.values())} requests failed (retried next run): "
                  + "; ".join(f"{m} (x{n})" for m, n in sorted(errors.items(), key=lambda e: -e[1])[:5]))
            for b in bodies:
                print(f"    first failures: {b}")
            if bodies and diagnose:
                mly_report_head.append("First failed requests (body, token redacted):\n\n" +
                                       "\n".join(f"- `{b}`" for b in bodies) + "\n")
        if sample:
            mly_report = diagnose_mapillary(sample, tile_cache, token) + "".join(mly_report_head)
    else:
        mly_note = "MAPILLARY_TOKEN not set: Mapillary skipped (cached Mapillary photos still used until they expire)"

    now = datetime.datetime.combine(today, datetime.time()).timestamp()
    image_sites = {}
    for url in {p["site_url"] for p in pois if p.get("site_url")}:
        for img in sites.get(url, {}).get("images", []):
            image_sites.setdefault(img, set()).add(website.domain(url))
    shared = frozenset(img for img, domains in image_sites.items() if len(domains) > 1)
    counts, found = {}, {}
    for p in pois:
        commons = commons_for(p)
        mly = (data["mapillary"].get(mkey(p)) or {}).get("photo")
        if mly and mly.get("expires") and mly["expires"] < now:
            mly = None  # signed URL already expired and could not be refreshed
        site = website_candidate(p, sites.get(p.get("site_url") or ""), data["images"], shared)
        found[p["id"]] = (commons, mly, site)

    # Verify before publishing: every candidate URL must load as an image (BE-17: all Commons URLs
    # were malformed and nothing caught it). A failed one falls through to the next source.
    verify_all([c["url"] for p in pois for c in ranked(p, *found[p["id"]])], data["verified"], today, check)
    verified = {}

    def ok(c):
        good = bool((data["verified"].get(c["url"]) or {}).get("ok"))
        verified.setdefault(c["source"], {"verified": 0, "failed": 0})["verified" if good else "failed"] += 1
        return good
    for p in pois:
        commons, mly, site = found[p["id"]]
        chosen = choose(p, commons, mly, site, ok)
        data["places"][p["id"]] = {"key": input_key(p), "checked": today.isoformat(), "photo": public(chosen),
                                   "available": [s for s, c in (("commons", commons), ("mapillary", mly),
                                                                ("website", site)) if c]}
        src = chosen["source"] if chosen else "none"
        counts.setdefault(p["category"], {}).setdefault(src, 0)
        counts[p["category"]][src] += 1
    data["verified"] = {u: v for u, v in data["verified"].items() if v.get("checked", "") >= stale
                        or not v.get("checked")}
    save(slug, data)
    print("  photos verified by source: " + "; ".join(f"{s} {v['verified']} ok, {v['failed']} failed"
                                                       for s, v in sorted(verified.items())))
    if mly_report:
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as f:
                f.write(mly_report)
        print(mly_report)
    return counts, mly_note


def main():
    import score  # score imports this module; import it here to avoid a cycle
    parser = argparse.ArgumentParser(description="Find a photo for every candidate place (ADR 015).")
    parser.add_argument("city")
    parser.add_argument("--max-age-days", type=int, default=30, help="re-check cached lookups older than this")
    parser.add_argument("--diagnose-mapillary", type=int, default=0, metavar="N",
                        help="log the raw Mapillary candidates of N sample places (to $GITHUB_STEP_SUMMARY in CI)")
    args = parser.parse_args()
    ctx = score.candidates(args.city)
    counts, note = run(ctx, args.max_age_days, os.environ.get("MAPILLARY_TOKEN", "").strip() or None,
                       diagnose=args.diagnose_mapillary)
    total = sum(sum(c.values()) for c in counts.values())
    have = sum(n for c in counts.values() for s, n in c.items() if s != "none")
    print(f"photos {args.city}: {have}/{total} places have a photo; per category and source: "
          + "; ".join(f"{cat} {dict(sorted(c.items()))}" for cat, c in sorted(counts.items())))
    if note:
        print(f"  !!! {note}")
    print(f"  wrote {cache_path(args.city)}")


if __name__ == "__main__":
    main()
