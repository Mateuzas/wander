# ADR 015: Every place needs a hook line and a photo, or it's removed

**Status:** accepted (user, 2026-11-06). Supersedes the description-coverage targets of the descriptions contract.

**Context.** Many places appear with only a name ("way too many points that just have a name"). A visitor can't tell
why they'd care. The user's decisions:
- AI writes the lines, grounded in facts
- photos from Mapillary or website preview images, whichever is better per place
- places lacking either are removed entirely

**Decision.**
1. **Hook** (`hook`, ≤ 80 characters, one sentence, eye-catching, sentence case, no emoji or hype words):
   - **Written by Claude Code sessions on the user's Claude subscription, not a paid API** (user decision 2026-11-06).
     `run_nightly.py --export-facts` writes one facts bundle per place that lacks a hook for its current facts hash.
     A Claude Code session (by hand, or a weekly scheduled routine) writes hooks by the rules in
     `Data/hooks/WRITING.md`, validates them with `Data/hooks.py validate`, and opens a PR with
     `Data/hooks/<city>.jsonl` (`{id, facts_hash, hook|null, prompt_version, written_by, date}`). The user reviews it.
   - **Grounding:** a bundle contains only facts we hold: name, kind and cuisine, OSM tags (outdoor seating, diet,
     heritage, start date, artist), the Wikipedia extract, the place's own website title or meta description, and the
     Overture category. The writer must not add facts. If the facts can't support an intriguing line, the hook is `null`
     and the place is removed (rule 3).
   - **Freshness:** the nightly job uses a hook only when its `facts_hash` matches the place's current facts. New or
     changed places stay off the map until the next writing session (at most about a week with the scheduled routine).
   - **Optional API writer:** `Data/hooks.py write --api` with the official `anthropic` SDK exists for when an API key is
     ever wanted. It's off by default, never used in CI, and the nightly job needs no Anthropic secret.
2. **Photo** (`photo` object), first available in priority order, scored "better" where several exist:
   1. own Commons image (`commonsImage`), then the Commons category
   2. Mapillary street-level image: the closest image within 40 m whose camera faces the place (compass angle within
      ±50° of the bearing to it); open licence (CC BY-SA); client token in the GitHub secret `MAPILLARY_TOKEN`
   3. the website preview image (`og:image` / `twitter:image`) from the place's own website, fetched only where
      robots.txt allows it; not used if it looks like a logo (square under 400 px, or svg)

   "Better" between Mapillary and the website preview: prefer a website photo that is large (≥ 800 px) and
   non-logo for food, shops and venues; prefer Mapillary for sights. Store the URL, never the bytes.
   `photo = {url, source: "commons"|"mapillary"|"website", credit, license?, page}`.
3. **Gate:** a place without both `hook` and `photo` is removed before tiers are computed. Curation `popular yes` does
   **not** override this; curation can add a hand-written `hook` (new `hook` action) or `photo` (existing `image` action).
4. **Description:** stays optional, shown under the hook in the card; `reason` stays as the short type label.

**Consequences.** The map shrinks to places that sell themselves. Writing uses the user's subscription limits (about 800
lines once, then a handful weekly), with no API bill. Every line is reviewed in a PR before it goes live. Expect counts well below 812; the publish gate needs a
one-time `--allow-shrink` for the first run (decreases are otherwise gated).
