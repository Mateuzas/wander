"""Step 3: score POIs, apply manual curation, write the app's pois-<city>.json (PLAN.md 5.3-5.5).

    python3 score.py lodz

Reads cache/<city>/enriched.json and curation.csv.
Writes App/Wander/Resources/pois-<city>.json and review/<city>-review.csv (for hand review).
"""
import csv
import datetime
import json
import math
import sys
import urllib.parse
from pathlib import Path

from common import DATA, RESOURCES, cache_dir, load_city, metres
from fetch_osm import venue_kind

# ---- Tunable weights (PLAN.md 5.3) -------------------------------------------------------
WEIGHTS = {
    "photo": {"photo": 0.45, "landmark": 0.45, "quality": 0.10},
    "shop":  {"quality": 0.60, "photo": 0.40},
    "food":  {"quality": 0.60, "photo": 0.40},
}
# PLAN.md gave shops/food 0.5 for merely being unbranded, so every independent café outranked
# real sights (Łódź top 300: 244 food, 5 photo). Instead, independence is a multiplier and
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
MIN_SCORE = 15              # drop anything below this from the app file
MAX_IMAGE_SHARES = 3       # a photo used by this many places is too generic to show
POPULAR_SHARE = 0.05       # top share of each category (by score) marked popular on the map...
POPULAR_FAME = 0.6         # ...plus sights this well-known (fame signal), whatever their score
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
    if p["category"] == "photo":
        return (t.get("artwork_type") if t.get("tourism") == "artwork" else None) \
            or (t.get("memorial") if t.get("historic") == "memorial" else None) \
            or (t.get("tourism") if t.get("tourism") not in (None, "attraction") else None) \
            or t.get("historic") or t.get("man_made") or t.get("leisure") or venue_kind(t) or "attraction"
    if p["category"] == "food":
        return t.get("amenity") if t.get("amenity") in FOOD_LABELS or t.get("amenity") == "restaurant" \
            else t.get("shop", "food")
    return t.get("shop", "shop")


def landmark_signal(p):
    t = p["tags"]
    fame = fame_signal(p)
    bonus = LANDMARK_TAG_BONUS if (t.get("tourism") in LANDMARK_TOURISM or "historic" in t) else 0
    return min(1.0, 0.75 * fame + bonus)


def photo_percentiles(pois):
    """Percentile rank of Commons file count within the city; places with no photos get 0."""
    counts = sorted(p["commons"] for p in pois)
    n = len(counts)
    pct = {}
    for c in set(counts):
        if c == 0:
            pct[c] = 0.0
        else:
            below = sum(x < c for x in counts)
            equal = sum(x == c for x in counts)
            pct[c] = (below + 0.5 * equal) / n
    return {p["id"]: pct[p["commons"]] for p in pois}


def quality_signal(p):
    t = p["tags"]
    return sum(any(k in t for k in keys) for keys in QUALITY_FIELDS) / len(QUALITY_FIELDS)


def is_unique(p):
    t = p["tags"]
    return not ("brand" in t or "brand:wikidata" in t)


def draft_reason(p, photo_pct):
    """A short, concrete, human reason. Curation can override it."""
    t, cat = p["tags"], p["category"]
    if cat == "photo":
        if t.get("tourism") == "artwork":
            base = ARTWORK_LABELS.get(t.get("artwork_type"), "Public artwork")
            artist = t.get("artist_name") or t.get("artist")
            if artist and artist not in p["name"]:
                base += f" by {artist}"
        else:
            key = t.get("tourism") if t.get("tourism") not in (None, "attraction") else None
            key = key or t.get("historic") or t.get("man_made") or t.get("leisure") or venue_kind(t)
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


def popular_ids(pois):
    """Ids marked popular: the top POPULAR_SHARE of each category by score (at least one),
    plus well-known sights; curation overrides win over both."""
    ids = set()
    for cat in ("photo", "shop", "food"):
        ranked = sorted((p for p in pois if p["category"] == cat), key=lambda p: (-p["score"], p["id"]))
        if ranked:
            k = max(1, math.floor(POPULAR_SHARE * len(ranked) + 0.5))  # round half up
            ids.update(p["id"] for p in ranked[:k])
    ids.update(p["id"] for p in pois if p["category"] == "photo" and fame_signal(p) >= POPULAR_FAME)
    for p in pois:
        if "popular_override" in p:
            (ids.add if p["popular_override"] else ids.discard)(p["id"])
    return ids


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


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: python3 score.py <city>")
    slug = sys.argv[1]
    city = load_city(slug)
    pois = json.loads((cache_dir(slug) / "enriched.json").read_text())["pois"]
    pct = photo_percentiles(pois)
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
    before_cut = len(pois)
    pois = [p for p in pois if p["score"] >= MIN_SCORE]
    renamed = name_generic_sights(pois)
    pois.sort(key=lambda p: (-p["score"], p["name"]))
    popular = popular_ids(pois)

    # A photo shared by several places is a series-level Wikidata image (e.g. one statue
    # standing in for a whole trail of them), so it shows none of them reliably.
    image_uses = {}
    for p in pois:
        if p["category"] == "photo" and commons_image(p):
            image_uses[commons_image(p)] = image_uses.get(commons_image(p), 0) + 1

    category_uses = {}
    for p in pois:
        if p["category"] == "photo" and commons_category(p):
            category_uses[commons_category(p)] = category_uses.get(commons_category(p), 0) + 1

    out_pois = []
    for p in pois:
        row = {k: p[k] for k in ("id", "name", "lat", "lon", "category", "score", "kind", "reason")}
        row["type"] = poi_type(p)
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
        out_pois.append(row)

    RESOURCES.mkdir(parents=True, exist_ok=True)
    out = RESOURCES / f"pois-{slug}.json"
    out.write_text(json.dumps({
        "city": city["name"],
        "generated": datetime.date.today().isoformat(),
        "attribution": "© OpenStreetMap contributors",
        "pois": out_pois,
    }, ensure_ascii=False, indent=1))

    review_dir = DATA / "review"
    review_dir.mkdir(exist_ok=True)
    review = review_dir / f"{slug}-review.csv"
    review_rows = [p for cat, n in REVIEW_PER_CATEGORY.items()
                   for p in [q for q in pois if q["category"] == cat][:n]]
    with review.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["rank", "osm_id", "name", "original_name", "category", "score", "reason", "sitelinks", "commons", "osm_url"])
        for i, p in enumerate(review_rows, 1):
            typ, num = p["id"].split(":")[1:]
            w.writerow([i, p["id"], p["name"], p["original_name"], p["category"], p["score"], p["reason"],
                        p["sitelinks"], p["commons"], f"https://www.openstreetmap.org/{typ}/{num}"])

    by_cat = {c: sum(p["category"] == c for p in pois) for c in ("photo", "shop", "food")}
    print(f"{city['name']}: {len(pois)} POIs {by_cat} "
          f"({before_cut - len(pois)} below score {MIN_SCORE}, {applied} curation rules applied, {renamed} generic names expanded)")
    untranslated = [p for p in pois if p["category"] == "photo" and p["id"] not in names_en
                    and not p["tags"].get("name:en")]
    if untranslated:
        print(f"  ! {len(untranslated)} sights have no English name; add them to names-en/{slug}.csv:")
        for p in untranslated[:10]:
            print(f"    {p['id']},,{p['original_name']}")
    pop_by_cat = {c: sum(p["category"] == c and p["id"] in popular for p in pois) for c in by_cat}
    print(f"  popular per category: {pop_by_cat}")
    print(f"  wrote {out.relative_to(DATA.parent)} ({out.stat().st_size // 1024} KB)")
    print(f"  wrote {review.relative_to(DATA.parent)}")


if __name__ == "__main__":
    main()
