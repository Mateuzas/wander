# POI data pipeline

Python 3, standard library only (except the monthly Overture extract, which needs `duckdb`, and the
optional hook API writer, which needs `anthropic`).
Cities and their bounding boxes live in `cities.json`.

```sh
python3 fetch_osm.py vilnius   # OSM via Overpass → cache/vilnius/osm.json (raw response cached; --refresh to re-download)
python3 enrich.py vilnius      # Wikidata sitelinks + Commons photo counts (cached, ~10 min first run)
python3 wikipedia.py vilnius   # English Wikipedia summaries for place descriptions (cached, ~10 min first run)
python3 photos.py vilnius      # a photo per place: Commons, Mapillary, website preview (cached; ADR 015)
python3 hooks.py export vilnius --out /tmp/facts.jsonl   # fact bundles for the hook writer (Data/hooks/WRITING.md)
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

**`run_nightly.py`** runs fetch_osm (`--refresh` passed through), enrich, wikipedia, photos and score for
the city (with `--export-facts <file.jsonl>` also `hooks.py export`, see below) and writes `<out>/pois-<city>.json`, never `App/Wander/Resources`. It runs score twice in
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

`--allow-shrink` lets per-category counts fall by any amount and lets tier-1 places go (listed, not
failed); it prints a warning on stderr and a WARNING callout in the summary. Use it once, for the
first publish with the hook+photo gate (ADR 015), then drop it.

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

## Hook and photo for every place (ADR 015, BE-14, BE-15)

A place is published only with **both** a `hook` (one factual sentence, at most 80 characters) and
a `photo` (`{url, source, credit, license?, page?}`). `score.py` drops the rest after curation,
de-duplication and the floors, before tiers; a curation `popular yes` does not bypass this.
`score.py` prints what the gate kept and dropped per category, and why (no hook, no photo, stale).

`score.candidates(city)` is the list both steps work on (the places that would be published if
they had both), so photos and hooks are never fetched or written for places below the floors.

### Photos (`photos.py`, standard library)

Per place, in priority order (ADR 015):

1. **Commons**: the place's own image (OSM `wikimedia_commons`/`image`, Wikidata P18, or a curation
   `image` row), then a file from its Commons category (no maps, plans, scans, logos; landscape
   first, then largest). Any category, not only sights. A file used by 3+ places is skipped
   (a series image). The URL is a Commons thumbnail 1280 px wide from an original at least 800 px
   wide; credit (author) and licence come from the Commons API `extmetadata`.
2. **Mapillary** (only when `MAPILLARY_TOKEN` is set; otherwise skipped with a `!!!` line): the
   image in the OSM `mapillary` tag if a mapper set one, else the closest non-panorama image within
   40 m whose camera faces the place (compass within ±50° of the bearing from the camera to the
   place), via the API v4 `images` bbox search (`thumb_1024_url`, `compass_angle`, `captured_at`,
   `creator`). Licence CC BY-SA 4.0, credit "<username> / Mapillary", page
   `https://www.mapillary.com/app/?pKey=<id>`.
3. **Website preview** (`og:image`, `twitter:image`) from the place's own homepage (`website.py`),
   only where robots.txt allows our user agent; profiles on other platforms (Facebook, Treatwell,
   Tripadvisor...) are not "own" sites. A range GET of the first 64 KB reads the image size. Never
   an svg, a likely logo (square-ish under 400 px, or `logo`/`icon`/`favicon` in the path) or an
   image narrower than 300 px. Credit is the site's domain, page the homepage.

"Better" between 2 and 3: food, shops and venues (theatres, galleries, stadiums...) take a website
image at least 800 px wide over Mapillary; sights take Mapillary over the website image.

**Mapillary URLs expire.** `thumb_1024_url` is a signed CDN URL whose `oe` query parameter is a
hex expiry time (typically days to weeks). `photos.py` stores the expiry, refreshes the URL by
image id when it is within 7 days of expiring (nightly), and drops a Mapillary photo whose URL has
expired and could not be refreshed. The published `photo.page` carries the stable form
(`pKey=<image id>`): when the app gets a 403/404 for a Mapillary `url`, it should re-resolve it with
`GET https://graph.mapillary.com/<id>?fields=thumb_1024_url` (client token), or fall back to the
placeholder. The bundled file ages, so this matters for the app's bundled data, not the nightly one.

Cache: `cache/<city>/photos.json` (per place id: the inputs key, the date checked, the chosen
photo and which sources had one; plus the per-source lookups) and `cache/<city>/websites.json`
(homepage title, description and preview images, per URL). Everything is re-checked after 30 days
(`--max-age-days`). `score.py` reads only the cache and uses a photo only while the place's inputs
(Commons file/category, website, position, `mapillary` tag, category, type) are unchanged, so it
stays deterministic and offline. Network cost: one Commons API call per 50 files plus one per
category, one homepage (and robots.txt) per website, a 64 KB range GET per preview image, one
Mapillary call per place without a Commons photo. First Vilnius run: a few minutes.

### Hooks (`hooks.py`, `Data/hooks/<city>.jsonl`)

Hooks are written in a **Claude Code session on the user's subscription** (or a scheduled weekly
routine), reviewed and committed. The nightly job never calls an API.

- `hooks.py export <city> --out facts.jsonl` writes one fact bundle per place without a current
  hook: `{id, name, facts_hash, facts}`. The facts are only data we hold: name, local name, kind,
  type, cuisine, selected OSM tags (artist, architect, start date, heritage, inscription, outdoor
  seating, diet options...), the Wikidata English label, the English Wikipedia extract (up to 900
  characters, whole sentences), the Overture category, and the homepage `<title>` and
  `<meta name=description>` (fetched only where robots.txt allows; cached, see above).
  `facts_hash` is the first 16 hex characters of sha256 of the facts as sorted JSON.
  `run_nightly.py --export-facts <file>` does the same from the nightly caches.
- The writer follows `Data/hooks/WRITING.md` (rules, prompt, input and output format) and merges
  the answers with `hooks.py merge <city> answers.jsonl --written-by "..."`, which rejects lines
  that break the rules or whose facts changed since the export.
- `Data/hooks/<city>.jsonl` (committed, sorted by id) holds one line per place:
  `{id, name, facts_hash, hook|null, prompt_version, written_by, date}`. `null` means "nothing
  intriguing and true to say" and keeps the place off the map. `hooks.py validate <file>` checks
  the format, 10–80 characters, one sentence ending in a full stop, no `!`/`?`, no emoji, no banned
  hype words, not starting with the place's own name.
- `score.py` uses a hook only when its `facts_hash` equals the place's current facts hash: when a
  place's facts change (a new Wikipedia extract, a new homepage title), its hook is stale and the
  place drops out until the next writing session. `score.py` prints the stale count.
- A curation `hook` row (below) wins over the file and is checked by the same rules.

**Optional API writer** (off by default, never in CI): `pip install -r Data/requirements-hooks.txt`
(official `anthropic` SDK, pinned) and `ANTHROPIC_API_KEY`, then
`python3 Data/hooks.py write vilnius --api [--effort low] [--limit N]`. It sends the WRITING.md
prompt as the system prompt and the facts as the user message to `claude-opus-5-5` (`MODEL`, one
constant) with structured output (`output_config.format`, schema `{hook: string|null}`), checks
`stop_reason` (refusal is stored as null, `max_tokens` is retried next time), validates, and
merges like `merge`. 50 or more places go through the Batch API (half price). `--compare-effort 20`
prints `low` and `medium` answers side by side and writes nothing. Cost: a bundle is about
300–600 input tokens plus thinking and ~30 output tokens; about 1,000 places cost roughly $1–2 at
Opus 5.5 prices ($4/$20 per MTok), half that with Batch; later runs only pay for changed places.

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
| image   | Commons file name, or empty | replace or remove the sight's photo (also the card `photo`, after `photos.py`) |
| popular | yes (default) or no       | force tier 1 (popular) on/off, any category; `yes` also passes the score floor (not the hook+photo gate) |
| hook    | one sentence, ≤ 80 chars  | hand-written hook line (ADR 015); beats `Data/hooks/<city>.jsonl` |

`cache/` is not committed. `review/`, `hooks/` and the app's `pois-*.json` are.

Tests for the hook and photo steps and the gate: `python3 Data/tests/test_hooks_photos.py`.

`sources/` is committed (the Overture extract).

Data © OpenStreetMap contributors (ODbL), Wikidata (CC0), Wikimedia Commons metadata, and
Overture Maps Foundation, CDLA-Permissive-2.0 (places; some source datasets carry their own terms,
e.g. Foursquare Apache-2.0, listed per place in the extract's `datasets`).
