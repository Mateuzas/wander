"""Step 3: score POIs, apply manual curation, write the app's pois-<city>.json (PLAN.md 5.3-5.5).

    python3 score.py vilnius                        # the app's bundled file
    python3 score.py vilnius --out /tmp/pois.json   # elsewhere (nightly job, ADR 013)

Reads cache/<city>/enriched.json, curation.csv and, when present, sources/overture/<city>.json
(Overture Maps Places, ADR 014: see overture.py).
Writes App/Wander/Resources/pois-<city>.json and review/<city>-review.csv (for hand review).
With --out it writes only the given file: no review CSV, nothing inside the repo.
"""
import argparse
import csv
import datetime
import json
import math
import re
import sys
import urllib.parse
from pathlib import Path
from types import SimpleNamespace

import hooks
import overture
import photos
import website
from common import DATA, RESOURCES, cache_dir, load_city, metres
from describe import osm_description, trim_extract
from enrich import COMMONS_RADIUS_M, TILE_LIMIT, count_near
from fetch_osm import building_kind, historic_kind, venue_kind

# ---- Tunable weights (PLAN.md 5.3) -------------------------------------------------------
WEIGHTS = {
    "photo": {"photo": 0.45, "landmark": 0.45, "quality": 0.10},
    "shop":  {"quality": 0.60, "photo": 0.40},
    "food":  {"quality": 0.60, "photo": 0.40},
}
# PLAN.md gave shops/food 0.5 for merely being unbranded, so every independent café outranked
# real sights (in the first city's top 300: 244 food, 5 photo). Instead, independence is a multiplier and
# shop/food scores are capped so the best café can match a mid-level sight but never a landmark.
CATEGORY_CEILING = {"photo": 1.0, "shop": 0.70, "food": 0.70}
BRANDED_FACTOR = 0.3       # chains keep 30% of their score
SITELINK_CAP = 40          # sitelinks at which the fame signal saturates
LANDMARK_TAG_BONUS = 0.25  # tourism/historic tag alone counts for something
POPULAR_PHOTO_PCT = 0.80   # photo percentile above which a reason says "popular photo spot"
FAMOUS_SITELINKS = 10      # sitelinks above which a reason says "well-known"
DEFAULT_BOOST = 20         # points added by a curation "boost" with no value
DUPLICATE_RADIUS_M = 40    # same name this close = same place
NEAR_RADIUS_M = 250        # "Mural near X": how far X may be from a generically named sight
NEAR_MIN_SCORE = 40        # X must be a sight at least this good, so tourists know it
SCORE_FLOOR = {"photo": 30, "shop": 30, "food": 35}  # drop places scoring below this, after curation (ADR 012)
MAX_IMAGE_SHARES = 3       # a photo used by this many places is too generic to show
TIER1_SHARE = 0.04         # tier 1 (must-see): top share of each category by score, at least one...
TIER1_FAME = 0.8           # ...plus sights this well-known (fame signal), whatever their score...
TIER1_PHOTO_CAP = 25       # ...but at most this many sights (highest scores kept)
TIER2_SHARE = 0.15         # tier 2 (notable): the next share of each category by score; the rest are tier 3
REVIEW_PER_CATEGORY = {"photo": 150, "food": 75, "shop": 75}  # rows in the hand-review sheet
# ------------------------------------------------------------------------------------------

LANDMARK_TOURISM = {"attraction", "museum", "gallery", "viewpoint", "artwork"}
QUALITY_FIELDS = [
    ("opening_hours",),
    ("website", "contact:website", "url"),
    ("phone", "contact:phone"),
    ("wheelchair",),
    ("description", "wikipedia", "cuisine"),
]
SHOP_LABELS = {
    "books": "Bookshop", "clothes": "Clothing shop", "second_hand": "Second-hand shop",
    "antiques": "Antiques shop", "art": "Art shop", "gift": "Gift shop", "jewelry": "Jewellery shop",
    "music": "Record shop", "toys": "Toy shop", "florist": "Florist", "shoes": "Shoe shop",
    "furniture": "Furniture shop", "interior_decoration": "Interior shop", "bicycle": "Bike shop",
    "photo": "Photo shop", "boutique": "Boutique", "wine": "Wine shop", "tea": "Tea shop",
    "herbalist": "Herbalist", "tattoo": "Tattoo studio", "hifi": "Hi-fi shop",
    "mall": "Shopping centre",
}
FOOD_LABELS = {
    "cafe": "Café", "bar": "Bar", "pub": "Pub", "ice_cream": "Ice cream",
    "bakery": "Bakery", "pastry": "Pastry shop", "deli": "Deli", "confectionery": "Sweet shop",
    "chocolate": "Chocolate shop", "coffee": "Coffee roaster", "tea": "Tea shop", "cheese": "Cheese shop",
}
PHOTO_LABELS = {
    "museum": "Museum", "gallery": "Art gallery", "viewpoint": "Viewpoint",
    "monument": "Monument", "memorial": "Memorial", "castle": "Castle", "church": "Historic church",
    "manor": "Manor house", "palace": "Palace", "city_gate": "City gate", "wayside_shrine": "Wayside shrine",
    "industrial": "Industrial heritage", "factory": "Historic factory", "ruins": "Ruins",
    "tower": "Tower", "bridge": "Bridge", "park": "Park",
    # Venues (BE-4)
    "stadium": "Stadium", "theatre": "Theatre", "concert_hall": "Concert hall", "zoo": "Zoo",
    "aquarium": "Aquarium", "theme_park": "Theme park", "arts_centre": "Arts centre",
    "events_venue": "Arena", "sports_hall": "Arena", "sports_centre": "Arena",
    # Landmark buildings tagged only by their use (BE-2); "cathedral", "chapel"... read fine as is
    "place_of_worship": "Place of worship", "townhall": "Town hall",
    "music_venue": "Music venue",  # Overture-only (ADR 014)
}
MEMORIAL_LABELS = {"statue": "Statue", "bust": "Bust", "sculpture": "Sculpture", "bench": "Bench sculpture",
                   "stone": "Memorial stone", "obelisk": "Obelisk", "war_memorial": "War memorial"}
PHOTO_LABELS.update({f"memorial:{k}": v for k, v in MEMORIAL_LABELS.items()})
ARTWORK_LABELS = {"mural": "Mural", "sculpture": "Sculpture", "statue": "Statue",
                  "installation": "Installation", "relief": "Relief"}


def sentence(text):
    return text[:1].upper() + text[1:] if text else text


def fame_signal(p):
    """0-1, log-scaled Wikipedia sitelink count (how famous the place is)."""
    return min(1.0, math.log1p(p["sitelinks"]) / math.log1p(SITELINK_CAP))


def poi_type(p):
    """Most specific OSM value describing the place, e.g. mural, museum, church, cafe, books."""
    t = p["tags"]
    if p.get("ovt_type"):
        return p["ovt_type"]  # Overture-only place: the type its category mapping chose
    if p["category"] == "photo":
        return (t.get("artwork_type") if t.get("tourism") == "artwork" else None) \
            or (t.get("memorial") if t.get("historic") == "memorial" else None) \
            or (t.get("tourism") if t.get("tourism") not in (None, "attraction") else None) \
            or historic_kind(t) or t.get("man_made") or t.get("leisure") or venue_kind(t) \
            or building_kind(t) or "attraction"
    if p["category"] == "food":
        return t.get("amenity") if t.get("amenity") in FOOD_LABELS or t.get("amenity") == "restaurant" \
            else t.get("shop", "food")
    return t.get("shop", "shop")


def landmark_signal(p):
    t = p["tags"]
    fame = fame_signal(p)
    bonus = LANDMARK_TAG_BONUS if (t.get("tourism") in LANDMARK_TOURISM or "historic" in t) else 0
    return min(1.0, 0.75 * fame + bonus)


def photo_percentiles(pois, extra=()):
    """Percentile rank of Commons file count within the city; places with no photos get 0.
    `extra` places (Overture-only) are ranked against the same OSM distribution without
    joining it, so adding them never shifts an OSM place's signal."""
    counts = sorted(p["commons"] for p in pois)
    n = len(counts)
    pct = {}
    for c in {p["commons"] for p in [*pois, *extra]}:
        if c == 0:
            pct[c] = 0.0
        else:
            below = sum(x < c for x in counts)
            equal = sum(x == c for x in counts)
            pct[c] = (below + 0.5 * equal) / n
    return {p["id"]: pct[p["commons"]] for p in [*pois, *extra]}


def commons_counter(slug):
    """Function giving the Commons photo count near each (lat, lon), from enrich.py's tile cache,
    counted exactly as enrich.py counts them for OSM places."""
    path = cache_dir(slug) / "commons_tiles.json"
    tiles = json.loads(path.read_text()) if path.exists() else {}
    points = set()
    for files in tiles.values():
        if len(files) < TILE_LIMIT:  # leaf tiles only, as in enrich.fetch_commons_points
            points.update(map(tuple, files))
    points = list(points)

    def counts(latlons):
        pois = [{"id": i, "lat": lat, "lon": lon} for i, (lat, lon) in enumerate(latlons)]
        near = count_near(pois, points, COMMONS_RADIUS_M)
        return [near[i] for i in range(len(latlons))]
    return counts


def quality_signal(p):
    if "ovt_quality" in p:
        return p["ovt_quality"]  # Overture-only: completeness of its record (overture.quality)
    t = p["tags"]
    return sum(any(k in t for k in keys) for keys in QUALITY_FIELDS) / len(QUALITY_FIELDS)


def is_unique(p):
    t = p["tags"]
    return not ("brand" in t or "brand:wikidata" in t)


def draft_reason(p, photo_pct):
    """A short, concrete, human reason. Curation can override it."""
    t, cat = p["tags"], p["category"]
    if cat == "photo" and p.get("ovt_type"):
        # Overture-only gallery or venue: its kind only. Nearby Commons photos show the street is
        # photogenic, not that a shop-like gallery is a photo spot.
        return PHOTO_LABELS.get(p["ovt_type"]) or sentence(p["ovt_type"].replace("_", " "))
    if cat == "photo":
        if t.get("tourism") == "artwork":
            base = ARTWORK_LABELS.get(t.get("artwork_type"), "Public artwork")
            artist = t.get("artist_name") or t.get("artist")
            if artist and artist not in p["name"]:
                base += f" by {artist}"
        else:
            key = p.get("ovt_type") or (t.get("tourism") if t.get("tourism") not in (None, "attraction") else None)
            key = key or historic_kind(t) or t.get("man_made") or t.get("leisure") or venue_kind(t) \
                or building_kind(t)
            if key == "memorial" and t.get("memorial") in MEMORIAL_LABELS:
                key = "memorial:" + t["memorial"]
            if key == "castle" and t.get("castle_type") in ("palace", "manor", "stately"):
                key = "palace" if t["castle_type"] != "manor" else "manor"
            base = PHOTO_LABELS.get(key) or ("Landmark" if t.get("tourism") == "attraction"
                                             else sentence((key or "landmark").replace("_", " ")))
        extras = []
        if p["sitelinks"] >= FAMOUS_SITELINKS:
            if base == "Landmark":
                base = "Well-known landmark"
            else:
                extras.append("well-known landmark")
        if photo_pct >= POPULAR_PHOTO_PCT:
            extras.append("popular photo spot")
        return ", ".join([base] + extras)

    # Independence already shapes the score; repeating it in every reason is noise.
    if cat == "food":
        kind = t.get("amenity") if t.get("amenity") in FOOD_LABELS else t.get("shop")
        cuisine = (t.get("cuisine") or "").split(";")[0].replace("_", " ").strip()
        if t.get("amenity") == "restaurant":
            label = f"{cuisine} restaurant" if cuisine and cuisine != "regional" else "Restaurant"
        else:
            label = FOOD_LABELS.get(kind, "Food")
        return sentence(label)

    label = SHOP_LABELS.get(t.get("shop")) or sentence(f"{t.get('shop', '').replace('_', ' ')} shop")
    return "Shop" if t.get("shop") == "yes" else label


def commons_image(p):
    """Commons file name (no "File:" prefix) of the place's own photo, or None.

    OSM tags are specific to the object, so they win; Wikidata's main image (P18) is the
    common fallback. Category links and photos hosted elsewhere are ignored.
    """
    if "image_override" in p:
        return p["image_override"] or None
    t = p["tags"]
    tag = t.get("wikimedia_commons", "")
    if tag.startswith("File:"):
        return tag[len("File:"):].strip()
    image = t.get("image", "")
    if "commons.wikimedia.org/wiki/File:" in image:
        return urllib.parse.unquote(image.split("/wiki/File:", 1)[1]).replace("_", " ").strip()
    return p.get("wikidata_image")


def commons_category(p):
    """Commons category with more photos of this place (no "Category:" prefix), or None."""
    if p.get("image_override") == "":
        return None  # its Wikidata item is a different place, so its category is too
    tag = p["tags"].get("wikimedia_commons", "")
    if tag.startswith("Category:"):
        return tag[len("Category:"):].strip()
    return p.get("wikidata_category")


def round_half_up(x):
    return math.floor(x + 0.5)


def below_floor(p):
    """Under its category's score floor; a curation `popular yes` rescues a known gem (ADR 012)."""
    return p["score"] < SCORE_FLOOR[p["category"]] and not p.get("popular_override")


def tier3_only(p):
    """Overture-only galleries stay tier 3 (Architect decision, BE-7 follow-up to ADR 014): Overture's
    art_gallery-like categories are mostly commercial (jewellery schools, shops), so without an OSM
    match (which would make it an osm: place) or a Wikidata link they never show at city or
    neighbourhood zoom. A curation `popular yes` still overrides this."""
    return (p["id"].startswith("ovt:") and p["category"] == "photo" and p.get("ovt_type") == "gallery"
            and not p["tags"].get("wikidata") and not p.get("popular_override"))


def tiers(pois):
    """Map tier per id, within each category (ADR 012): 1 must-see, 2 notable, 3 detail.

    Tier 1 is the top TIER1_SHARE by score (at least one; ties by id), plus sights with fame of
    at least TIER1_FAME, with sights capped at TIER1_PHOTO_CAP. Tier 2 is the next TIER2_SHARE.
    A curation `popular yes` forces tier 1, `popular no` turns tier 1 off (tier 2).
    Overture-only galleries are always tier 3 (see tier3_only)."""
    tier = {}
    for cat in ("photo", "shop", "food"):
        ranked = sorted((p for p in pois if p["category"] == cat), key=lambda p: (-p["score"], p["id"]))
        if not ranked:
            continue
        n = len(ranked)  # shares count every place in the category...
        capped = [p for p in ranked if tier3_only(p)]  # ...but these never take a tier 1-2 slot
        for p in capped:
            tier[p["id"]] = 3
        ranked = [p for p in ranked if not tier3_only(p)]
        k = max(1, round_half_up(TIER1_SHARE * n))
        top = [p for i, p in enumerate(ranked)
               if i < k or (cat == "photo" and fame_signal(p) >= TIER1_FAME)]
        if cat == "photo":
            top = top[:TIER1_PHOTO_CAP]  # ranked order, so the highest scores stay
        top_ids = {p["id"] for p in top}
        for p in ranked:
            if "popular_override" in p:
                (top_ids.add if p["popular_override"] else top_ids.discard)(p["id"])
        rest = [p for p in ranked if p["id"] not in top_ids]
        m = round_half_up(TIER2_SHARE * n)
        for i, p in enumerate(rest):
            tier[p["id"]] = 2 if i < m or p.get("popular_override") is False else 3
        tier.update((i, 1) for i in top_ids)
    return tier


def load_wikipedia(slug):
    """English Wikipedia summaries fetched by wikipedia.py; empty when it has not been run."""
    path = cache_dir(slug) / "wikipedia_cache.json"
    if not path.exists():
        print("  ! no wikipedia_cache.json: run wikipedia.py for Wikipedia descriptions")
        return {"enwiki": {}, "summaries": {}}
    return json.loads(path.read_text())


def article_title(p, wiki):
    """English Wikipedia title for a place: OSM `wikipedia=en:...`, else its Wikidata enwiki link."""
    t = p["tags"]
    if t.get("wikipedia", "").startswith("en:"):
        return t["wikipedia"][3:].strip() or None
    return wiki["enwiki"].get(t.get("wikidata", ""))


def article_key(p, wiki):
    title = article_title(p, wiki)
    summary = wiki["summaries"].get(title) if title else None
    return summary["url"] if summary else title


def own_summary(p, wiki, article_uses):
    """The English Wikipedia summary that describes this place itself, or None.

    An emptied image means the place's Wikidata item is a different place (curation.csv);
    an article shared by several places (e.g. a museum and its branches) describes only the
    place it is named after."""
    title = article_title(p, wiki)
    own = title and (article_uses.get(article_key(p, wiki), 0) == 1
                     or re.sub(r"\s*\(.*\)$|,.*$", "", title).casefold() == p["name"].casefold())
    summary = wiki["summaries"].get(title) if own and p.get("image_override") != "" else None
    return summary if summary and summary.get("type") != "disambiguation" else None


def description(p, typ, popular, wiki, article_uses):
    """(text, source, url) for the place card, or None (CONTRACTS §1 `description`).

    The English Wikipedia lead wins wherever there is one; popular places without one get a
    sentence composed from their OSM tags. Nothing is written beyond what the source says."""
    summary = own_summary(p, wiki, article_uses)
    if summary:
        text = trim_extract(summary.get("extract"))
        if text:
            return text, "wikipedia", summary["url"]
    if popular:
        text = osm_description(p, typ)
        if text:
            return text, "osm", None
    return None


def load_curation():
    path = DATA / "curation.csv"
    rules = {}
    with path.open(newline="") as f:
        for row in csv.DictReader(f):
            osm_id = (row.get("osm_id") or "").strip()
            if osm_id and not osm_id.startswith("#"):
                rules.setdefault(osm_id, []).append(
                    ((row.get("action") or "").strip(), (row.get("value") or "").strip()))
    return rules


def load_english_names(slug):
    """Reviewed English display names (names-en/<city>.csv). OSM rarely has name:en and
    Wikidata labels are unreliable, so these are drafted once and edited by hand."""
    path = DATA / "names-en" / f"{slug}.csv"
    if not path.exists():
        return {}
    with path.open(newline="") as f:
        return {r["osm_id"]: r["name_en"].strip() for r in csv.DictReader(f) if r.get("name_en", "").strip()}


def english_name(p, names_en):
    """Sights get an English name; shops and food keep their own (they are proper names)."""
    if p["id"] in names_en:
        return names_en[p["id"]]
    if p["category"] == "photo":
        # Wikidata labels are a fallback only: names-en/<city>.csv is the reviewed source.
        return p["tags"].get("name:en") or p.get("wikidata_label_en") or p["name"]
    return p["name"]


GENERIC_NAMES = set(ARTWORK_LABELS.values()) | set(MEMORIAL_LABELS.values()) | {"Public artwork"}


def name_generic_sights(pois):
    """A nudge for "Mural, 40 m ahead" means little. Name generic sights after their artist,
    or else after the nearest well-known sight. Returns how many were renamed."""
    anchors = [q for q in pois if q["category"] == "photo" and q["name"] not in GENERIC_NAMES
               and q["score"] >= NEAR_MIN_SCORE]
    renamed = 0
    for p in pois:
        if p["category"] != "photo" or p["name"] not in GENERIC_NAMES:
            continue
        artist = p["tags"].get("artist_name") or p["tags"].get("artist")
        if artist:
            label = p["name"]
            p["name"] = f"{label} by {artist}"
            p["reason"] = p["reason"].replace(f"{label} by {artist}", label, 1)  # don't repeat the name
        else:
            near = min(anchors, default=None, key=lambda q: metres(p["lat"], p["lon"], q["lat"], q["lon"]))
            if not near or metres(p["lat"], p["lon"], near["lat"], near["lon"]) > NEAR_RADIUS_M:
                continue
            p["name"] = f"{p['name']} near {near['name']}"
        renamed += 1
    return renamed


def apply_curation(pois, rules):
    kept, applied = [], 0
    for p in pois:
        excluded = False
        for action, value in rules.get(p["id"], []):
            applied += 1
            if action == "exclude":
                excluded = True
            elif action == "boost":
                p["score"] = min(100, p["score"] + (int(value) if value else DEFAULT_BOOST))
            elif action == "rename":
                p["name"] = value
            elif action == "reason":
                p["reason"] = value
            elif action == "popular":
                p["popular_override"] = value.strip().lower() in ("yes", "true", "1", "")
            elif action == "hook":
                p["hook_override"] = value  # hand-written hook line (ADR 015)
            elif action == "image":
                p["image_override"] = value  # empty value removes the photo
            else:
                print(f"  ! unknown curation action '{action}' for {p['id']}")
        if not excluded:
            kept.append(p)
    return kept, applied


def dedupe(pois):
    """Same name within a few metres is one place (e.g. a mural tagged twice). Keep the best."""
    pois = sorted(pois, key=lambda p: -p["score"])
    kept = []
    for p in pois:
        name = p["original_name"].casefold()  # stable regardless of translations
        if any(q["original_name"].casefold() == name and
               metres(p["lat"], p["lon"], q["lat"], q["lon"]) < DUPLICATE_RADIUS_M for q in kept):
            continue
        kept.append(p)
    return kept


def candidates(slug):
    """Every place that is published if it has a hook and a photo (ADR 015): the scored places
    after curation, de-duplication, the score floors and generic-name expansion, in output order.
    photos.py and hooks.py work on exactly this list; main() gates it and computes tiers.
    Returns a namespace with the places and what main() reports about them."""
    city = load_city(slug)
    pois = json.loads((cache_dir(slug) / "enriched.json").read_text())["pois"]
    ovt_data = overture.load(slug)
    added, ovt_report = overture.integrate(pois, ovt_data, commons_counter(slug)) if ovt_data else ([], None)
    pct = photo_percentiles(pois, added)
    pois += added
    today = datetime.date.today().isoformat()
    seen, bootstrap = overture.first_seen(slug, sorted(p["id"] for p in pois), today)
    names_en = load_english_names(slug)
    for p in pois:
        p["original_name"] = p["name"]
        p["name"] = english_name(p, names_en)

    for p in pois:
        signals = {
            "photo": pct[p["id"]],
            "landmark": landmark_signal(p),
            "unique": 1.0 if is_unique(p) else 0.0,
            "quality": quality_signal(p),
        }
        cat = p["category"]
        w = WEIGHTS[cat]
        raw = sum(w[k] * signals[k] for k in w) * CATEGORY_CEILING[cat]
        if cat != "photo" and not signals["unique"]:
            raw *= BRANDED_FACTOR
        p["score"] = round(100 * raw)
        p["reason"] = draft_reason(p, pct[p["id"]])
        p["kind"] = "passby" if p["category"] == "photo" else "stop"

    pois, applied = apply_curation(pois, load_curation())
    pois = dedupe(pois)
    before_floor = {c: sum(p["category"] == c for p in pois) for c in SCORE_FLOOR}
    pois = [p for p in pois if not below_floor(p)]
    renamed = name_generic_sights(pois)
    pois.sort(key=lambda p: (-p["score"], p["name"]))
    for p in pois:
        p["type"] = poi_type(p)
    wiki = load_wikipedia(slug)
    article_uses = {}  # by resolved article URL: two titles can redirect to one article
    for p in pois:
        if key := article_key(p, wiki):
            article_uses[key] = article_uses.get(key, 0) + 1
    for p in pois:  # what photos.py and hooks.py read (they never import score.py)
        p["wiki_summary"] = own_summary(p, wiki, article_uses)
        p["commons_file"] = commons_image(p)
        p["commons_cat"] = commons_category(p)
        p["site_url"] = p.get("website") or overture.website_from_osm(p["tags"])
    return SimpleNamespace(slug=slug, city=city, pois=pois, pct=pct, ovt_data=ovt_data, ovt_report=ovt_report,
                           today=today, seen=seen, bootstrap=bootstrap, names_en=names_en, applied=applied,
                           before_floor=before_floor, renamed=renamed, wiki=wiki, article_uses=article_uses)


def gate(ctx):
    """ADR 015: keep only places with both a hook and a photo, attaching them as `hook_text` and
    `photo_obj`. A curation `hook` row beats the committed hooks file; `popular yes` does not
    bypass the gate. Returns (kept places, report)."""
    hook_rows = hooks.load(ctx.slug)
    photo_cache = photos.load(ctx.slug)
    sites = website.load_cache(ctx.slug)
    report = {"kept": {}, "no_hook": {}, "no_photo": {}, "neither": {}, "stale_hook": 0, "stale_photo": 0,
              "curated_hook": 0, "bad_curated_hook": []}
    kept = []
    for p in ctx.pois:
        cat = p["category"]
        hook = None
        if "hook_override" in p:
            problem = hooks.problem(p["hook_override"], p["name"])
            if problem:
                report["bad_curated_hook"].append(f"{p['id']}: {problem}")
            else:
                hook = p["hook_override"]
                report["curated_hook"] += 1
        if hook is None:
            row = hook_rows.get(p["id"])
            if row:
                if row.get("facts_hash") == hooks.facts_hash(hooks.facts(p, ctx.city['name'], sites)):
                    hook = row.get("hook")
                else:
                    report["stale_hook"] += 1
        photo, fresh = photos.photo_for(p, photo_cache)
        if not fresh:
            report["stale_photo"] += 1
        if hook and photo:
            p["hook_text"], p["photo_obj"] = hook, photo
            kept.append(p)
            bucket = "kept"
        else:
            bucket = "neither" if not hook and not photo else ("no_hook" if not hook else "no_photo")
        report[bucket][cat] = report[bucket].get(cat, 0) + 1
    return kept, report


def print_gate(report, slug):
    def fmt(d):
        return ", ".join(f"{c} {d.get(c, 0)}" for c in ("photo", "shop", "food"))
    print(f"  hook+photo gate (ADR 015): kept {fmt(report['kept'])}; dropped: no hook {fmt(report['no_hook'])}; "
          f"no photo {fmt(report['no_photo'])}; neither {fmt(report['neither'])}")
    print(f"    {report['curated_hook']} curated hooks; {report['stale_hook']} committed hooks are stale "
          f"(facts changed: re-export and rewrite, Data/hooks/WRITING.md); "
          f"{report['stale_photo']} places with no or stale photo cache (run photos.py {slug})")
    for line in report["bad_curated_hook"]:
        print(f"  ! curation hook rejected, {line}")


def main():
    parser = argparse.ArgumentParser(description="Score POIs and write pois-<city>.json.")
    parser.add_argument("city")
    parser.add_argument("--out", type=Path, help="output file (default: App/Wander/Resources/pois-<city>.json); "
                                                 "skips the review CSV")
    args = parser.parse_args()
    slug = args.city
    ctx = candidates(slug)
    city, today, pct, wiki, article_uses = ctx.city, ctx.today, ctx.pct, ctx.wiki, ctx.article_uses
    ovt_data, ovt_report, seen, bootstrap = ctx.ovt_data, ctx.ovt_report, ctx.seen, ctx.bootstrap
    names_en, applied, before_floor, renamed = ctx.names_en, ctx.applied, ctx.before_floor, ctx.renamed
    after_floor = {c: sum(p["category"] == c for p in ctx.pois) for c in SCORE_FLOOR}
    pois, gate_report = gate(ctx)
    tier = tiers(pois)
    popular = {i for i, t in tier.items() if t == 1}  # `popular` equals tier 1 (ADR 012)

    # A photo shared by several places is a series-level Wikidata image (e.g. one statue
    # standing in for a whole trail of them), so it shows none of them reliably.
    image_uses = {}
    for p in ctx.pois:
        if p["category"] == "photo" and commons_image(p):
            image_uses[commons_image(p)] = image_uses.get(commons_image(p), 0) + 1

    category_uses = {}
    for p in ctx.pois:
        if p["category"] == "photo" and commons_category(p):
            category_uses[commons_category(p)] = category_uses.get(commons_category(p), 0) + 1

    out_pois = []
    for p in pois:
        row = {k: p[k] for k in ("id", "name", "lat", "lon", "category", "score", "kind", "reason")}
        row["type"] = p["type"]
        row["hook"] = p["hook_text"]
        row["photo"] = p["photo_obj"]
        if p["original_name"] != p["name"]:
            # Local (OSM) name, for matching Apple Maps places, which use it.
            row["localName"] = p["original_name"]
        # Raw 0-1 signals so the app can weight them per user; `score` is the default blend.
        row["signals"] = {
            "photos": round(pct[p["id"]], 3),
            "fame": round(fame_signal(p), 3),
            "quality": round(quality_signal(p), 3),
            "independent": is_unique(p),
        }
        cuisine = p["tags"].get("cuisine")
        if p["category"] == "food" and cuisine:
            row["cuisine"] = [c.strip() for c in cuisine.split(";") if c.strip()]
        row["tier"] = tier[p["id"]]
        if p["id"] in popular:
            row["popular"] = True
        category = commons_category(p) if p["category"] == "photo" else None
        if category and category_uses.get(category, 0) < MAX_IMAGE_SHARES:
            row["commonsCategory"] = category
        image = commons_image(p) if p["category"] == "photo" else None
        if image and image_uses.get(image, 0) < MAX_IMAGE_SHARES:
            row["commonsImage"] = image
        if p["category"] != "photo" and p["tags"].get("opening_hours"):
            row["openingHours"] = p["tags"]["opening_hours"]
        if "sources" in p:
            row["sources"] = p["sources"]
        if website := p.get("website") or overture.website_from_osm(p["tags"]):
            row["website"] = website
        if instagram := p.get("instagram") or overture.instagram_from_osm(p["tags"]):
            row["instagram"] = instagram
        if overture.is_new(p["id"], seen, bootstrap, today):
            row["new"] = True
        described = description(p, row["type"], p["id"] in popular, wiki, article_uses)
        if described:
            row["description"], row["descriptionSource"] = described[:2]
            if described[2]:
                row["descriptionUrl"] = described[2]
        out_pois.append(row)

    out = args.out or RESOURCES / f"pois-{slug}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({
        "city": city["name"],
        "generated": today,
        "attribution": "© OpenStreetMap contributors" + (", Overture Maps Foundation" if ovt_data else ""),
        "pois": out_pois,
    }, ensure_ascii=False, indent=1))

    review = None if args.out else write_review_csv(slug, pois)

    by_cat = {c: sum(p["category"] == c for p in pois) for c in ("photo", "shop", "food")}
    if ovt_report:
        overture.print_report(ovt_report, ovt_data.get("release"))
        kept = {c: sum(p["category"] == c and p["id"].startswith("ovt:") for p in pois) for c in by_cat}
        t12 = {c: sum(p["category"] == c and p["id"].startswith("ovt:") and tier[p["id"]] < 3 for p in pois)
               for c in by_cat}
        print(f"  overture-only after floors: {kept} (tier 1-2: {t12}); "
              f"new: {sum('new' in r for r in out_pois)} (first seen on {bootstrap} = bootstrap, never new)")
    print_gate(gate_report, slug)
    print(f"{city['name']}: {len(pois)} POIs {by_cat} "
          f"({applied} curation rules applied, {renamed} generic names expanded)")
    print("  score floors: " + ", ".join(f"{c} {before_floor[c]} -> {after_floor[c]} (floor {SCORE_FLOOR[c]})"
                                         for c in by_cat))
    tiers_by_cat = {c: [sum(p["category"] == c and tier[p["id"]] == t for p in pois) for t in (1, 2, 3)]
                    for c in by_cat}
    print("  tiers 1/2/3 per category: " + ", ".join(f"{c} {'/'.join(map(str, n))}"
                                                     for c, n in tiers_by_cat.items()))
    untranslated = [p for p in pois if p["category"] == "photo" and p["id"] not in names_en
                    and not p["tags"].get("name:en") and not p["id"].startswith("ovt:")]
    if untranslated:
        print(f"  ! {len(untranslated)} sights have no English name; add them to names-en/{slug}.csv:")
        for p in untranslated[:10]:
            print(f"    {p['id']},,{p['original_name']}")
    pop_by_cat = {c: sum(p["category"] == c and p["id"] in popular for p in pois) for c in by_cat}
    print(f"  popular per category: {pop_by_cat}")
    described = {r["id"]: r for r in out_pois if "description" in r}
    pop_desc = {c: sum(p["category"] == c and p["id"] in popular and p["id"] in described for p in pois)
                for c in by_cat}
    print(f"  popular with a description: " + ", ".join(f"{c} {pop_desc[c]}/{pop_by_cat[c]}" for c in by_cat))
    sources = {}
    for r in described.values():
        sources[r["descriptionSource"]] = sources.get(r["descriptionSource"], 0) + 1
    print(f"  descriptions: {len(described)} {sources}")
    print(f"  wrote {display_path(out)} ({out.stat().st_size // 1024} KB)")
    if review:
        print(f"  wrote {display_path(review)}")


def display_path(path):
    try:
        return path.resolve().relative_to(DATA.parent)
    except ValueError:
        return path


def write_review_csv(slug, pois):
    review_dir = DATA / "review"
    review_dir.mkdir(exist_ok=True)
    review = review_dir / f"{slug}-review.csv"
    review_rows = [p for cat, n in REVIEW_PER_CATEGORY.items()
                   for p in [q for q in pois if q["category"] == cat][:n]]
    with review.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["rank", "osm_id", "name", "original_name", "category", "score", "reason", "sitelinks", "commons", "osm_url"])
        for i, p in enumerate(review_rows, 1):
            if p["id"].startswith("osm:"):
                typ, num = p["id"].split(":")[1:]
                url = f"https://www.openstreetmap.org/{typ}/{num}"
            else:  # ovt:<GERS id>
                url = f"https://explore.overturemaps.org/?mode=explore&feature=places.place.{p['id'][4:]}"
            w.writerow([i, p["id"], p["name"], p["original_name"], p["category"], p["score"], p["reason"],
                        p["sitelinks"], p["commons"], url])
    return review


if __name__ == "__main__":
    main()
