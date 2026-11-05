"""Place descriptions for the place card (BE-10, CONTRACTS §1 `description`).

Two sources only, never invented:
- the lead of the English Wikipedia article, trimmed to 1-2 whole sentences (`wikipedia`);
- a sentence or two composed from OSM tags that are present (`osm`).
Used by score.py; no network access here (wikipedia.py fills the cache).
"""
import re

MAX_LEN = 300
MIN_LEN = 20

# Words before a full stop that do not end a sentence.
ABBREVIATIONS = {"st", "sts", "mt", "dr", "jr", "sr", "c", "ca", "no", "nos", "vs", "etc", "e.g", "i.e",
                 "approx", "ft", "gen", "prof", "rev", "fr", "mr", "mrs", "ms", "lt", "col", "u.s", "a.k.a"}
BOUNDARY = re.compile(r'[.!?]["”’)]?(?=\s+["“(]?[A-Z0-9ĄČĘĖĮŠŲŪŽ]|\s*$)')


def sentences(text):
    """Split prose into sentences, not breaking after abbreviations or initials ("M. K. Čiurlionis")."""
    out, start = [], 0
    for m in BOUNDARY.finditer(text):
        word = re.search(r"(\S+)$", text[start:m.start() + 1])
        token = word.group(1).rstrip(".").lstrip("(\"“").casefold() if word else ""
        if m.group(0)[0] == "." and (token in ABBREVIATIONS or (len(token) == 1 and token.isalpha())):
            continue
        out.append(text[start:m.end()].strip())
        start = m.end()
    rest = text[start:].strip()
    if rest:
        out.append(rest)
    return [s for s in out if s]


def trim_extract(extract):
    """The first one or two sentences of a Wikipedia extract, at most MAX_LEN characters,
    ending at a sentence end; None when even the first sentence is too long or too short."""
    parts = sentences(" ".join((extract or "").split()))
    if not parts or not parts[0].endswith((".", "!", "?", '."', ".”", ".)")):
        return None
    text = parts[0]
    if len(parts) > 1 and len(text) + 1 + len(parts[1]) <= MAX_LEN:
        text += " " + parts[1]
    return text if MIN_LEN <= len(text) <= MAX_LEN else None


# ---- OSM-composed descriptions -------------------------------------------------------------

DAY_NAMES = {"Mo": "Mon", "Tu": "Tue", "We": "Wed", "Th": "Thu", "Fr": "Fri", "Sa": "Sat", "Su": "Sun"}
DAY_RE = r"(?:Mo|Tu|We|Th|Fr|Sa|Su)"
DAYS_RE = re.compile(rf"^{DAY_RE}(?:-{DAY_RE})?(?:,{DAY_RE}(?:-{DAY_RE})?)*$")
TIME_RE = re.compile(r"^([01]?\d|2[0-4]):([0-5]\d)-([01]?\d|2[0-4]):([0-5]\d)$")


def _days(spec):
    if spec in ("Mo-Su", "Su-Sa"):
        return "daily"
    groups = [g.replace("-", "–") for g in spec.split(",")]
    for short, long in DAY_NAMES.items():
        groups = [g.replace(short, long) for g in groups]
    return groups[0] if len(groups) == 1 else ", ".join(groups[:-1]) + " and " + groups[-1]


def _times(spec):
    out = []
    for span in spec.split(","):
        m = TIME_RE.match(span)
        if not m:
            return None
        h1, m1, h2, m2 = m.groups()
        out.append(f"{int(h1)}:{m1}–{int(h2)}:{m2}")
    return " and ".join(out)


def summarise_hours(oh):
    """Plain English for simple opening_hours ("Mo-Fr 10:00-18:00; Sa,Su off"), else None."""
    oh = (oh or "").strip().rstrip(";")
    if oh == "24/7":
        return "Open 24 hours, every day."
    # "PH off" (closed on public holidays) is dropped: the summary is about the usual week.
    rules = [r.strip() for r in oh.split(";") if r.strip() and r.strip() != "PH off"]
    if not rules or len(rules) > 3:
        return None
    open_parts, closed = [], []
    for rule in rules:
        days, _, times = rule.partition(" ")
        if not times:  # "10:00-20:00" applies to every day
            days, times = "Mo-Su", days
        if not DAYS_RE.match(days):
            return None
        if times in ("off", "closed"):
            closed.append(_days(days))
            continue
        t = _times(times)
        if not t:
            return None
        d = _days(days)
        open_parts.append(f"{d} {t}" if d != "daily" else f"daily {t}")
    if not open_parts:
        return None
    text = "Open " + ", ".join(open_parts)
    if closed:
        text += "; closed " + " and ".join(closed)
    return text + "."


NATIONAL = {"american", "argentinian", "armenian", "asian", "austrian", "azerbaijani", "balkan", "belgian",
            "brazilian", "british", "caucasian", "chinese", "czech", "english", "european", "french",
            "georgian", "german", "greek", "hungarian", "indian", "irish", "israeli", "italian", "japanese",
            "jewish", "korean", "latvian", "lebanese", "lithuanian", "mediterranean", "mexican",
            "middle eastern", "nepalese", "nordic", "peruvian", "polish", "portuguese", "russian",
            "scandinavian", "spanish", "syrian", "taiwanese", "thai", "turkish", "ukrainian", "uzbek",
            "vietnamese", "arab", "persian", "korean", "eastern european", "latin american"}
# Cuisine values that only repeat the kind of place.
REDUNDANT_CUISINE = {"coffee_shop", "cafe", "pub", "bar", "ice_cream", "bakery", "regional", "local", "bistro",
                     "restaurant", "fine_dining"}
NOUNS = {"restaurant": "restaurant", "cafe": "café", "bar": "bar", "pub": "pub", "ice_cream": "ice cream shop",
         "bakery": "bakery", "pastry": "pastry shop", "deli": "deli", "confectionery": "sweet shop",
         "chocolate": "chocolate shop", "coffee": "coffee roaster", "tea": "tea shop", "cheese": "cheese shop"}
BUILT_TYPES = {"church", "cathedral", "chapel", "castle", "palace", "manor", "tower", "bridge", "city_gate",
               "townhall", "place_of_worship", "university", "monastery", "synagogue", "building",
               "museum", "theatre", "concert_hall", "stadium", "gallery", "arts_centre", "factory"}


def _join(items):
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1]


def _cuisine_words(tags):
    words = []
    for c in (tags.get("cuisine") or "").split(";"):
        c = c.strip().casefold()
        if not c or c in REDUNDANT_CUISINE:
            continue
        w = c.replace("_", " ")
        words.append(w.title() if w in NATIONAL else w)
    return words[:3]


def _food_sentence(tags):
    kind = tags.get("amenity") if tags.get("amenity") in NOUNS else tags.get("shop")
    noun = NOUNS.get(kind, "place to eat")
    cuisine = _cuisine_words(tags)
    head = f"{_join(cuisine)} {noun}" if cuisine else noun
    extras = []
    if tags.get("outdoor_seating") == "yes":
        extras.append("outdoor seating")
    menus, options = [], []
    for diet in ("vegetarian", "vegan"):
        value = tags.get(f"diet:{diet}")
        if value == "only":
            menus.append(diet)
        elif value == "yes":
            options.append(diet)
    if menus:
        extras.append(f"an all-{menus[-1]} menu")  # vegan-only implies vegetarian-only
        options = [o for o in options if o not in menus and not (o == "vegetarian" and "vegan" in menus)]
    if options:
        extras.append(f"{_join(options)} options")
    if tags.get("takeaway") in ("yes", "only"):
        extras.append("takeaway only" if tags["takeaway"] == "only" else "takeaway")
    text = head + (" with " + _join(extras) if extras else "")
    return text[:1].upper() + text[1:] + ".", bool(cuisine or extras)


def _shop_sentence(tags):
    extras = []
    if tags.get("second_hand") in ("yes", "only"):
        extras.append("second-hand goods" if tags["second_hand"] == "only" else "some second-hand goods")
    if tags.get("organic") in ("yes", "only"):
        extras.append("organic products")
    if not extras:
        return None
    return "Sells " + _join(extras) + "."


def _year_phrase(start):
    """"1387" -> "in 1387", "C18" -> "in the 18th century"; None for anything less plain."""
    s = (start or "").strip()
    if re.fullmatch(r"\d{4}", s):
        return f"in {s}"
    if m := re.fullmatch(r"(?:~|ca\.? ?|c\. ?)(\d{4})", s):
        return f"around {m.group(1)}"
    if m := re.fullmatch(r"(\d{4})-\d{2}(?:-\d{2})?", s):
        return f"in {m.group(1)}"
    if m := re.fullmatch(r"(\d{3}0)s", s):
        return f"in the {m.group(1)}s"
    if m := re.fullmatch(r"C(\d{1,2})", s):
        n = int(m.group(1))
        suffix = "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
        return f"in the {n}{suffix} century"
    return None


def _sight_sentences(p, typ):
    t = p["tags"]
    out = []
    when = _year_phrase(t.get("start_date"))
    if t.get("tourism") == "artwork":
        artist = t.get("artist_name") or t.get("artist")
        if artist and artist in p["name"]:
            artist = None
        if artist and when:
            out.append(f"Created by {artist} {when}.")
        elif artist:
            out.append(f"Created by {artist}.")
        elif when:
            out.append(f"Created {when}.")
    else:
        architect = (t.get("architect") or "").replace(";", ", ").strip() or None
        built = "building" in t or typ in BUILT_TYPES
        if when and built:
            out.append(f"Built {when}" + (f" to a design by {architect}." if architect else "."))
        elif when:
            out.append(f"Dates from {when.removeprefix('in ')}.")
        if architect and not (when and built):
            out.append(f"Designed by {architect}.")
    if t.get("heritage"):
        out.append("Protected as cultural heritage.")
    return out[:2]


def osm_description(p, typ):
    """1-2 sentences from OSM tags, or None when the tags add nothing to the reason.
    Opening hours are appended to other facts but never stand alone."""
    t, cat = p["tags"], p["category"]
    parts = []
    if cat == "food":
        first, informative = _food_sentence(t)
        if informative and first.rstrip(".").casefold() != p["reason"].casefold():
            parts.append(first)
    elif cat == "shop":
        if s := _shop_sentence(t):
            parts.append(s)
    else:
        parts += _sight_sentences(p, typ)
    if not parts:
        return None  # opening hours alone say nothing about the place
    if len(parts) < 2 and (hours := summarise_hours(t.get("opening_hours"))):
        parts.append(hours)
    text = " ".join(parts)
    return text if MIN_LEN <= len(text) <= MAX_LEN else None
