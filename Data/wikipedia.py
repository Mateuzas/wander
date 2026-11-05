"""Step 2b: fetch English Wikipedia summaries for places with a Wikipedia link (BE-10).

    python3 wikipedia.py vilnius

A place's English article comes from its OSM `wikipedia` tag when that is `en:<title>`, else from
the `enwiki` sitelink of its Wikidata item. Places without an English article get no Wikipedia text
(no other languages, no machine translation). score.py trims the summary to 1-2 sentences.

Reads cache/<city>/osm.json, writes cache/<city>/wikipedia_cache.json:
    {"enwiki": {qid: title | null}, "summaries": {title: {"extract", "url", "type"} | null}}
Re-runs only fetch what is missing. One request at a time, with a pause between them.
"""
import json
import sys
import time
import urllib.error
import urllib.parse

from common import cache_dir, http_json

WIKIDATA = "https://www.wikidata.org/w/api.php"
SUMMARY = "https://en.wikipedia.org/api/rest_v1/page/summary/"
PAUSE_S = 3.0  # the REST API rate-limits anonymous scripts (429 with Retry-After)


def load(path):
    data = json.loads(path.read_text()) if path.exists() else {}
    data.setdefault("enwiki", {})
    data.setdefault("summaries", {})
    return data


def english_title(tags, enwiki):
    """English article title for an OSM object, or None."""
    tag = tags.get("wikipedia", "")
    if tag.startswith("en:") and tag[3:].strip():
        return tag[3:].strip()
    return enwiki.get(tags.get("wikidata", ""))


def fetch_sitelinks(qids, cache, path):
    missing = sorted(q for q in qids if q not in cache["enwiki"])
    for i in range(0, len(missing), 50):
        batch = missing[i:i + 50]
        res = http_json(WIKIDATA, params={
            "action": "wbgetentities", "ids": "|".join(batch), "props": "sitelinks",
            "sitefilter": "enwiki", "format": "json",
        })
        for qid in batch:
            link = res.get("entities", {}).get(qid, {}).get("sitelinks", {}).get("enwiki")
            cache["enwiki"][qid] = link["title"] if link else None
        path.write_text(json.dumps(cache, ensure_ascii=False, indent=1))
        print(f"  wikidata sitelinks {min(i + 50, len(missing))}/{len(missing)}")
        time.sleep(PAUSE_S)


def fetch_summary(title):
    url = SUMMARY + urllib.parse.quote(title.replace(" ", "_"), safe="")
    try:
        res = http_json(url, retries=8, timeout=30)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise
    return {
        "extract": res.get("extract", ""),
        "url": res.get("content_urls", {}).get("desktop", {}).get("page")
        or "https://en.wikipedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_")),
        "type": res.get("type", ""),
    }


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: python3 wikipedia.py <city>")
    d = cache_dir(sys.argv[1])
    pois = json.loads((d / "osm.json").read_text())["pois"]
    path = d / "wikipedia_cache.json"
    cache = load(path)

    qids = {p["tags"]["wikidata"] for p in pois if p["tags"].get("wikidata", "").startswith("Q")}
    print(f"Wikidata: {len(qids)} ids, looking up English articles")
    fetch_sitelinks(qids, cache, path)

    titles = sorted({t for p in pois if (t := english_title(p["tags"], cache["enwiki"]))})
    missing = [t for t in titles if t not in cache["summaries"]]
    print(f"Wikipedia: {len(titles)} English articles, {len(missing)} to fetch")
    for i, title in enumerate(missing, 1):
        cache["summaries"][title] = fetch_summary(title)
        path.write_text(json.dumps(cache, ensure_ascii=False, indent=1))
        if i % 20 == 0 or i == len(missing):
            print(f"  summaries {i}/{len(missing)}", flush=True)
        time.sleep(PAUSE_S)
    print(f"Wrote {path.name}")


if __name__ == "__main__":
    main()
