"""Publish gate for a nightly POI file (ADR 013, CONTRACTS §3b).

    python3 Data/publish_gate.py --new build/pois-vilnius.json --previous <file|URL|none>
                                 [--curation Data/curation.csv] [--rerun <file>] [--allow-growth]

Checks, each reported in a Markdown summary on stdout (fit for $GITHUB_STEP_SUMMARY):
- the new file validates against docs/schema/pois.schema.json (scripts/validate-pois.py)
- city and file structure are unchanged: same `city`, same top-level keys, no POI field dropped
- POI count per category is within ±25% of the previous file; with --allow-growth (a new source,
  ADR 014) increases of any size pass, decreases are still limited to -25%
- every previous tier-1 id is still tier 1, or has a curation row (`exclude`, or `popular no`)
- with --rerun: a second build from the same inputs is byte-identical, ignoring `generated`

`--previous none` (first publish) or an HTTP 404 for the URL passes the comparisons with a note.
Exits 1 if any check fails, 2 on bad usage.
"""
import argparse
import csv
import importlib.util
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COUNT_TOLERANCE = 0.25
CATEGORIES = ("photo", "shop", "food")
USER_AGENT = "WanderMVP/0.1 (nightly publish gate)"

_validator_module = None


def validator_module():
    """scripts/validate-pois.py, imported by path (its name has a hyphen)."""
    global _validator_module
    if _validator_module is None:
        spec = importlib.util.spec_from_file_location("validate_pois", ROOT / "scripts" / "validate-pois.py")
        _validator_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_validator_module)
    return _validator_module


def validate(path):
    """[(json path, message)] problems of a POI file against the schema; empty when valid."""
    vp = validator_module()
    validator = vp.Validator(json.loads(vp.SCHEMA.read_text(encoding="utf-8")))
    errors = vp.validate_file(path, validator)
    if validator.unsupported:
        errors.append(("$", f"schema uses keywords the validator ignores: {sorted(validator.unsupported)}"))
    return errors


def load_previous(src):
    """(document or None, note). None for 'none' or an HTTP 404; raises on any other failure."""
    if src.strip().lower() == "none":
        return None, "none (first publish)"
    if re.match(r"https?://", src):
        req = urllib.request.Request(src, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.loads(resp.read().decode("utf-8")), src
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None, f"{src} returned 404 (nothing published yet)"
            raise
    return json.loads(Path(src).read_text(encoding="utf-8")), src


def load_curation(path):
    """{id: {action, ...}} from curation.csv; comment rows (id starting with #) are skipped."""
    rules = {}
    with Path(path).open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            osm_id = (row.get("osm_id") or "").strip()
            if osm_id and not osm_id.startswith("#"):
                action = (row.get("action") or "").strip()
                value = (row.get("value") or "").strip().lower()
                rules.setdefault(osm_id, set()).add(f"{action} {value}".strip())
    return rules


def explains_tier1_loss(actions):
    return any(a == "exclude" or a.startswith("exclude ") or a in ("popular no", "popular false", "popular 0")
               for a in actions)


def without_generated(raw):
    return re.sub(rb'"generated"\s*:\s*"[^"]*"', b'"generated": ""', raw, count=1)


class Gate:
    def __init__(self):
        self.rows = []  # (check, ok, detail)

    def add(self, check, ok, detail):
        self.rows.append((check, ok, detail))

    @property
    def failed(self):
        return [r for r in self.rows if r[1] is False]


def run(args):
    gate = Gate()
    notes = []
    new_path = Path(args.new)

    errors = validate(new_path)
    if errors:
        shown = "; ".join(f"{p}: {m}" for p, m in errors[:5])
        more = f" (and {len(errors) - 5} more)" if len(errors) > 5 else ""
        gate.add("Schema", False, f"{len(errors)} problem(s): {shown}{more}")
    else:
        gate.add("Schema", True, "validates against docs/schema/pois.schema.json")
    try:
        new = json.loads(new_path.read_text(encoding="utf-8"))
        new_pois = [p for p in new.get("pois", []) if isinstance(p, dict)]
    except Exception as exc:
        gate.add("Readable", False, f"cannot read {new_path}: {exc}")
        return gate, notes, None

    try:
        previous, prev_note = load_previous(args.previous)
    except Exception as exc:
        gate.add("Previous file", False, f"cannot load {args.previous}: {exc}")
        previous, prev_note = None, None
    if prev_note:
        notes.append(f"Previous: {prev_note}.")

    if previous is not None:
        prev_pois = [p for p in previous.get("pois", []) if isinstance(p, dict)]

        same_city = new.get("city") == previous.get("city")
        gate.add("City", same_city, f"{new.get('city')!r}" if same_city
                 else f"changed from {previous.get('city')!r} to {new.get('city')!r}")

        dropped_top = sorted(set(previous) - set(new))
        added_top = sorted(set(new) - set(previous))
        new_fields = set().union(*(p.keys() for p in new_pois)) if new_pois else set()
        prev_fields = set().union(*(p.keys() for p in prev_pois)) if prev_pois else set()
        dropped_fields = sorted(prev_fields - new_fields)
        problems = []
        if dropped_top or added_top:
            problems.append(f"top-level keys changed (dropped {dropped_top}, added {added_top})")
        if dropped_fields:
            problems.append(f"POI fields no longer present: {dropped_fields}")
        gate.add("Structure", not problems, "; ".join(problems) or "same top-level keys, no POI field dropped")
        if sorted(new_fields - prev_fields):
            notes.append(f"New POI fields: {sorted(new_fields - prev_fields)} (additive).")

        for cat in CATEGORIES:
            n_new = sum(p.get("category") == cat for p in new_pois)
            n_old = sum(p.get("category") == cat for p in prev_pois)
            if n_old == 0:
                gate.add(f"Count: {cat}", True, f"{n_new} (previous had none)")
                continue
            change = (n_new - n_old) / n_old
            ok = abs(change) <= COUNT_TOLERANCE or (args.allow_growth and change > 0)
            limit = f"-{COUNT_TOLERANCE:.0%}, growth allowed" if args.allow_growth else f"±{COUNT_TOLERANCE:.0%}"
            gate.add(f"Count: {cat}", ok, f"{n_old} -> {n_new} ({change:+.1%}; limit {limit})")

        curation = load_curation(args.curation)
        now = {p.get("id"): p for p in new_pois}
        lost = []
        explained = []
        for p in prev_pois:
            if p.get("tier") != 1 and p.get("popular") is not True:
                continue
            cur = now.get(p["id"])
            if cur and cur.get("tier") == 1:
                continue
            state = f"now tier {cur.get('tier')}" if cur else "gone"
            label = f"{p.get('name')} (`{p['id']}`, {state})"
            (explained if explains_tier1_loss(curation.get(p["id"], ())) else lost).append(label)
        n_prev_t1 = sum(p.get("tier") == 1 or p.get("popular") is True for p in prev_pois)
        if lost:
            gate.add("Tier 1 kept", False, f"{len(lost)} tier-1 place(s) lost without a curation row "
                                           f"(exclude, or popular no): " + "; ".join(lost))
        else:
            gate.add("Tier 1 kept", True, f"all {n_prev_t1} previous tier-1 places are still tier 1"
                     + (f", or curated out: {'; '.join(explained)}" if explained else ""))
    else:
        notes.append("Count, city, structure and tier-1 checks skipped: nothing to compare with.")

    if args.rerun:
        try:
            a, b = new_path.read_bytes(), Path(args.rerun).read_bytes()
            if a == b:
                gate.add("Deterministic", True, "re-run is byte-identical")
            elif without_generated(a) == without_generated(b):
                gate.add("Deterministic", True, "re-run is identical apart from `generated`")
            else:
                gate.add("Deterministic", False, f"{args.rerun} differs from {args.new}")
        except OSError as exc:
            gate.add("Deterministic", False, f"cannot read the re-run: {exc}")

    return gate, notes, new


def markdown(gate, notes, new, args):
    ok = not gate.failed
    city = new.get("city", "?") if isinstance(new, dict) else "?"
    n = len(new.get("pois", [])) if isinstance(new, dict) else "?"
    lines = [f"## Publish gate: {'PASS' if ok else 'FAIL'}", "",
             f"`{args.new}`: {city}, {n} POIs, generated {new.get('generated', '?') if isinstance(new, dict) else '?'}.",
             ""]
    if args.allow_growth:
        lines += ["> **--allow-growth is on:** count increases above +25% pass this run (a new source, ADR 014). "
                  "Decreases are still limited to -25%.", ""]
    lines += ["| Check | Result | Detail |", "|---|---|---|"]
    for check, passed, detail in gate.rows:
        lines.append(f"| {check} | {'pass' if passed else '**FAIL**'} | {str(detail).replace('|', '/')} |")
    if notes:
        lines += [""] + [f"- {note}" for note in notes]
    if not ok:
        lines += ["", "Not published: the previous file stays live. Fix the data, or add a "
                      "`Data/curation.csv` row for an intended tier-1 change."]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Check a nightly POI file before publishing (ADR 013).")
    parser.add_argument("--new", required=True, help="the freshly built pois-<city>.json")
    parser.add_argument("--previous", required=True, help="last published file: path, URL, or 'none'")
    parser.add_argument("--curation", default=str(ROOT / "Data" / "curation.csv"), help="curation.csv to consult")
    parser.add_argument("--rerun", help="optional second build from the same inputs (determinism check)")
    parser.add_argument("--allow-growth", action="store_true",
                        help="let per-category counts grow by more than 25%% (e.g. a new source); decreases are still gated")
    args = parser.parse_args()
    gate, notes, new = run(args)
    sys.stdout.write(markdown(gate, notes, new, args))
    return 1 if gate.failed else 0


if __name__ == "__main__":
    sys.exit(main())
