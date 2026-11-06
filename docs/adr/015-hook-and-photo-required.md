# ADR 015: Every place needs a hook line and a photo, or it's removed

**Status:** accepted (user, 2026-11-06). Supersedes the description-coverage targets of the descriptions contract.

**Context.** Many places appear with only a name ("way too many points that just have a name"). A visitor can't tell
why they'd care. The user's decisions:
- AI writes the lines, grounded in facts
- photos from Mapillary or website preview images, whichever is better per place
- places lacking either are removed entirely

**Decision.**
1. **Hook** (`hook`, ≤ 80 characters, one sentence, eye-catching, sentence case, no emoji or hype words):
   - Written by Claude via the Anthropic API in the nightly pipeline (`Data/hooks.py`; official `anthropic` Python SDK
     pinned in `Data/requirements-hooks.txt`; model `claude-opus-5-5`, the default, swappable by one constant). The Batch
     API is used for full runs.
   - **Grounding:** the prompt contains only facts we hold: name, kind and cuisine, OSM tags (outdoor seating, diet,
     heritage, start date, artist), the Wikipedia extract, the place's own website title or meta description, and the
     Overture category. The model must not add facts; if the facts can't support an intriguing line, it returns
     `null`, and the place is removed (rule 3).
   - Structured output (`output_config.format`: JSON schema `{hook: string|null}`), length enforced after parsing.
   - **Cached** per place by a hash of (facts + prompt version + model) in `Data/cache/<city>/hooks.json`, so nights
     only pay for new or changed places. A prompt or model change bumps the version and rewrites all hooks.
   - **The API key** is a GitHub Actions secret `ANTHROPIC_API_KEY` only; never on disk, never in the repo. Without the
     key (local dev, forks) the step uses cached hooks and drops uncached places, with a loud summary line.
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

**Consequences.** The map shrinks to places that sell themselves. The first full run costs about $1–2 on Opus 5.5
(about half that with Batch); nightly cost after that is cents. Expect counts well below 812; the publish gate needs a
one-time `--allow-shrink` for the first run (decreases are otherwise gated).
