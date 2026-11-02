# POI data pipeline

Python 3, standard library only. Cities and their bounding boxes live in `cities.json`.

```sh
python3 fetch_osm.py lodz   # OSM via Overpass → cache/lodz/osm.json (raw response cached; --refresh to re-download)
python3 enrich.py lodz      # Wikidata sitelinks + Commons photo counts (cached, ~10 min first run)
python3 score.py lodz       # scores + curation → App/Wander/Resources/pois-lodz.json, review/lodz-review.csv
```

Only `score.py` needs re-running after editing weights or `curation.csv`.

## Curation (`curation.csv`)

One row per rule; ids look like `osm:node:123` (copy them from the review CSV).

| action  | value                     | effect                              |
|---------|---------------------------|-------------------------------------|
| exclude |                           | drop the place                      |
| boost   | points (default 20)       | add to its score (max 100)          |
| rename  | new name                  | replace the display name            |
| reason  | short text                | replace the auto-drafted reason     |

`cache/` is not committed. `review/` and the app's `pois-*.json` are.

Data © OpenStreetMap contributors (ODbL), Wikidata (CC0), Wikimedia Commons metadata.
