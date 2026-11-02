"""Step 1: pull candidate POIs for a city from OpenStreetMap (Overpass API).

    python3 fetch_osm.py lodz            # reuse cached Overpass response if present
    python3 fetch_osm.py lodz --refresh  # re-download

Writes cache/<city>/osm_raw.json (Overpass response) and
cache/<city>/osm.json (named POIs with a category: photo|shop|food).
"""
import json
import sys

from common import cache_dir, http_json, load_city, metres

OVERPASS = "https://overpass-api.de/api/interpreter"

# Shops that are errands, not discoveries (PLAN.md 5.1).
BORING_SHOPS = {
    "supermarket", "convenience", "chemist", "mobile_phone", "car", "car_repair", "car_parts",
    "tyres", "fuel", "hairdresser", "beauty", "massage", "optician", "kiosk", "tobacco",
    "e-cigarette", "lottery", "money_lender", "pawnbroker", "funeral_directors", "dry_cleaning",
    "laundry", "copyshop", "hardware", "doityourself", "trade", "variety_store", "mall",
    "insurance", "travel_agency", "bookmaker", "vacant", "storage_rental", "motorcycle",
    "electrical", "telecommunication", "medical_supply", "hearing_aids", "nutrition_supplements",
    "alcohol", "beverages", "pet", "pet_grooming", "general", "department_store", "wholesale",
    "electronics", "computer", "appliance", "bathroom_furnishing", "kitchen", "doors", "windows",
    "flooring", "paint", "tiles", "curtain", "bed", "lighting", "houseware", "craft", "glaziery",
    "locksmith", "sewing", "fabric", "shoe_repair", "repair", "agrarian", "gas", "erotic",
    "weapons", "security", "health_food", "frozen_food", "dairy", "butcher", "greengrocer",
    "seafood", "cosmetics", "perfumery", "fashion_accessories", "bag", "baby_goods", "fireplace",
}
FOOD_SHOPS = {"bakery", "pastry", "deli", "confectionery", "chocolate", "coffee", "tea", "cheese"}
FOOD_AMENITIES = {"cafe", "restaurant", "bar", "ice_cream", "pub"}
PHOTO_TOURISM = {"attraction", "viewpoint", "artwork", "museum", "gallery"}
# Historic objects too small or too abstract to be worth walking past.
BORING_HISTORIC = {
    "memorial:plaque", "boundary_stone", "milestone", "district", "yes", "building",
    "stolperstein", "tomb", "grave", "archaeological_site", "aircraft",
}
MAX_SPOT_SIZE_M = 800     # a "spot" bigger than this is an area, not a place you walk past
MIN_PARK_SIZE_M = 200     # named parks smaller than this are pocket greens


def query(bbox):
    s, w, n, e = bbox
    b = f"({s},{w},{n},{e})"
    return f"""
[out:json][timeout:180];
(
  nwr["tourism"~"^(attraction|viewpoint|artwork|museum|gallery)$"]{b};
  nwr["historic"]{b};
  nwr["man_made"~"^(tower|lighthouse|bridge)$"]{b};
  nwr["leisure"="park"]["name"]{b};
  nwr["shop"]["name"]{b};
  nwr["amenity"~"^(cafe|restaurant|bar|ice_cream|pub)$"]["name"]{b};
);
out tags center bb;
"""


def size_m(el):
    """Diagonal of the element's bounding box in metres (0 for nodes)."""
    b = el.get("bounds")
    if not b:
        return 0.0
    return metres(b["minlat"], b["minlon"], b["maxlat"], b["maxlon"])


def location(el):
    """Point for an element. With `out center bb` Overpass returns only bounds for ways and
    relations (no center), so use the middle of the bounds."""
    if "lat" in el:
        return {"lat": el["lat"], "lon": el["lon"]}
    if "center" in el:
        return el["center"]
    b = el.get("bounds")
    if b:
        return {"lat": (b["minlat"] + b["maxlat"]) / 2, "lon": (b["minlon"] + b["maxlon"]) / 2}
    return None


def categorise(tags, size):
    """Return the category for an OSM element, or None to drop it."""
    tourism, historic, shop = tags.get("tourism"), tags.get("historic"), tags.get("shop")
    amenity, man_made, leisure = tags.get("amenity"), tags.get("man_made"), tags.get("leisure")

    if amenity in FOOD_AMENITIES or shop in FOOD_SHOPS:
        return "food"
    if tourism in PHOTO_TOURISM:
        return "photo" if size <= MAX_SPOT_SIZE_M else None
    if historic:
        key = "memorial:plaque" if historic == "memorial" and tags.get("memorial") == "plaque" else historic
        if key in BORING_HISTORIC:
            return None
        return "photo" if size <= MAX_SPOT_SIZE_M else None
    if man_made in {"tower", "lighthouse", "bridge"}:
        # "Notable only": something someone bothered to describe on Wikidata/Wikipedia.
        return "photo" if ("wikidata" in tags or "wikipedia" in tags) else None
    if leisure == "park":
        return "photo" if size >= MIN_PARK_SIZE_M else None
    if shop:
        return None if shop in BORING_SHOPS else "shop"
    return None


def display_name(tags):
    name = tags.get("name")
    if name:
        return name
    # Murals and sculptures are often unnamed in OSM but worth keeping.
    if tags.get("tourism") == "artwork":
        kind = {"mural": "Mural", "statue": "Statue", "sculpture": "Sculpture"}.get(
            tags.get("artwork_type"), "Artwork")
        artist = tags.get("artist_name") or tags.get("artist")
        if artist:
            return f"{kind} by {artist}"
        return kind if kind != "Artwork" else None
    return None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        sys.exit("usage: python3 fetch_osm.py <city> [--refresh]")
    slug = args[0]
    city = load_city(slug)
    raw_path = cache_dir(slug) / "osm_raw.json"
    if raw_path.exists() and "--refresh" not in sys.argv:
        print(f"Using cached {raw_path.name} (pass --refresh to re-download)")
        raw = json.loads(raw_path.read_text())
    else:
        print(f"Fetching OSM data for {city['name']} {city['bbox']} ...")
        raw = http_json(OVERPASS, data={"data": query(city["bbox"])})
        raw_path.write_text(json.dumps(raw, ensure_ascii=False))
    elements = raw.get("elements", [])
    print(f"  {len(elements)} raw elements")

    pois, dropped = [], {"unnamed": 0, "filtered": 0, "no_location": 0}
    for el in elements:
        tags = el.get("tags", {})
        name = display_name(tags)
        if not name:
            dropped["unnamed"] += 1
            continue
        size = size_m(el)
        category = categorise(tags, size)
        if not category:
            dropped["filtered"] += 1
            continue
        center = location(el)
        if not center:
            dropped["no_location"] += 1
            continue
        pois.append({
            "id": f"osm:{el['type']}:{el['id']}",
            "name": name,
            "lat": round(center["lat"], 6),
            "lon": round(center["lon"], 6),
            "category": category,
            "size_m": round(size),
            "tags": tags,
        })

    counts = {c: sum(p["category"] == c for p in pois) for c in ("photo", "shop", "food")}
    print(f"  kept {len(pois)} {counts}, dropped {dropped}")
    out = cache_dir(slug) / "osm.json"
    out.write_text(json.dumps({"city": city["name"], "pois": pois}, ensure_ascii=False, indent=1))
    print(f"  wrote {out.relative_to(out.parents[2])}")


if __name__ == "__main__":
    main()
