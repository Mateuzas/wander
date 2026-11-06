"""Unattended nightly pipeline for one city (ADR 013).

    python3 Data/run_nightly.py vilnius --out build/data [--refresh] [--previous FILE|URL|none]
                                [--export-facts FILE.jsonl]

Runs fetch_osm (--refresh passed through), enrich, wikipedia, photos (ADR 015: Commons, Mapillary
when MAPILLARY_TOKEN is set, website preview images; also fetches homepage metadata) and score,
writing
<out>/pois-<city>.json, never App/Wander/Resources. Score runs twice in separate processes and
the two files must be byte-identical (determinism, ADR 013). The file must pass
scripts/validate-pois.py.

Also writes <out>/review-<city>.md, the "needs review" summary: sights without a reviewed English
name (names-en/<city>.csv) and the fallback used, tier-1 places new or gone since the previous file
(default: the bundled App/Wander/Resources/pois-<city>.json), counts per category and tier, and
description coverage. A missing English name (no names-en row, no OSM name:en) never fails the run: the sight shows its
Wikidata English label, else its local name, and is listed.

Hooks (ADR 015) are never written here: score.py reads the committed Data/hooks/<city>.jsonl. With
--export-facts it also writes the fact bundles of places that need a hook (hooks.py export), for
the next writing session (Data/hooks/WRITING.md).

Exits non-zero only on real errors: a step failing (e.g. network down after the retries), or an
output that is invalid or not deterministic.
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from common import DATA, RESOURCES, cache_dir, load_city
from publish_gate import load_previous, validate
from score import load_curation, load_english_names

CATEGORIES = ("photo", "shop", "food")


def step(*args):
    cmd = [sys.executable, str(DATA / args[0]), *args[1:]]
    print(f"\n== {' '.join(['python3', *args])}", flush=True)
    result = subprocess.run(cmd, cwd=DATA)
    if result.returncode != 0:
        raise SystemExit(f"run_nightly: {args[0]} failed (exit {result.returncode})")


def name_fallbacks(slug, pois):
    """Sights with neither a reviewed English name (names-en/<city>.csv) nor an OSM `name:en`,
    as (id, shown name, local name, fallback used): the Wikidata English label, else the local name."""
    names_en = load_english_names(slug)
    renamed = {i for i, rules in load_curation().items() if any(a == "rename" for a, _ in rules)}
    enriched = {p["id"]: p for p in json.loads((cache_dir(slug) / "enriched.json").read_text())["pois"]}
    rows = []
    for p in pois:
        if p["category"] != "photo" or p["id"] in names_en or p["id"] in renamed:
            continue
        if p["id"].startswith("ovt:"):
            continue  # Overture-only galleries and venues keep their own (proper) names
        src = enriched.get(p["id"], {})
        if src.get("tags", {}).get("name:en"):
            continue  # tagged in OSM by a mapper; score.py treats it as English too
        if src.get("wikidata_label_en"):
            used = "Wikidata English label"
        else:
            used = "local name"
        rows.append((p["id"], p["name"], src.get("name", p.get("localName", p["name"])), used))
    return rows


def md_cell(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def review_markdown(slug, doc, previous, previous_label, fallbacks):
    pois = doc["pois"]
    lines = [f"# Needs review: {doc['city']} ({doc['generated']})", "",
             f"{len(pois)} places. Previous file: {previous_label}.", "",
             "## Counts per category and tier", "",
             "| Category | Total | Tier 1 | Tier 2 | Tier 3 | Previous | With description | Tier 1 with description |",
             "|---|---|---|---|---|---|---|---|"]
    for cat in CATEGORIES:
        rows = [p for p in pois if p["category"] == cat]
        t = [sum(p.get("tier") == n for p in rows) for n in (1, 2, 3)]
        prev = sum(p["category"] == cat for p in previous["pois"]) if previous else "–"
        desc = sum("description" in p for p in rows)
        t1_desc = sum("description" in p for p in rows if p.get("tier") == 1)
        lines.append(f"| {cat} | {len(rows)} | {t[0]} | {t[1]} | {t[2]} | {prev} | {desc} | {t1_desc}/{t[0]} |")
    sources = {}
    for p in pois:
        if "descriptionSource" in p:
            sources[p["descriptionSource"]] = sources.get(p["descriptionSource"], 0) + 1
    total_desc = sum(sources.values())
    lines += ["", f"Descriptions: {total_desc}/{len(pois)} places "
                  f"({', '.join(f'{k} {v}' for k, v in sorted(sources.items())) or 'none'})."]

    lines += ["", "## Tier-1 changes", ""]
    if previous is None:
        lines.append("No previous file to compare with.")
    else:
        old = {p["id"]: p for p in previous["pois"] if p.get("tier") == 1}
        new = {p["id"]: p for p in pois if p.get("tier") == 1}
        added = [new[i] for i in sorted(new.keys() - old.keys())]
        gone = [old[i] for i in sorted(old.keys() - new.keys())]
        if not added and not gone:
            lines.append("None.")
        now = {p["id"]: p for p in pois}
        for p in added:
            lines.append(f"- new: {md_cell(p['name'])} (`{p['id']}`, {p['category']}, score {p['score']})")
        for p in gone:
            cur = now.get(p["id"])
            state = f"now tier {cur.get('tier')}, score {cur['score']}" if cur else "no longer in the file"
            lines.append(f"- removed: {md_cell(p['name'])} (`{p['id']}`, {p['category']}, {state})")

    lines += ["", f"## Sights without an English name ({len(fallbacks)})", ""]
    if fallbacks:
        lines += [f"Add a row to `Data/names-en/{slug}.csv` (`osm_id,name_en,original`) to fix a name.", "",
                  "| id | Shown as | Local name | Fallback |", "|---|---|---|---|"]
        lines += [f"| `{i}` | {md_cell(n)} | {md_cell(o)} | {u} |" for i, n, o, u in fallbacks]
    else:
        lines.append("None.")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Run the POI pipeline for one city, unattended (ADR 013).")
    parser.add_argument("city")
    parser.add_argument("--out", required=True, type=Path, help="directory for pois-<city>.json and review-<city>.md")
    parser.add_argument("--refresh", action="store_true", help="re-download OSM (passed to fetch_osm.py)")
    parser.add_argument("--previous", default=None,
                        help="file or URL for the tier-1 comparison in the review, or 'none' "
                             "(default: the bundled App/Wander/Resources/pois-<city>.json)")
    parser.add_argument("--export-facts", type=Path, metavar="FILE",
                        help="also write the fact bundles of places needing a hook (JSON lines, ADR 015)")
    args = parser.parse_args()
    slug = args.city
    load_city(slug)  # exits on an unknown city
    out_dir = args.out.resolve()
    if out_dir == RESOURCES.resolve():
        sys.exit("run_nightly: --out must not be App/Wander/Resources (use score.py for the bundled file)")
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"pois-{slug}.json"

    step("fetch_osm.py", slug, *(["--refresh"] if args.refresh else []))
    step("enrich.py", slug)
    step("wikipedia.py", slug)
    step("photos.py", slug)
    if args.export_facts:
        step("hooks.py", "export", slug, "--offline", "--out", str(args.export_facts.resolve()))
    step("score.py", slug, "--out", str(out))
    with tempfile.TemporaryDirectory() as tmp:
        again = Path(tmp) / out.name
        print("\n== score.py again (determinism check)", flush=True)
        result = subprocess.run([sys.executable, str(DATA / "score.py"), slug, "--out", str(again)],
                                cwd=DATA, stdout=subprocess.DEVNULL)
        if result.returncode != 0:
            sys.exit("run_nightly: score.py failed on the determinism re-run")
        if again.read_bytes() != out.read_bytes():
            sys.exit("run_nightly: score.py is not deterministic: two runs on the same caches differ")

    errors = validate(out)
    if errors:
        for path, msg in errors[:20]:
            print(f"  {out.name}: {path}: {msg}", file=sys.stderr)
        sys.exit(f"run_nightly: {out} does not validate against the schema ({len(errors)} problem(s))")

    doc = json.loads(out.read_text(encoding="utf-8"))
    prev_src = args.previous or str(RESOURCES / f"pois-{slug}.json")
    try:
        previous, prev_note = load_previous(prev_src)
    except Exception as exc:  # the review is advisory: never fail the run over it
        previous, prev_note = None, f"could not load {prev_src}: {exc}"
    fallbacks = name_fallbacks(slug, doc["pois"])
    review = out_dir / f"review-{slug}.md"
    review.write_text(review_markdown(slug, doc, previous, prev_note, fallbacks), encoding="utf-8")

    counts = {c: sum(p["category"] == c for p in doc["pois"]) for c in CATEGORIES}
    tier1 = sum(p.get("tier") == 1 for p in doc["pois"])
    print(f"\nrun_nightly {slug}: ok, {len(doc['pois'])} POIs {counts}, {tier1} tier 1, deterministic, valid; "
          f"{len(fallbacks)} sights without an English name")
    print(f"  wrote {out}")
    print(f"  wrote {review}")


if __name__ == "__main__":
    main()
