# POI data pipeline

Python 3, standard library only (except the monthly Overture extract, which needs `duckdb`).
Cities and their bounding boxes live in `cities.json`.

```sh
python3 fetch_osm.py vilnius   # OSM via Overpass → cache/vilnius/osm.json (raw response cached; --refresh to re-download)
python3 enrich.py vilnius      # Wikidata sitelinks + Commons photo counts (cached, ~10 min first run)
python3 wikipedia.py vilnius   # English Wikipedia summaries for place descriptions (cached, ~10 min first run)
python3 score.py vilnius       # scores + curation (+ Overture places) → App/Wander/Resources/pois-vilnius.json, review/vilnius-review.csv
```

Only `score.py` needs re-running after editing weights or `curation.csv`.
`score.py <city> --out <file>` writes the file elsewhere instead (no review CSV, nothing in the repo).

## Nightly job (ADR 013)

The DevOps workflow calls two scripts from the repo root; their flags are a stable interface.

```sh
python3 Data/run_nightly.py vilnius --out build/data [--refresh] [--previous <file|URL|none>]
python3 Data/publish_gate.py --new build/data/pois-vilnius.json --previous <file|URL|none> \
    [--curation Data/curation.csv] [--rerun <file>]
```

**`run_nightly.py`** runs fetch_osm (`--refresh` passed through), enrich, wikipedia and score for
the city and writes `<out>/pois-<city>.json`, never `App/Wander/Resources`. It runs score twice in
separate processes and fails if the two files differ, then validates the file against the schema.
It also writes `<out>/review-<city>.md`, the "needs review" summary: counts per category and tier,
description coverage, tier-1 places new or gone since `--previous` (default: the bundled file), and
sights without an English name. Unattended, such a sight (no `names-en` row, no OSM `name:en`)
shows its Wikidata English label, else its local name; that never fails the run. Exit status is
non-zero only on real errors: a step failing (e.g. network down after the retries), or an output
that is invalid or not deterministic. Nothing is committed to the repo.

**`publish_gate.py`** prints a Markdown summary (append it to `$GITHUB_STEP_SUMMARY`) and exits 1
if any check fails:

- the file passes `scripts/validate-pois.py` (imported, not copied);
- same `city`, same top-level keys, no POI field dropped (new fields are fine);
- POI count per category within ±25% of the previous file;
- every previous tier-1 id is still tier 1, or has a curation row (`exclude`, or `popular no`):
  to drop a must-see on purpose, add that row first;
- with `--rerun <file>` (a second build from the same caches): byte-identical, ignoring `generated`.

`--allow-growth` lets per-category counts grow by more than 25% (decreases are still gated); the
summary says so in a callout. Use it once, when a new source lands (the first Overture publish).

`--previous none` (first publish) or a 404 from the URL passes, with a note; any other download
error fails.

## What gets fetched

Photo spots (tourism, historic, notable towers and bridges, parks), browsable independent shops
(an allowlist of `shop=*` values) and food. See `fetch_osm.py` for the exact tags.

**Landmark buildings** (BE-2): churches and other places of worship, town halls and universities
(`amenity=place_of_worship|townhall|university`) count as sights when they have a `wikidata` or
`wikipedia` tag and are at most 800 m across. In Vilnius the Cathedral, the Town Hall, the
University and most Old Town churches carry no `tourism`/`historic` tag, so without this rule they
were missing. Streets (Pilies, Literatų) are not points and are not fetched; an OSM attraction on
the street (e.g. the Literatų Street project) stands in for it.

**Venues** (BE-4): stadiums (`leisure=stadium`), theatres, arts centres and concert halls
(`amenity=theatre|arts_centre|concert_hall`), arenas (`amenity=events_venue`, `leisure=sports_hall`, and `leisure=sports_centre`
only with a `wikidata`/`wikipedia` tag, since most are gyms), zoos, aquariums and theme parks
(`tourism=zoo|aquarium|theme_park`), and shopping malls (`shop=mall`). Malls are `shop`
(a stop); the rest are `photo` (a pass-by), with `type` set to the OSM value.
Only notable venues are kept: one with a `wikidata` or `wikipedia` tag, or with a footprint
(bounding-box diagonal) of at least 150 m. Venues may be up to 2,500 m across (other spots: 800 m).
Venues are searched in the city's optional `venue_bbox` (`cities.json`; for Vilnius the whole city),
everything else in `bbox`. Commons photo counts cover `bbox` only, so outer venues get photos = 0
and rely on Wikidata fame.
A venue already kept as a sight through another tag (e.g. `historic=theatre`) stays as it was.

## Overture Maps Places (ADR 014, BE-7)

OSM misses many small and new cafés, bars, galleries and shops; Overture (mostly Meta pages, plus
Foursquare and others) has them. Two steps:

**Monthly extract** (DevOps OPS-8; the only step with a non-stdlib dependency):

```sh
python3 -m venv ~/Library/Caches/wander/venv-overture     # outside the repo
~/Library/Caches/wander/venv-overture/bin/pip install -r Data/requirements-overture.txt   # duckdb, pinned
~/Library/Caches/wander/venv-overture/bin/python Data/overture_extract.py vilnius \
    [--release latest|2026-10-21.0] --out Data/sources/overture/vilnius.json
```

It reads `s3://overturemaps-us-west-2/release/<release>/theme=places/type=place/*` anonymously for
the city's `bbox` and keeps places with confidence ≥ 0.5. `latest` is the newest folder in an S3
listing of `release/` (`https://overturemaps-us-west-2.s3.amazonaws.com/?list-type=2&prefix=release/&delimiter=/`).
The file is committed (about 3 MB for Vilnius) and is deterministic for a given release apart from
`generated`: `release`, `generated`, and `places` sorted by id, one per line, each with `id`, `name`,
`local_name` (Lithuanian, when different), `lat`/`lon`, `basic_category`, `taxonomy`
(`primary`, `hierarchy`), `confidence`, `brand` (name, `true` if only a Wikidata id, else `false`),
`website` (first), `instagram` (handle from `socials`), `phone` (present = has one), `address`
(freeform), `operating_status`, `datasets` (source datasets) and `updated` (newest source update date).
Absent values are left out.

**Nightly merge** (`overture.py`, called by `score.py`; standard library; no file = no-op):

- **Select**: confidence ≥ 0.7, not closed, not a chain (a brand on 2+ places in the city, a
  Wikidata-only brand, or the same name on 3+ places), and a category in `CATEGORY_MAP`, the one
  mapping table (top of `overture.py`): food (restaurants, cafés, coffee shops, bars, pubs,
  bakeries, ice cream, chocolate...; not fast food), shop (books, records, second-hand, antiques,
  gifts, souvenirs, art and craft supplies, boutiques, toys, wine...: the `TOURIST_SHOPS` spirit) and
  photo (art galleries, music venues, theatres, cultural centres). The taxonomy hierarchy is searched
  from the most specific name up. `score.py` prints the top unmapped `basic_category` values, to tune it.
- **Dedupe with OSM**: same place if the normalised names (casefold, no diacritics or punctuation,
  generic words like "cafe", "kavinė", "baras" dropped, Lithuanian endings stripped) are equal within
  60 m, similar (difflib ratio ≥ 0.85) within 25 m, one contained in the other within 30 m, or the
  website domain is the same within 60 m. The OSM record wins: it gets `sources: ["osm", "overture"]`
  and a missing `website`/`instagram`. Duplicates inside Overture are merged the same way.
- **Overture-only places** become POIs with id `ovt:<Overture id>` and `sources: ["overture"]`,
  scored like the rest: fame 0, quality = completeness (website, Instagram, address, phone, more than
  one source dataset), photos from the same Commons tiles (ranked against the OSM distribution, so OSM
  scores do not move), independent. Then the same curation, floors, tiers and descriptions. Their
  names are proper names and stay as they are; `reason` is the kind ("Bar", "Italian restaurant",
  "Art gallery"). Curation rows work with `ovt:` ids too. Overture-only galleries (mostly
  commercial) stay tier 3 unless they have a Wikidata link or a curation `popular yes` (Architect
  decision, BE-7 follow-up); matched ones are OSM places and tier normally.
- **`new`**: `cache/<city>/first_seen.json` (git-ignored) keeps the first date each id was seen;
  ids first seen in the last 60 days get `new: true`. The run that creates the file is the bootstrap:
  everything is first seen that day, so nothing is flagged until later runs. The CI cache must keep
  this file between runs, or every run is a bootstrap.
- The file's `attribution` becomes "© OpenStreetMap contributors, Overture Maps Foundation".
  Every place also gets `website`/`instagram` from OSM tags when it has them.

Vilnius, release 2026-10-21.0: 5,060 places with confidence ≥ 0.7; 983 selected; 422 matched 416 OSM
places; 554 added before the floors, 276 after (food 177, photo 68, shop 31).

## English names (`names-en/<city>.csv`)

Sights are shown in English. OSM rarely has `name:en` and Wikidata labels are unreliable,
so each city has a reviewed `osm_id,name_en,original` file (first drafted by Claude: please check).
Shops and food keep their own names. Without a reviewed entry, a sight falls back to OSM `name:en`,
then the Wikidata English label, then its own name; `score.py` lists any sight still missing one.

Sights named only by their kind ("Mural", "Sculpture") are expanded automatically to
"Mural by <artist>" or "Mural near <nearest well-known sight>" (within 250 m).

## Score floors and map tiers (ADR 012)

**Floors.** After curation (boosts count) and de-duplication, `score.py` drops places below their
category's floor, `SCORE_FLOOR`: photo < 30, shop < 30, food < 35. A curation `popular yes` keeps a
place under the floor. Vilnius: photo 383 → 268, shop 82 → 33, food 742 → 235.

**Tiers.** Every place gets a `tier` within its category (the map shows tier 1 when zoomed out):

- **1, must-see**: the top `TIER1_SHARE` (4%) by score, at least one (round half up; ties by id),
  plus sights whose fame signal is at least `TIER1_FAME` (0.8). Sights are capped at
  `TIER1_PHOTO_CAP` (25), keeping the highest scores.
- **2, notable**: the next `TIER2_SHARE` (15% of the category, by count).
- **3, detail**: the rest.

A `popular` curation rule overrides tier 1: `yes` forces it, `no` turns it off (tier 2).
`"popular": true` is written exactly when `tier` is 1, for compatibility.
`score.py` prints the counts before and after the floors and the tiers per category.

## Descriptions (BE-10)

`score.py` gives places a 1–2 sentence `description` for the place card (CONTRACTS §1), from two
sources only, never invented or paraphrased:

- **Wikipedia** (`descriptionSource: wikipedia`, with `descriptionUrl`): any place whose OSM
  `wikipedia` tag is `en:<title>`, or whose Wikidata item has an English article (`enwiki`).
  `wikipedia.py` fetches the REST summary; `describe.py` keeps the first one or two whole sentences
  of its `extract`, at most 300 characters. No English article means no Wikipedia text (no other
  languages, no machine translation). Skipped when one article is linked from several places (a
  museum and its branches) or when curation emptied the place's image (its Wikidata item is a
  different place).
- **OSM** (`descriptionSource: osm`, popular places only): composed from tags that are present:
  cuisine, outdoor seating, vegetarian/vegan options, takeaway, second-hand/organic (shops),
  start date, architect, heritage, artist. Simple opening hours are appended in plain English
  (complex ones are left out), but hours alone are never a description. Nothing is written when
  the tags add nothing to the `reason`.

`score.py` prints how many popular places per category have a description.

## Curation (`curation.csv`)

One row per rule; ids look like `osm:node:123` (copy them from the review CSV).

| action  | value                     | effect                              |
|---------|---------------------------|-------------------------------------|
| exclude |                           | drop the place                      |
| boost   | points (default 20)       | add to its score (max 100)          |
| rename  | new name                  | replace the display name            |
| reason  | short text                | replace the auto-drafted reason     |
| image   | Commons file name, or empty | replace or remove the sight's photo |
| popular | yes (default) or no       | force tier 1 (popular) on/off, any category; `yes` also passes the score floor |

`cache/` is not committed. `review/` and the app's `pois-*.json` are.

`sources/` is committed (the Overture extract).

Data © OpenStreetMap contributors (ODbL), Wikidata (CC0), Wikimedia Commons metadata, and
Overture Maps Foundation, CDLA-Permissive-2.0 (places; some source datasets carry their own terms,
e.g. Foursquare Apache-2.0, listed per place in the extract's `datasets`).
