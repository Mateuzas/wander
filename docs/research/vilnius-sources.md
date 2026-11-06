# Vilnius sources for niche places and events (ARC-7, 2026-11-06)

Research by a sub-agent; robots.txt files fetched with a descriptive UA. Overture queried for release 2026-10-21.0
(Vilnius bbox 25.02–25.48 E, 54.57–54.83 N). [V] = verified in the session, [?] = unverified.

## Shortlist

| Source | Covers | How | Rights | Fit |
|---|---|---|---|---|
| **vilnius-events.lt** (official city calendar; Go Vilnius `/events` redirects here) | Events (all kinds; ~467 new in 30 days) | WP REST `/wp-json/wp/v2/event`, plus JSON embedded in the listing with lat/lng, time, price, category | robots allows, Crawl-delay 120; no ToS found [?]. Ask Go Vilnius for OK or a feed | 5 |
| **Overture Maps Places** | Places (25,220 in bbox; 10,998 with confidence > 0.7; ~23k from Meta pages, so new and small places) | GeoParquet on S3, monthly; needs a `taxonomy`/`basic_category` filter | Open (CDLA-Permissive-2.0 / per source) | 5 |
| **bilietai.lt** | Ticketed events (Lithuania-wide; filter Vilnius) | Nightly sitemaps plus schema.org `Event` JSON-LD | robots allows (blocks /search); ToS silent on scraping | 4 |
| **Foursquare OS Places** | Places; closed dates | Parquet on Hugging Face (gated, auto-approve) | Apache-2.0 | 4 |
| kakava.lt | Ticketed events | Daily sitemap; SPA JSON API | robots allows event pages; ToS [?] | 3 |
| Go Vilnius places | ~148 curated places | Sitemap; lat/lng in pages | robots allows all; llms.txt | 3 (an "official pick" badge) |
| Vilnius GIS (opendata.vilnius.lt) | Trails, benches, toilets, beaches, culture institutions | ArcGIS REST / GeoJSON | Open data (licence per layer [?]) | 3 (walking extras) |
| artnews.lt | Exhibitions | RSS | Copyrighted text: title, link and date only | 3 |
| Falstaff Nordics, tv3.lt tags, Delfi | "New / closed place" signals | RSS, HTML | Reference only: names and links into a manual queue, never republished | 2 |

## Excluded
- tiketa.lt: robots `Disallow: /`.
- 15min: robots bans text and data mining and commercial use.
- LRT: disallows almost everything.
- Resident Advisor: ToS bans commercial extraction.
- Songkick: paid only.
- Eventbrite: no city search.
- Facebook / Instagram: closed.
- Google / Tripadvisor: storage banned.
- In Your Pocket: content signal limits use to reference.
- kasvyksta.lt: Kaunas and Neringa only.
- data.gov.lt: WAF 403 [?].

## Recommended plan
- **Places (BE-7):** Overture (confidence ≥ 0.7; food, drink, art, venue and shop categories), deduplicated against OSM by name and distance, monthly refresh in the nightly job. Later, a Foursquare cross-check for closed places, and a Go Vilnius "official pick" badge.
- **Events (BE-8):** vilnius-events.lt first, ideally with written OK or a feed from Go Vilnius. Then bilietai.lt (Event JSON-LD, dedup by venue + date + title). Later, kakava.lt and artnews.lt.

## Open questions (user)
1. Commercial or not?
2. Email Go Vilnius and bilietai.lt for permission or a feed?
3. Show only events with coordinates, or geocode venues?
4. Trusted curated lists as manual input?
5. Hugging Face account for Foursquare?
6. Which "Kas vyksta Vilniuje" was meant?
