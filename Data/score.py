"""Step 3: score POIs, apply manual curation, write the app's pois-<city>.json (PLAN.md 5.3-5.5).

    python3 score.py lodz

Reads cache/<city>/enriched.json and curation.csv.
Writes App/Wander/Resources/pois-<city>.json and review/<city>-top300.csv (for hand review).
"""
import csv
import datetime
import json
import math
import sys
from pathlib import Path

from common import DATA, RESOURCES, cache_dir, load_city, metres

# ---- Tunable weights (PLAN.md 5.3) -------------------------------------------------------
WEIGHTS = {
    "photo": {"photo": 0.45, "landmark": 0.45, "quality": 0.10},
    "shop":  {"unique": 0.50, "quality": 0.30, "photo": 0.20},
    "food":  {"unique": 0.50, "quality": 0.30, "photo": 0.20},
}
SITELINK_CAP = 40          # sitelinks at which the fame signal saturates
LANDMARK_TAG_BONUS = 0.25  # tourism/historic tag alone counts for something
POPULAR_PHOTO_PCT = 0.80   # photo percentile above which a reason says "popular photo spot"
FAMOUS_SITELINKS = 10      # sitelinks above which a reason says "well-known"
DEFAULT_BOOST = 20         # points added by a curation "boost" with no value
DUPLICATE_RADIUS_M = 40    # same name this close = same place
MIN_SCORE = 15             # drop anything below this from the app file
REVIEW_TOP_N = 300
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
}
ARTWORK_LABELS = {"mural": "Mural", "sculpture": "Sculpture", "statue": "Statue",
                  "installation": "Installation", "relief": "Relief"}


def sentence(text):
    return text[:1].upper() + text[1:] if text else text


def landmark_signal(p):
    t = p["tags"]
    fame = min(1.0, math.log1p(p["sitelinks"]) / math.log1p(SITELINK_CAP))
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
            key = key or t.get("historic") or t.get("man_made") or t.get("leisure")
            base = PHOTO_LABELS.get(key) or ("Landmark" if t.get("tourism") == "attraction"
                                             else sentence((key or "landmark").replace("_", " ")))
        extras = []
        if p["sitelinks"] >= FAMOUS_SITELINKS:
            extras.append("well-known landmark")
        if photo_pct >= POPULAR_PHOTO_PCT:
            extras.append("popular photo spot")
        return ", ".join([base] + extras)

    indie = is_unique(p)
    if cat == "food":
        kind = t.get("amenity") if t.get("amenity") in FOOD_LABELS else t.get("shop")
        cuisine = (t.get("cuisine") or "").split(";")[0].replace("_", " ").strip()
        if t.get("amenity") == "restaurant":
            label = f"{cuisine} restaurant" if cuisine and cuisine != "regional" else "Restaurant"
        else:
            label = FOOD_LABELS.get(kind, "Food")
        label = sentence(label)
        return f"Independent {label[0].lower() + label[1:]}" if indie else label

    label = SHOP_LABELS.get(t.get("shop")) or sentence(f"{t.get('shop', '').replace('_', ' ')} shop")
    if t.get("shop") == "yes":
        label = "Shop"
    return f"Independent {label[0].lower() + label[1:]}" if indie else label


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
        name = p["name"].casefold()
        if any(q["name"].casefold() == name and
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

    for p in pois:
        signals = {
            "photo": pct[p["id"]],
            "landmark": landmark_signal(p),
            "unique": 1.0 if is_unique(p) else 0.0,
            "quality": quality_signal(p),
        }
        w = WEIGHTS[p["category"]]
        p["score"] = round(100 * sum(w[k] * signals[k] for k in w))
        p["reason"] = draft_reason(p, pct[p["id"]])
        p["kind"] = "passby" if p["category"] == "photo" else "stop"

    pois, applied = apply_curation(pois, load_curation())
    pois = dedupe(pois)
    before_cut = len(pois)
    pois = [p for p in pois if p["score"] >= MIN_SCORE]
    pois.sort(key=lambda p: (-p["score"], p["name"]))

    out_pois = []
    for p in pois:
        row = {k: p[k] for k in ("id", "name", "lat", "lon", "category", "score", "kind", "reason")}
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
    review = review_dir / f"{slug}-top{REVIEW_TOP_N}.csv"
    with review.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["rank", "osm_id", "name", "category", "score", "reason", "sitelinks", "commons", "osm_url"])
        for i, p in enumerate(pois[:REVIEW_TOP_N], 1):
            typ, num = p["id"].split(":")[1:]
            w.writerow([i, p["id"], p["name"], p["category"], p["score"], p["reason"],
                        p["sitelinks"], p["commons"], f"https://www.openstreetmap.org/{typ}/{num}"])

    by_cat = {c: sum(p["category"] == c for p in pois) for c in ("photo", "shop", "food")}
    print(f"{city['name']}: {len(pois)} POIs {by_cat} "
          f"({before_cut - len(pois)} below score {MIN_SCORE}, {applied} curation rules applied)")
    print(f"  wrote {out.relative_to(DATA.parent)} ({out.stat().st_size // 1024} KB)")
    print(f"  wrote {review.relative_to(DATA.parent)}")


if __name__ == "__main__":
    main()
