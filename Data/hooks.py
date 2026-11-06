"""Step 4b: a short hook line for every place (ADR 015, BE-15).

Hooks are written by a Claude Code session (the user's subscription) from fact bundles, reviewed,
and committed as Data/hooks/<city>.jsonl, the source of truth. The nightly job never calls an API.
The writing rules and the prompt live in Data/hooks/WRITING.md (read by this script, one source).

    python3 Data/hooks.py export vilnius --out /tmp/facts-vilnius.jsonl [--offline] [--all]
    python3 Data/hooks.py merge vilnius answers.jsonl --written-by "claude-code (claude-opus-5-5)"
    python3 Data/hooks.py validate Data/hooks/vilnius.jsonl
    python3 Data/hooks.py write vilnius --api [--limit N] [--effort low|medium] [--compare-effort 20]

export   one JSON line per candidate place with no committed hook for its current facts:
         {id, name, facts_hash, facts}. --all exports every candidate. Fetches missing or old
         homepage metadata first (website.py, robots.txt respected) unless --offline.
merge    adds a writer's answers ({id, facts_hash, hook|null} per line) to the hooks file,
         after checking each against the rules and the current facts; rejected lines are listed
         and not merged.
validate checks a hooks file: format, length, one sentence, banned words.
write    OPTIONAL, off by default, never used in CI: writes hooks with the Anthropic API
         (official `anthropic` SDK, Data/requirements-hooks.txt) when ANTHROPIC_API_KEY is set.

score.py uses a committed hook only when its facts_hash equals the place's current facts hash;
a stale hook counts as none (the place is dropped until rewritten). A curation `hook` row wins.
Standard library only, except `write --api`.
"""
import argparse
import datetime
import hashlib
import json
import re
import sys
import time
import unicodedata
from pathlib import Path

import website
from common import DATA
from describe import sentences

HOOKS_DIR = DATA / "hooks"
WRITING = HOOKS_DIR / "WRITING.md"
MODEL = "claude-opus-5-5"   # the optional API writer's model: change it here only
DEFAULT_EFFORT = "low"
BATCH_MIN = 50              # the API writer uses the Batch API (half price) from this many places
MAX_LEN, MIN_LEN = 80, 10
WIKI_FACT_CHARS = 900
BANNED = re.compile(r"\b(amazing|must[- ]visit|must[- ]see|hidden gems?|best|stunning|breathtaking|unmissable|"
                    r"world[- ]class|iconic|perfect|ultimate|incredible|awesome)\b", re.I)
OSM_FACT_TAGS = (
    "artist_name", "artist", "architect", "start_date", "heritage", "historic", "memorial", "artwork_type",
    "material", "inscription", "description", "subject", "denomination", "religion", "castle_type",
    "outdoor_seating", "diet:vegetarian", "diet:vegan", "takeaway", "second_hand", "organic",
    "microbrewery", "brewery", "height", "building:architecture", "old_name", "alt_name",
)
CATEGORY_WORD = {"photo": "sight", "shop": "shop", "food": "food and drink"}
REASON_EXTRAS = re.compile(r", (well-known landmark|popular photo spot)")


# ---- The prompt (from WRITING.md) -------------------------------------------------------------

def writing_doc():
    return WRITING.read_text(encoding="utf-8")


def prompt_version():
    m = re.search(r"PROMPT_VERSION:\s*`?([\w.-]+)`?", writing_doc())
    if not m:
        raise SystemExit(f"hooks: no PROMPT_VERSION in {WRITING}")
    return m.group(1)


def system_prompt():
    """The rules between the prompt markers in WRITING.md, verbatim."""
    m = re.search(r"<!-- prompt:start -->\s*```text\n(.*?)```\s*<!-- prompt:end -->", writing_doc(), re.S)
    if not m:
        raise SystemExit(f"hooks: no prompt block in {WRITING}")
    return m.group(1).strip()


# ---- Facts ----------------------------------------------------------------------------------

def wiki_fact(summary):
    """The Wikipedia extract, cut at a sentence end to at most WIKI_FACT_CHARS."""
    text = " ".join(((summary or {}).get("extract") or "").split())
    if not text:
        return None
    out = ""
    for s in sentences(text):
        if len(out) + len(s) + 1 > WIKI_FACT_CHARS:
            break
        out = f"{out} {s}".strip()
    return out or text[:WIKI_FACT_CHARS]


def facts(p, city_name, sites):
    """The facts bundle a writer sees for a place: only data we hold, nothing derived from scores.

    `p` is a place from score.candidates(); `sites` is website.load_cache(). Keys with no value
    are left out, so adding a source later changes only the places it has data for."""
    t = p["tags"]
    f = {"name": p["name"], "city": city_name, "category": CATEGORY_WORD[p["category"]],
         "kind": REASON_EXTRAS.sub("", p.get("reason") or "") or None, "type": p.get("type")}
    if p.get("original_name") and p["original_name"] != p["name"]:
        f["local_name"] = p["original_name"]
    if p["category"] == "food" and t.get("cuisine"):
        f["cuisine"] = [c.strip().replace("_", " ") for c in t["cuisine"].split(";") if c.strip()]
    osm = {k: t[k] for k in OSM_FACT_TAGS if t.get(k) and t.get(k) != p["name"]}
    if osm:
        f["osm"] = osm
    if p.get("wikidata_label_en") and p["wikidata_label_en"] != p["name"]:
        f["wikidata_label"] = p["wikidata_label_en"]
    if w := wiki_fact(p.get("wiki_summary")):
        f["wikipedia"] = w
    if p.get("ovt_category"):
        f["overture_category"] = p["ovt_category"].replace("_", " ")
    title, desc = website.page_facts(sites.get(p.get("site_url") or ""), p.get("site_url"),
                                     (p["name"], p.get("original_name")))
    if title:
        f["website_title"] = title
    if desc:
        f["website_description"] = desc
    return {k: v for k, v in f.items() if v}


def facts_hash(f):
    return hashlib.sha256(json.dumps(f, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:16]


# ---- Validation -----------------------------------------------------------------------------

def problem(hook, name=None):
    """Why a hook breaks the rules (WRITING.md), or None when it is fine."""
    if not isinstance(hook, str):
        return "not a string"
    if hook != hook.strip() or "\n" in hook or "  " in hook:
        return "stray whitespace or line break"
    if not MIN_LEN <= len(hook) <= MAX_LEN:
        return f"{len(hook)} characters (allowed {MIN_LEN}-{MAX_LEN})"
    if not (hook[0].isupper() or hook[0].isdigit()):
        return "does not start with a capital letter or digit"
    if not hook.endswith(".") or hook.endswith(".."):
        return "must end with a single full stop"
    if "!" in hook or "?" in hook:
        return "no exclamation or question marks"
    if len(sentences(hook)) != 1:
        return "more than one sentence"
    if any(unicodedata.category(c) in ("So", "Cs", "Co") for c in hook):
        return "emoji or symbol"
    if m := BANNED.search(hook):
        return f"banned word '{m.group(0)}'"
    if name and len(name) >= 4 and hook.casefold().startswith(name.casefold()):
        return "starts with the place's own name (the card already shows it)"
    return None


def read_jsonl(path):
    rows = []
    for n, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if line.strip():
            try:
                rows.append((n, json.loads(line)))
            except json.JSONDecodeError as exc:
                rows.append((n, exc))
    return rows


HOOK_KEYS = {"id", "facts_hash", "hook", "prompt_version", "written_by", "date"}


def validate_rows(rows):
    """[(line, message)] for a hooks file's rows."""
    errors, seen = [], set()
    for n, row in rows:
        if isinstance(row, Exception):
            errors.append((n, f"not JSON: {row}"))
            continue
        missing = HOOK_KEYS - row.keys()
        extra = row.keys() - HOOK_KEYS - {"name"}
        if missing or extra:
            errors.append((n, f"keys: missing {sorted(missing)}, unexpected {sorted(extra)}"))
            continue
        if row["id"] in seen:
            errors.append((n, f"duplicate id {row['id']}"))
        seen.add(row["id"])
        if not re.fullmatch(r"[0-9a-f]{16}", str(row["facts_hash"])):
            errors.append((n, "facts_hash must be 16 lowercase hex characters"))
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(row["date"])):
            errors.append((n, "date must be YYYY-MM-DD"))
        if not row["written_by"] or not row["prompt_version"]:
            errors.append((n, "written_by and prompt_version must be set"))
        if row["hook"] is not None and (why := problem(row["hook"], row.get("name"))):
            errors.append((n, f"{row['id']}: {why}: {row['hook']!r}"))
    return errors


def hooks_path(slug):
    return HOOKS_DIR / f"{slug}.jsonl"


def load(slug):
    """{id: row} from the committed hooks file (empty when there is none). Invalid rows are skipped
    loudly: a broken line must never publish a broken hook."""
    path = hooks_path(slug)
    if not path.exists():
        return {}
    rows = read_jsonl(path)
    bad = {n for n, _ in validate_rows(rows)}
    if bad:
        print(f"  ! {path.name}: {len(bad)} invalid line(s) ignored; run hooks.py validate {path}")
    return {row["id"]: row for n, row in rows if n not in bad and isinstance(row, dict)}


def write_hooks(slug, by_id):
    rows = sorted(by_id.values(), key=lambda r: r["id"])
    order = ("id", "name", "facts_hash", "hook", "prompt_version", "written_by", "date")
    text = "".join(json.dumps({k: r[k] for k in order if k in r}, ensure_ascii=False) + "\n" for r in rows)
    HOOKS_DIR.mkdir(exist_ok=True)
    hooks_path(slug).write_text(text, encoding="utf-8")


# ---- Bundles ----------------------------------------------------------------------------------

def bundles(slug, offline=False, everything=False):
    """(all bundles, the ones needing a hook). A bundle is {id, name, facts_hash, facts}."""
    import score  # score imports this module; import it here to avoid a cycle
    ctx = score.candidates(slug)
    sites = website.load_cache(slug) if offline else website.refresh(slug, [p["site_url"] for p in ctx.pois])
    committed = load(slug)
    out, todo = [], []
    for p in ctx.pois:
        f = facts(p, ctx.city["name"], sites)
        b = {"id": p["id"], "name": p["name"], "facts_hash": facts_hash(f), "facts": f}
        out.append(b)
        row = committed.get(p["id"])
        if p.get("hook_override"):
            continue  # hand-written in curation.csv
        if everything or not row or row["facts_hash"] != b["facts_hash"]:
            todo.append(b)
    return out, todo


def cmd_export(args):
    all_b, todo = bundles(args.city, args.offline, args.all)
    with open(args.out, "w", encoding="utf-8") as f:
        for b in todo:
            f.write(json.dumps(b, ensure_ascii=False, sort_keys=True) + "\n")
    cats = {}
    for b in todo:
        cats[b["facts"]["category"]] = cats.get(b["facts"]["category"], 0) + 1
    thin = sum(set(b["facts"]) <= {"name", "city", "category", "kind", "type", "local_name"} for b in todo)
    print(f"hooks export {args.city}: {len(todo)} of {len(all_b)} places need a hook {cats}; "
          f"{thin} have only name and kind (likely null)")
    print(f"  wrote {args.out} ({Path(args.out).stat().st_size // 1024} KB)")


def cmd_merge(args):
    all_b, _ = bundles(args.city, offline=True, everything=True)
    current = {b["id"]: b for b in all_b}
    by_id = load(args.city)
    version = prompt_version()
    today = datetime.date.today().isoformat()
    merged, rejected = 0, []
    for n, row in read_jsonl(args.answers):
        if isinstance(row, Exception) or not {"id", "facts_hash", "hook"} <= row.keys():
            rejected.append(f"line {n}: needs id, facts_hash and hook")
            continue
        b = current.get(row["id"])
        if not b:
            rejected.append(f"line {n}: {row['id']} is not a candidate place")
            continue
        if row["facts_hash"] != b["facts_hash"]:
            rejected.append(f"line {n}: {row['id']} facts changed since the export (re-export)")
            continue
        if row["hook"] is not None and (why := problem(row["hook"], b["name"])):
            rejected.append(f"line {n}: {row['id']}: {why}: {row['hook']!r}")
            continue
        by_id[row["id"]] = {"id": row["id"], "name": b["name"], "facts_hash": b["facts_hash"], "hook": row["hook"],
                            "prompt_version": version, "written_by": args.written_by, "date": today}
        merged += 1
    write_hooks(args.city, by_id)
    print(f"hooks merge {args.city}: {merged} merged, {len(rejected)} rejected; "
          f"{hooks_path(args.city).name} has {len(by_id)} lines")
    for r in rejected:
        print(f"  ! {r}")
    return 1 if rejected else 0


def cmd_validate(args):
    rows = read_jsonl(args.file)
    errors = validate_rows(rows)
    for n, msg in errors:
        print(f"{args.file}:{n}: {msg}")
    hooks = [r for _, r in rows if isinstance(r, dict)]
    print(f"{args.file}: {len(rows)} lines, {sum(r.get('hook') is not None for r in hooks)} hooks, "
          f"{sum(r.get('hook') is None for r in hooks)} null; {len(errors)} problem(s)")
    return 1 if errors else 0


# ---- Optional API writer ------------------------------------------------------------------------

OUTPUT_SCHEMA = {
    "type": "object",
    "properties": {"hook": {"anyOf": [{"type": "string"}, {"type": "null"}]}},
    "required": ["hook"],
    "additionalProperties": False,
}


def request_params(bundle, effort, system):
    """Messages API parameters for one bundle (also the Batch API's `params`)."""
    return {
        "model": MODEL,
        "max_tokens": 4096,  # thinking counts toward it on this model; the answer itself is ~30 tokens
        "system": system,
        "output_config": {"effort": effort, "format": {"type": "json_schema", "schema": OUTPUT_SCHEMA}},
        "messages": [{"role": "user", "content": user_message(bundle)}],
    }


def user_message(bundle):
    return "Facts (JSON):\n" + json.dumps(bundle["facts"], ensure_ascii=False, sort_keys=True, indent=1)


def parse_message(msg, name):
    """(hook or None, status) from a Message. status: ok | null | refusal | max_tokens | invalid: ..."""
    if msg.stop_reason == "refusal":
        return None, "refusal"
    if msg.stop_reason == "max_tokens":
        return None, "max_tokens"
    text = next((b.text for b in msg.content if b.type == "text"), None)
    try:
        hook = json.loads(text)["hook"] if text else None
    except (json.JSONDecodeError, KeyError, TypeError):
        return None, "invalid: not the JSON schema"
    if hook is None:
        return None, "null"
    hook = " ".join(str(hook).split())
    why = problem(hook, name)
    return (None, f"invalid: {why}") if why else (hook, "ok")


def api_client():
    import os
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise SystemExit("hooks write --api: ANTHROPIC_API_KEY is not set (hooks are normally written in a "
                         "Claude Code session: see Data/hooks/WRITING.md)")
    try:
        import anthropic
    except ImportError:
        raise SystemExit("hooks write --api: pip install -r Data/requirements-hooks.txt")
    return anthropic, anthropic.Anthropic()


def call_one(anthropic, client, bundle, effort, system):
    """(hook, status) for one bundle with a plain Messages call; typed SDK errors, most specific first."""
    try:
        msg = client.messages.create(**request_params(bundle, effort, system))
    except anthropic.BadRequestError as e:
        return None, f"error: bad request: {e.message}"
    except anthropic.AuthenticationError:
        raise SystemExit("hooks write --api: invalid ANTHROPIC_API_KEY")
    except anthropic.PermissionDeniedError:
        raise SystemExit("hooks write --api: the API key lacks permission")
    except anthropic.NotFoundError:
        raise SystemExit(f"hooks write --api: model {MODEL} not found")
    except anthropic.RateLimitError:
        return None, "error: rate limited (after the SDK's retries)"
    except anthropic.APIStatusError as e:
        return None, f"error: API status {e.status_code}"
    except anthropic.APIConnectionError:
        return None, "error: connection"
    return parse_message(msg, bundle["name"])


def run_batch(anthropic, client, todo, effort, system, wait_s):
    """{id: (hook, status)} via the Batch API."""
    from anthropic.types.message_create_params import MessageCreateParamsNonStreaming
    from anthropic.types.messages.batch_create_params import Request
    by_custom = {f"p{i}": b for i, b in enumerate(todo)}  # custom_id allows [a-zA-Z0-9_-] only
    batch = client.messages.batches.create(requests=[
        Request(custom_id=cid, params=MessageCreateParamsNonStreaming(**request_params(b, effort, system)))
        for cid, b in by_custom.items()])
    print(f"  batch {batch.id}: {len(todo)} requests", flush=True)
    deadline = time.time() + wait_s
    while True:
        batch = client.messages.batches.retrieve(batch.id)
        if batch.processing_status == "ended":
            break
        if time.time() > deadline:
            raise SystemExit(f"hooks write --api: batch {batch.id} still running after {wait_s}s; nothing merged")
        time.sleep(30)
    out = {}
    for result in client.messages.batches.results(batch.id):
        b = by_custom[result.custom_id]
        if result.result.type == "succeeded":
            out[b["id"]] = parse_message(result.result.message, b["name"])
        else:
            out[b["id"]] = (None, f"error: batch {result.result.type}")
    return out


def cmd_write(args):
    if not args.api:
        raise SystemExit("hooks write: only --api is supported (hooks are normally written in a Claude Code "
                         "session: see Data/hooks/WRITING.md)")
    _, todo = bundles(args.city, args.offline)
    todo = todo[:args.limit] if args.limit else todo
    anthropic, client = api_client()
    system = system_prompt()
    if args.compare_effort:
        sample = todo[:args.compare_effort]
        print("| place | low | medium |\n|---|---|---|")
        for b in sample:
            res = [call_one(anthropic, client, b, e, system) for e in ("low", "medium")]
            print(f"| {b['name']} | " + " | ".join(h or f"({s})" for h, s in res) + " |")
        return 0
    if len(todo) >= BATCH_MIN:
        results = run_batch(anthropic, client, todo, args.effort, system, args.wait)
    else:
        results = {b["id"]: call_one(anthropic, client, b, args.effort, system) for b in todo}
    by_id = load(args.city)
    version, today = prompt_version(), datetime.date.today().isoformat()
    statuses = {}
    names = {b["id"]: b for b in todo}
    for pid, (hook, status) in results.items():
        statuses[status.split(":")[0]] = statuses.get(status.split(":")[0], 0) + 1
        if status.startswith("error") or status == "max_tokens":
            continue  # transient: try again next time
        b = names[pid]
        by_id[pid] = {"id": pid, "name": b["name"], "facts_hash": b["facts_hash"], "hook": hook,
                      "prompt_version": version, "written_by": f"{MODEL} api effort={args.effort}", "date": today}
    write_hooks(args.city, by_id)
    print(f"hooks write --api {args.city}: {len(todo)} places: {statuses}; review the diff before committing")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Hook lines for places (ADR 015). See Data/hooks/WRITING.md.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export", help="fact bundles for places that need a hook")
    e.add_argument("city")
    e.add_argument("--out", required=True)
    e.add_argument("--offline", action="store_true", help="use cached homepage metadata only")
    e.add_argument("--all", action="store_true", help="every candidate place, even with a current hook")
    m = sub.add_parser("merge", help="merge a writer's answers into Data/hooks/<city>.jsonl")
    m.add_argument("city")
    m.add_argument("answers")
    m.add_argument("--written-by", required=True, help='e.g. "claude-code (claude-opus-5-5)"')
    v = sub.add_parser("validate", help="check a hooks file")
    v.add_argument("file")
    w = sub.add_parser("write", help="OPTIONAL: write hooks with the Anthropic API (off by default)")
    w.add_argument("city")
    w.add_argument("--api", action="store_true", help="required: use the Anthropic API (ANTHROPIC_API_KEY)")
    w.add_argument("--effort", default=DEFAULT_EFFORT, choices=("low", "medium", "high"))
    w.add_argument("--limit", type=int)
    w.add_argument("--offline", action="store_true")
    w.add_argument("--wait", type=int, default=3 * 3600, help="seconds to wait for a batch")
    w.add_argument("--compare-effort", type=int, metavar="N", help="print low vs medium for N places; writes nothing")
    args = parser.parse_args()
    return {"export": cmd_export, "merge": cmd_merge, "validate": cmd_validate, "write": cmd_write}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main() or 0)
