# POI data pipeline

Python 3, standard library only. Cities and their bounding boxes live in `cities.json`.

```sh
python3 fetch_osm.py vilnius   # OSM via Overpass → cache/vilnius/osm.json (raw response cached; --refresh to re-download)
python3 enrich.py vilnius      # Wikidata sitelinks + Commons photo counts (cached, ~10 min first run)
python3 score.py vilnius       # scores + curation → App/Wander/Resources/pois-vilnius.json, review/vilnius-review.csv
```

Only `score.py` needs re-running after editing weights or `curation.csv`.

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

## English names (`names-en/<city>.csv`)

Sights are shown in English. OSM rarely has `name:en` and Wikidata labels are unreliable,
so each city has a reviewed `osm_id,name_en,original` file (first drafted by Claude: please check).
Shops and food keep their own names. Without a reviewed entry, a sight falls back to OSM `name:en`,
then the Wikidata English label, then its own name; `score.py` lists any sight still missing one.

Sights named only by their kind ("Mural", "Sculpture") are expanded automatically to
"Mural by <artist>" or "Mural near <nearest well-known sight>" (within 250 m).

## Popular places

`score.py` marks the best places in every category with `"popular": true` (a map marker):
the top `POPULAR_SHARE` (5%) of each category's places in the app file, by score
(at least one per non-empty category; ties by id), plus sights whose fame signal is at least
`POPULAR_FAME` (0.6). A `popular` curation rule overrides both.

## Curation (`curation.csv`)

One row per rule; ids look like `osm:node:123` (copy them from the review CSV).

| action  | value                     | effect                              |
|---------|---------------------------|-------------------------------------|
| exclude |                           | drop the place                      |
| boost   | points (default 20)       | add to its score (max 100)          |
| rename  | new name                  | replace the display name            |
| reason  | short text                | replace the auto-drafted reason     |
| image   | Commons file name, or empty | replace or remove the sight's photo |
| popular | yes (default) or no       | force the "popular" marker on/off (any category) |

`cache/` is not committed. `review/` and the app's `pois-*.json` are.

Data © OpenStreetMap contributors (ODbL), Wikidata (CC0), Wikimedia Commons metadata.
