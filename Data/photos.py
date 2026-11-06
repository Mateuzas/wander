"""Step 4a: a photo for every place (ADR 015, BE-14). Standard library only.

    python3 photos.py vilnius [--max-age-days 30]

For every candidate place (score.candidates: after curation, de-duplication and the floors) it
looks for, in priority order:

1. Commons: the place's own image (`commonsImage` logic, curation `image` included), then a file
   from its Commons category. A thumbnail URL at most THUMB_WIDTH wide, from an original at least
   COMMONS_MIN_WIDTH wide, with the author and licence from the Commons API.
2. Mapillary (only with MAPILLARY_TOKEN in the environment): the image a mapper put in the OSM
   `mapillary` tag, else the closest image within MAPILLARY_RADIUS_M whose camera faces the place
   (compass within FACING_DEG of the bearing to it). Never panoramas.
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
import hashlib
import html
import json
import math
import os
import re
import sys
import time
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
MAPILLARY_RADIUS_M = 40
FACING_DEG = 50
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
    for k in ("places", "commons_files", "commons_categories", "mapillary", "images"):
        data.setdefault(k, {})
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


def thumb_url(url, width):
    """The standard Commons thumbnail THUMB_WIDTH wide for an original upload URL (the original
    when it is not wider). Built from the URL instead of asking the API (`iiurlwidth`), which
    renders thumbnails and is rate limited."""
    prefix = "https://upload.wikimedia.org/wikipedia/commons/"
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

def bearing(lat1, lon1, lat2, lon2):
    """Initial compass bearing in degrees from point 1 to point 2."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    x = math.sin(dl) * math.cos(p2)
    y = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(x, y)) + 360) % 360


def angle_diff(a, b):
    return abs((a - b + 180) % 360 - 180)


def thumb_expiry(url):
    """Epoch seconds when a signed Mapillary thumbnail URL expires (`oe` is hex), or None."""
    oe = urllib.parse.parse_qs(urllib.parse.urlsplit(url or "").query).get("oe")
    try:
        return int(oe[0], 16) if oe else None
    except ValueError:
        return None


def mapillary_get(path, params, token):
    url = f"{MAPILLARY_API}/{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Authorization": f"OAuth {token}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def image_point(img):
    geo = img.get("computed_geometry") or img.get("geometry") or {}
    c = geo.get("coordinates")
    return (c[1], c[0]) if c else None


def mapillary_pick(lat, lon, images):
    """The closest non-panorama image within MAPILLARY_RADIUS_M whose camera faces (lat, lon)."""
    best = None
    for img in images:
        pt = image_point(img)
        compass = img.get("computed_compass_angle", img.get("compass_angle"))
        if not pt or compass is None or img.get("is_pano") or not img.get("thumb_1024_url"):
            continue
        d = metres(pt[0], pt[1], lat, lon)
        if d > MAPILLARY_RADIUS_M or angle_diff(compass, bearing(pt[0], pt[1], lat, lon)) > FACING_DEG:
            continue
        rank = (round(d, 1), -(img.get("captured_at") or 0), str(img["id"]))
        if best is None or rank < best[0]:
            best = (rank, img, d)
    return (best[1], best[2]) if best else (None, None)


def mapillary_candidate(img, distance=None):
    creator = (img.get("creator") or {}).get("username") or "Mapillary contributor"
    out = {"url": img["thumb_1024_url"], "source": "mapillary", "credit": f"{creator} / Mapillary",
           "license": MAPILLARY_LICENSE, "page": f"https://www.mapillary.com/app/?pKey={img['id']}",
           "id": str(img["id"]), "expires": thumb_expiry(img["thumb_1024_url"])}
    if distance is not None:
        out["distance_m"] = round(distance, 1)
    return out


def fetch_mapillary(p, token):
    """A Mapillary candidate for a place, or None."""
    tagged = p["tags"].get("mapillary", "").strip()
    if tagged.isdigit():
        img = mapillary_get(tagged, {"fields": MAPILLARY_FIELDS}, token)
        if img.get("thumb_1024_url") and not img.get("is_pano"):
            return mapillary_candidate(img)
    dlat = MAPILLARY_RADIUS_M * 1.2 / 111_320
    dlon = dlat / max(0.2, math.cos(math.radians(p["lat"])))
    bbox = f"{p['lon'] - dlon:.6f},{p['lat'] - dlat:.6f},{p['lon'] + dlon:.6f},{p['lat'] + dlat:.6f}"
    data = mapillary_get("images", {"fields": MAPILLARY_FIELDS, "bbox": bbox, "limit": 200}, token)
    img, d = mapillary_pick(p["lat"], p["lon"], data.get("data", []))
    return mapillary_candidate(img, d) if img else None


def refresh_mapillary_url(cand, token):
    img = mapillary_get(cand["id"], {"fields": "id,thumb_1024_url"}, token)
    if img.get("thumb_1024_url"):
        cand = {**cand, "url": img["thumb_1024_url"], "expires": thumb_expiry(img["thumb_1024_url"])}
    return cand


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
            out = {"url": url, "source": "website", "credit": website.domain(p["site_url"]), "page": p["site_url"]}
            if probe.get("width"):
                out["width"], out["height"] = probe["width"], probe.get("height")
            return out
    return None


# ---- Choice -----------------------------------------------------------------------------

def choose(p, commons, mapillary, site):
    """The photo to publish (ADR 015): Commons first; then food, shops and venues prefer a large
    website photo over Mapillary, and sights prefer Mapillary over the website."""
    if commons:
        return commons
    venue_like = p["category"] in ("food", "shop") or p.get("type") in VENUE_TYPES
    large_site = site if site and (site.get("width") or 0) >= WEBSITE_LARGE else None
    order = [large_site, mapillary, site] if venue_like else [mapillary, site]
    return next((c for c in order if c), None)


def public(photo):
    """The `photo` object as published (CONTRACTS §1): url, source, credit, license?, page?."""
    if not photo:
        return None
    return {k: photo[k] for k in ("url", "source", "credit", "license", "page") if photo.get(k)}


def run(ctx, max_age_days, token, today=None):
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

    mly_note = None
    if token:
        need = [p for p in pois if not commons_for(p)]
        soon = (datetime.datetime.combine(today, datetime.time()) +
                datetime.timedelta(days=MAPILLARY_REFRESH_DAYS)).timestamp()
        todo = [p for p in need if old(data["mapillary"].get(mkey(p)))]
        refresh = [p for p in need if p not in todo and (data["mapillary"][mkey(p)].get("photo") or {}).get("expires")
                   and data["mapillary"][mkey(p)]["photo"]["expires"] < soon]
        print(f"  mapillary: {len(todo)} searches, {len(refresh)} URL refreshes", flush=True)

        def search(p):
            try:
                return fetch_mapillary(p, token), None
            except Exception as exc:  # leave it unchecked; tried again next run
                return None, exc
        with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
            errors = 0
            for p, (cand, exc) in zip(todo, pool.map(search, todo)):
                if exc:
                    errors += 1
                    continue
                data["mapillary"][mkey(p)] = {"checked": today.isoformat(), "photo": cand}
            for p in refresh:
                try:
                    data["mapillary"][mkey(p)]["photo"] = refresh_mapillary_url(data["mapillary"][mkey(p)]["photo"], token)
                except Exception:
                    errors += 1
            if errors:
                print(f"  ! mapillary: {errors} requests failed (retried next run)")
    else:
        mly_note = "MAPILLARY_TOKEN not set: Mapillary skipped (cached Mapillary photos still used until they expire)"

    now = datetime.datetime.combine(today, datetime.time()).timestamp()
    image_sites = {}
    for url in {p["site_url"] for p in pois if p.get("site_url")}:
        for img in sites.get(url, {}).get("images", []):
            image_sites.setdefault(img, set()).add(website.domain(url))
    shared = frozenset(img for img, domains in image_sites.items() if len(domains) > 1)
    counts = {}
    for p in pois:
        commons = commons_for(p)
        mly = (data["mapillary"].get(mkey(p)) or {}).get("photo")
        if mly and mly.get("expires") and mly["expires"] < now:
            mly = None  # signed URL already expired and could not be refreshed
        site = website_candidate(p, sites.get(p.get("site_url") or ""), data["images"], shared)
        chosen = choose(p, commons, mly, site)
        data["places"][p["id"]] = {"key": input_key(p), "checked": today.isoformat(), "photo": public(chosen),
                                   "available": [s for s, c in (("commons", commons), ("mapillary", mly),
                                                                ("website", site)) if c]}
        src = chosen["source"] if chosen else "none"
        counts.setdefault(p["category"], {}).setdefault(src, 0)
        counts[p["category"]][src] += 1
    save(slug, data)
    return counts, mly_note


def main():
    import score  # score imports this module; import it here to avoid a cycle
    parser = argparse.ArgumentParser(description="Find a photo for every candidate place (ADR 015).")
    parser.add_argument("city")
    parser.add_argument("--max-age-days", type=int, default=30, help="re-check cached lookups older than this")
    args = parser.parse_args()
    ctx = score.candidates(args.city)
    counts, note = run(ctx, args.max_age_days, os.environ.get("MAPILLARY_TOKEN", "").strip() or None)
    total = sum(sum(c.values()) for c in counts.values())
    have = sum(n for c in counts.values() for s, n in c.items() if s != "none")
    print(f"photos {args.city}: {have}/{total} places have a photo; per category and source: "
          + "; ".join(f"{cat} {dict(sorted(c.items()))}" for cat, c in sorted(counts.items())))
    if note:
        print(f"  !!! {note}")
    print(f"  wrote {cache_path(args.city)}")


if __name__ == "__main__":
    main()
