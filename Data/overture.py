"""Overture Maps Places as the second place source (ADR 014, BE-7). Standard library only.

score.py calls `integrate()` with the enriched OSM POIs. It reads sources/overture/<city>.json
(written monthly by overture_extract.py; absent means nothing happens), selects the places worth
showing, merges those already in OSM into the OSM record (the OSM record wins: "overture" is added
to its `sources` and a missing website or Instagram handle is filled), and returns the rest as new
POIs with id `ovt:<Overture id>`, shaped like enriched OSM POIs (synthetic OSM-style tags), so the
usual scoring, floors, tiers and descriptions apply to them.

It also keeps cache/<city>/first_seen.json (git-ignored): the first date each id was seen. Ids first
seen in the last NEW_DAYS days are `new`, except on the bootstrap run that creates the file
(everything is "first seen" then, so nothing is flagged).
"""
import datetime
import difflib
import json
import re
import unicodedata
import urllib.parse

from common import DATA, cache_dir, metres

# ---- Tunable selection (ADR 014) ---------------------------------------------------------
MIN_CONFIDENCE = 0.7       # the extract keeps >= 0.5; this is the real threshold
CLOSED_STATUSES = {"permanently_closed", "temporarily_closed", "closed"}
SAME_NAME_RADIUS_M = 60    # equal normalised names this close are one place
SIMILAR_NAME_RADIUS_M = 25  # ...or similar names (difflib ratio >= SIMILAR_RATIO) this close
SIMILAR_RATIO = 0.85
CONTAINED_RADIUS_M = 30    # ...or one name's words all within the other's ("Soprano" in "Kavinė-ledainė Soprano")
# ...or the same website domain within SAME_NAME_RADIUS_M (Meta pages are often named oddly), except these hosts:
SHARED_HOSTS = {"facebook.com", "instagram.com", "business.site", "linktr.ee", "google.com", "wixsite.com",
                "wordpress.com", "weebly.com", "blogspot.com", "tripadvisor.com", "booking.com", "wolt.com",
                "bolt.eu", "treatwell.lt", "x.com", "twitter.com", "youtube.com", "tiktok.com"}
# Lithuanian case endings dropped from words before comparing (Amatininkų = Amatininkai), longest first.
ENDINGS = ("iai", "iu", "ai", "as", "es", "os", "is", "ys", "us", "u", "a", "e", "o", "i", "s")
NEW_DAYS = 60              # first seen this recently = `new`
CHAIN_MIN_PLACES = 2       # a brand name on this many places in the city (or on Wikidata) is a chain...
CHAIN_MIN_SAME_NAME = 3    # ...and so is a name on this many places, branded or not (Meta pages often lack the brand)

# Overture taxonomy name -> (category, OSM-style type), or None to ignore that branch.
# A place's taxonomy hierarchy is searched from the most specific name up, so "italian_restaurant"
# falls through to "restaurant", while "karaoke_venue" stops at None before "music_venue".
# Types are the OSM values the app already knows (CONTRACTS §1 `type`).
CATEGORY_MAP = {
    # food (types as in fetch_osm FOOD_AMENITIES / FOOD_SHOPS)
    "restaurant": ("food", "restaurant"), "bistro": ("food", "restaurant"), "diner": ("food", "restaurant"),
    "steakhouse": ("food", "restaurant"), "pancake_house": ("food", "restaurant"),
    "fast_food_restaurant": None, "food_truck": None, "food_court": None,
    "cafe": ("food", "cafe"), "coffee_shop": ("food", "cafe"), "tea_room": ("food", "cafe"),
    "bubble_tea_shop": ("food", "cafe"), "internet_cafe": None,
    "bar": ("food", "bar"), "wine_bar": ("food", "bar"), "cocktail_bar": ("food", "bar"),
    "beer_bar": ("food", "bar"), "whiskey_bar": ("food", "bar"), "sports_bar": ("food", "bar"),
    "beer_garden": ("food", "bar"), "brewery": ("food", "bar"), "gay_bar": ("food", "bar"),
    "pub": ("food", "pub"), "gastropub": ("food", "pub"), "irish_pub": ("food", "pub"),
    "hookah_bar": None, "lounge": None,
    "bakery": ("food", "bakery"), "patisserie": ("food", "pastry"), "cupcake_shop": ("food", "pastry"),
    "donut_shop": ("food", "pastry"), "dessert_shop": ("food", "pastry"),
    "ice_cream_shop": ("food", "ice_cream"), "gelato": ("food", "ice_cream"),
    "frozen_yoghurt_shop": ("food", "ice_cream"),
    "chocolatier": ("food", "chocolate"), "candy_store": ("food", "confectionery"),
    "delicatessen": ("food", "deli"), "cheese_shop": ("food", "cheese"),
    "coffee_roastery": ("food", "coffee"), "coffee_and_tea_supplies": ("food", "tea"),
    # shop: only kinds in the spirit of fetch_osm TOURIST_SHOPS (browsable, not errands)
    "bookstore": ("shop", "books"), "used_bookstore": ("shop", "books"), "comic_book_store": ("shop", "comics"),
    "music_and_dvd_store": ("shop", "music"), "vinyl_record_store": ("shop", "music"),
    "musical_instrument_store": ("shop", "musical_instrument"),
    "second_hand_store": ("shop", "second_hand"), "thrift_store": ("shop", "second_hand"),
    "vintage_and_consignment_store": ("shop", "second_hand"), "flea_market": ("shop", "second_hand"),
    "pawn_shop": None,
    "antique_store": ("shop", "antiques"), "gift_shop": ("shop", "gift"), "souvenir_store": ("shop", "souvenir"),
    "art_supply_store": ("shop", "art"), "arts_crafts_and_hobby_store": ("shop", "craft"),
    "craft_shop": ("shop", "craft"), "fashion_boutique": ("shop", "boutique"), "toy_store": ("shop", "toys"),
    "wine_store": ("shop", "wine"), "board_game_store": ("shop", "games"), "pottery_store": ("shop", "pottery"),
    "camera_store": ("shop", "photo"),
    # photo: galleries and live-music / performance venues
    "art_gallery": ("photo", "gallery"), "music_venue": ("photo", "music_venue"),
    "jazz_and_blues_venue": ("photo", "music_venue"), "karaoke_venue": None,
    "theatre_venue": ("photo", "theatre"), "concert_hall": ("photo", "concert_hall"),
    "opera_and_ballet": ("photo", "theatre"), "cultural_center": ("photo", "arts_centre"),
}
# Generic words dropped before comparing names ("Kavinė Mano" = "Mano"); compared without diacritics.
GENERIC_WORDS = {
    "cafe", "caffe", "coffee", "kavine", "kava", "restaurant", "restoranas", "restorane", "bar", "baras",
    "pub", "bistro", "bistras", "pizzeria", "picerija", "kepykla", "kepyklele", "bakery", "vynine",
    "wine", "gallery", "galerija", "shop", "store", "parduotuve", "parduotuvele", "krautuvele", "knygynas",
    "bookshop", "bookstore", "ledaine", "ledai", "uzeiga", "kavos", "the", "and", "ir", "uab", "lt",
    "vilnius", "vilniuje", "vilniaus",
}
# Cuisine from the taxonomy name ("italian_restaurant" -> "italian"); these say nothing about food.
CUISINE_SKIP = {"buffet", "theme", "comfort_food", "bar_and_grill", "special_diet", "health_food",
                "breakfast_and_brunch", "fast_food", "eastern_european", "european", "asian",
                "east_asian", "southeast_asian", "central_european", "mediterranean", "latin_american",
                "middle_eastern", "western_european"}
CUISINE_ALIASES = {"steakhouse": "steak_house", "doner_kebab": "kebab", "texmex": "tex-mex"}
QUALITY_KEYS = ("website", "instagram", "address", "phone", "multi_source")
INSTAGRAM_RE = re.compile(r"^(?:https?://(?:www\.)?instagram\.com/)?@?([A-Za-z0-9._]{1,30})/?$", re.I)
# ------------------------------------------------------------------------------------------


def load(slug):
    path = DATA / "sources" / "overture" / f"{slug}.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def strip_accents(text):
    return "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c))


def norm_name(name):
    """casefold, no diacritics or punctuation, generic words dropped (unless nothing is left)."""
    words = re.findall(r"[a-z0-9]+", strip_accents(name.casefold()))
    kept = [w for w in words if w not in GENERIC_WORDS]
    return " ".join(kept or words)


def mapped(place):
    """(category, type) for an Overture place, or None."""
    tax = place.get("taxonomy") or {}
    for name in reversed(tax.get("hierarchy") or [tax.get("primary")]):
        if name in CATEGORY_MAP:
            return CATEGORY_MAP[name]
    return None


def cuisine(place):
    for name in reversed((place.get("taxonomy") or {}).get("hierarchy") or []):
        if name == "steakhouse" or (name.endswith("_restaurant") and name != "restaurant"):
            c = name.removesuffix("_restaurant")
            if c in CUISINE_SKIP:
                continue
            return CUISINE_ALIASES.get(c, c)
    return None


def chains(places):
    """(brand names, normalised place names) that mark a chain: a brand on CHAIN_MIN_PLACES places in
    the city, or a name on CHAIN_MIN_SAME_NAME places. Meta attaches a "brand" to many single-location
    pages, so a brand on one place alone does not make a chain; a Wikidata-linked brand does."""
    brands, names = {}, {}
    for p in places:
        if isinstance(p.get("brand"), str):
            brands[p["brand"].casefold()] = brands.get(p["brand"].casefold(), 0) + 1
        n = norm_name(p["name"])
        names[n] = names.get(n, 0) + 1
    return ({b for b, n in brands.items() if n >= CHAIN_MIN_PLACES},
            {b for b, n in names.items() if n >= CHAIN_MIN_SAME_NAME})


def is_chain(p, chain_names):
    brands, names = chain_names
    b = p.get("brand")
    return b is True or (isinstance(b, str) and b.casefold() in brands) or norm_name(p["name"]) in names


def instagram_from_osm(tags):
    m = INSTAGRAM_RE.match((tags.get("contact:instagram") or tags.get("instagram") or "").strip())
    return m.group(1) if m and m.group(1).lower() not in ("p", "reel", "explore") else None


TRACKING_PARAMS = re.compile(r"^(utm_.*|fbclid|gclid|dclid|msclkid|igshid|rwg_token|y_source|mc_[a-z]+|_ga)$", re.I)


def clean_url(url):
    """The URL without tracking parameters (utm_*, fbclid, Google's rwg_token...), or None if not http(s)."""
    url = (url or "").strip()
    if not re.match(r"https?://\S+$", url):
        return None
    parts = urllib.parse.urlsplit(url)
    if not parts.query:
        return url
    query = [(k, v) for k, v in urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
             if not TRACKING_PARAMS.match(k)]
    return urllib.parse.urlunsplit(parts._replace(query=urllib.parse.urlencode(query)))


def website_from_osm(tags):
    for key in ("website", "contact:website", "url"):
        if v := clean_url(tags.get(key)):
            return v
    return None


class Index:
    """Coarse grid of places for "anything within 60 m" lookups."""
    CELL = 0.001  # ~111 m of latitude; 60 m lookups need only the neighbouring cells

    def __init__(self):
        self.grid = {}

    def add(self, item, lat, lon, names, domain=None):
        self.grid.setdefault((int(lat / self.CELL), int(lon / self.CELL)), []).append(
            (item, lat, lon, names, domain))

    def match(self, lat, lon, names, domain=None):
        """Closest item that is the same place by name (or website) and distance, or None."""
        best = None
        ci, cj = int(lat / self.CELL), int(lon / self.CELL)
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for item, la, lo, other, other_domain in self.grid.get((ci + di, cj + dj), ()):
                    d = metres(lat, lon, la, lo)
                    if d > max(SAME_NAME_RADIUS_M, SIMILAR_NAME_RADIUS_M, CONTAINED_RADIUS_M) \
                            or (best and d >= best[0]):
                        continue
                    if same_place(names, other, d) or (domain and domain == other_domain
                                                       and d <= SAME_NAME_RADIUS_M):
                        best = (d, item)
        return best[1] if best else None


def domain(url):
    """Website host without www, or None for hosts shared by many places (facebook.com...)."""
    host = urllib.parse.urlsplit(url or "").hostname or ""
    host = host.removeprefix("www.").removeprefix("m.")
    if not host or any(host == h or host.endswith("." + h) for h in SHARED_HOSTS):
        return None
    return host


def stem(word):
    for end in ENDINGS:
        if len(word) - len(end) >= 4 and word.endswith(end):
            return word[:-len(end)]
    return word


def stems(name):
    return {stem(w) for w in name.split()}


def same_place(a, b, d):
    """Two lists of normalised names, d metres apart: the same place?"""
    for x in a:
        for y in b:
            sx, sy = stems(x), stems(y)
            if (x == y or sx == sy) and d <= SAME_NAME_RADIUS_M:
                return True
            if d <= SIMILAR_NAME_RADIUS_M and difflib.SequenceMatcher(None, x, y).ratio() >= SIMILAR_RATIO:
                return True
            if d <= CONTAINED_RADIUS_M:
                small = min((sx, sy), key=len)
                if (sx <= sy or sy <= sx) and max(map(len, small), default=0) >= 4:
                    return True
    return False


def osm_names(p):
    t = p["tags"]
    raw = [p["name"], t.get("name"), t.get("name:lt"), t.get("name:en"), t.get("alt_name"), t.get("old_name")]
    return sorted({norm_name(n) for n in raw if n})


def quality(place):
    """Completeness, 0-1: website, Instagram, address, phone, and more than one source dataset."""
    have = {"website": "website" in place, "instagram": "instagram" in place, "address": "address" in place,
            "phone": bool(place.get("phone")), "multi_source": len(place.get("datasets") or []) > 1}
    return sum(have[k] for k in QUALITY_KEYS) / len(QUALITY_KEYS)


def synthetic_tags(category, typ, place):
    """OSM-style tags so score.py's type, reason and description code reads the place like OSM."""
    tags = {"name": place["name"]}
    if category == "food":
        tags["amenity" if typ in ("restaurant", "cafe", "bar", "pub", "ice_cream") else "shop"] = typ
        if typ == "restaurant" and (c := cuisine(place)):
            tags["cuisine"] = c
    elif category == "shop":
        tags["shop"] = typ
    elif typ == "gallery":
        tags["tourism"] = "gallery"
    else:
        tags["amenity"] = typ
    if website := clean_url(place.get("website")):
        tags["website"] = website
    return tags


def first_seen(slug, ids, today):
    """{id: first-seen date}, updating cache/<city>/first_seen.json, and the bootstrap date
    (the run that created the file: ids first seen then are never `new`)."""
    path = cache_dir(slug) / "first_seen.json"
    state = json.loads(path.read_text()) if path.exists() else {"bootstrap": today, "first_seen": {}}
    seen = state["first_seen"]
    for i in ids:
        seen.setdefault(i, today)
    path.write_text(json.dumps(state, sort_keys=True, indent=0))
    return seen, state["bootstrap"]


def is_new(pid, seen, bootstrap, today):
    date = seen.get(pid)
    if not date or date == bootstrap:
        return False
    age = (datetime.date.fromisoformat(today) - datetime.date.fromisoformat(date)).days
    return age < NEW_DAYS


def integrate(pois, data, commons_counts):
    """Merge Overture places into the OSM POIs (in place) and return (new POIs, report).

    `commons_counts(list of (lat, lon))` gives the Commons photo count near each point.
    """
    places = data["places"]
    chain_names = chains(places)
    report = {"total": len(places), "confident": 0, "closed": 0, "chain": 0, "unmapped": {},
              "selected": {}, "matched": 0, "matched_osm": set(), "filled_website": 0,
              "filled_instagram": 0, "duplicates": 0, "added": {}}
    selected = []
    for p in places:
        if p.get("confidence", 0) < MIN_CONFIDENCE:
            continue
        report["confident"] += 1
        if p.get("operating_status") in CLOSED_STATUSES:
            report["closed"] += 1
            continue
        if is_chain(p, chain_names):
            report["chain"] += 1
            continue
        m = mapped(p)
        if not m:
            key = p.get("basic_category") or "(none)"
            report["unmapped"][key] = report["unmapped"].get(key, 0) + 1
            continue
        report["selected"][m[0]] = report["selected"].get(m[0], 0) + 1
        selected.append((p, m))

    osm = Index()
    for q in pois:
        osm.add(q, q["lat"], q["lon"], osm_names(q), domain(website_from_osm(q["tags"])))
    # Most confident first, so a duplicate inside Overture keeps its best record.
    selected.sort(key=lambda pm: (-pm[0]["confidence"], pm[0]["id"]))
    added, ovt = [], Index()
    for p, (category, typ) in selected:
        names = sorted({norm_name(n) for n in (p["name"], p.get("local_name")) if n})
        site = domain(p.get("website"))
        q = osm.match(p["lat"], p["lon"], names, site)
        if q:
            report["matched"] += 1
            report["matched_osm"].add(q["id"])
            q["sources"] = ["osm", "overture"]
            if not q.get("website") and not website_from_osm(q["tags"]) and clean_url(p.get("website")):
                q["website"] = clean_url(p["website"])
                report["filled_website"] += 1
            if not q.get("instagram") and not instagram_from_osm(q["tags"]) and p.get("instagram"):
                q["instagram"] = p["instagram"]
                report["filled_instagram"] += 1
            continue
        if ovt.match(p["lat"], p["lon"], names, site):
            report["duplicates"] += 1
            continue
        poi = {
            "id": f"ovt:{p['id']}", "name": p["name"], "lat": p["lat"], "lon": p["lon"],
            "category": category, "tags": synthetic_tags(category, typ, p), "size_m": 0,
            "sitelinks": 0, "wikidata_label_en": None, "wikidata_image": None, "wikidata_category": None,
            "sources": ["overture"], "ovt_quality": quality(p), "ovt_type": typ,
        }
        if website := clean_url(p.get("website")):
            poi["website"] = website
        if p.get("instagram"):
            poi["instagram"] = p["instagram"]
        ovt.add(poi, p["lat"], p["lon"], names, site)
        added.append(poi)
        report["added"][category] = report["added"].get(category, 0) + 1
    counts = commons_counts([(a["lat"], a["lon"]) for a in added])
    for a, n in zip(added, counts):
        a["commons"] = n
    report["matched_osm"] = len(report["matched_osm"])
    return added, report


def print_report(report, release, top=20):
    print(f"  overture {release}: {report['total']} places, {report['confident']} with confidence >= "
          f"{MIN_CONFIDENCE}; skipped {report['closed']} closed, {report['chain']} chains; selected "
          f"{report['selected']}")
    print(f"  overture dedupe: {report['matched']} matched {report['matched_osm']} OSM places "
          f"(filled {report['filled_website']} websites, {report['filled_instagram']} Instagram handles), "
          f"{report['duplicates']} Overture duplicates, added {report['added']} before floors")
    unmapped = sorted(report["unmapped"].items(), key=lambda kv: (-kv[1], kv[0]))
    print(f"  overture unmapped basic_category (top {top} of {len(unmapped)}, "
          f"{sum(report['unmapped'].values())} places; tune CATEGORY_MAP in overture.py):")
    for name, n in unmapped[:top]:
        print(f"    {n:5d}  {name}")
