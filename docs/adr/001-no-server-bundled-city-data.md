# ADR 001: No server; bundled per-city data files

**Status:** accepted (2026-10-17, PLAN §2). **Date recorded:** 2026-11-02.

**Context.** Building a city's places takes minutes and ~100 requests to free, rate-limited services
(Overpass, Wikidata, Commons). Scores are only meaningful city-wide (percentiles), and English names and
curation are done once per city.

**Decision.** Run the pipeline offline on the Mac and bundle one `pois-<city>.json` per city in the app.
No server, accounts or runtime data fetching, except Apple MapKit and read-only Commons photos.

**Consequences.** + Nothing to host, works offline for places. − A new city needs a pipeline run and an
app build. **Later:** a scheduled job publishes static per-area files to a CDN, and the app downloads
the file for wherever it is. MapKit's nearby points of interest are the fallback for uncovered areas.
The file format stays the same.
