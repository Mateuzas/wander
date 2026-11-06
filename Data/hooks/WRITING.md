# Writing hook lines (ADR 015)

Every published place needs a **hook**: one short, factual sentence that makes a visitor who knows
nothing about the place want to look. Hooks are written by a Claude Code session (or a scheduled
weekly routine) on the user's subscription, from fact bundles we export, and committed here as
`Data/hooks/<city>.jsonl`. The nightly job never calls an API: a place without a current hook is
not published.

PROMPT_VERSION: `1`

Bump the version when the rules below change; `hooks.py merge` stamps it on every line.

## Workflow

```sh
# 1. Export the places that need a hook (new places, or places whose facts changed).
python3 Data/hooks.py export vilnius --out /tmp/facts-vilnius.jsonl

# 2. Write one answer line per bundle into /tmp/answers-vilnius.jsonl (format below),
#    following the rules in the prompt block exactly.

# 3. Merge: checks every answer against the rules and the current facts; rejects are listed, not merged.
python3 Data/hooks.py merge vilnius /tmp/answers-vilnius.jsonl --written-by "claude-code (claude-opus-5-5)"

# 4. Validate the committed file, review the diff, commit.
python3 Data/hooks.py validate Data/hooks/vilnius.jsonl
```

Fix and re-merge any rejected lines (or answer `null`). Work in chunks of about 50 bundles and
merge after each chunk, so a long session never loses work.

## Input: one bundle per line

```json
{"id": "osm:node:31319735", "name": "Frank Zappa", "facts_hash": "3f2a9c0d1e4b5a67",
 "facts": {"category": "sight", "city": "Vilnius", "kind": "Bust", "type": "bust", "name": "Frank Zappa",
           "osm": {"artist_name": "Konstantinas Bogdanas", "start_date": "1995"},
           "wikidata_label": "Frank Zappa memorial"}}
```

`facts` holds only data we have: name, kind, cuisine, selected OSM tags (artist, architect, start
date, heritage, inscription, outdoor seating, diet options...), the English Wikipedia extract, the
Overture category, the website domain, and the place's own homepage title and meta description. Some values are in
Lithuanian; translating them is fine, adding to them is not.

## Output: one answer per line

```json
{"id": "osm:node:31319735", "facts_hash": "3f2a9c0d1e4b5a67", "hook": "A bust by sculptor Konstantinas Bogdanas, put up here in 1995."}
{"id": "ovt:0a1b...", "facts_hash": "9c8d7e6f5a4b3c2d", "hook": null}
```

Copy `id` and `facts_hash` from the bundle unchanged. `hook` is a string or `null`. `merge` adds
`name`, `prompt_version`, `written_by` and `date`; the committed file has one line per place:
`{id, name, facts_hash, hook, prompt_version, written_by, date}`, sorted by id.

## The rules (also the API writer's system prompt)

<!-- prompt:start -->
```text
You write the hook line for a place card in a walking app for visitors. The card already shows the
place's name, kind and photo; the hook is the one line that makes a visitor who knows nothing about
the place want to go and look.

You get a JSON object of facts about one place. Write one hook:
- One sentence, at most 80 characters, ending with a full stop. Sentence case. No emoji, no
  exclamation or question marks, no quotation of the name as a headline.
- Factual: use only the facts given. Never add a date, a person, a number, a superlative or a
  claim that the facts don't state. Translating a Lithuanian fact into English is fine.
- Specific and intriguing: lead with the most surprising or concrete fact (who made it, when, what
  it was, what is unusual about it, what they serve or sell that is distinctive).
- Don't start with the place's name and don't spend words restating its kind ("This café is a
  café"); the card shows both.
- No hype or marketing words: amazing, must-visit, must-see, hidden gem, best, stunning,
  breathtaking, iconic, unmissable, world-class, perfect, ultimate, incredible, awesome. No
  superlative ("oldest", "largest", "first") unless a fact states it.
- Neutral, plain English; no "you", no invitations ("Come and...", "Don't miss...").
- If the facts can't support a specific, intriguing line (for example only a name and a kind, or a
  generic website slogan), the answer is null. A null removes the place from the map, which is
  better than a bland or invented line.

Answer with JSON only: {"hook": "<the line>"} or {"hook": null}.
```
<!-- prompt:end -->

## Checked automatically

`hooks.py merge` and `hooks.py validate` reject: more than 80 or fewer than 10 characters; more
than one sentence; no final full stop; `!` or `?`; not starting with a capital or digit; emoji or
symbols; any of the banned words above; starting with the place's own name; stray whitespace.
They cannot check facts: review the diff against the bundles before committing.

## Good and bad

| Facts (short) | Hook | Why |
|---|---|---|
| bust, Frank Zappa, artist Konstantinas Bogdanas, 1995 | A bust by sculptor Konstantinas Bogdanas, put up here in 1995. | specific, all from facts |
| café, cuisine coffee, website "Specialty coffee roasted in-house" | Coffee roasted in-house, served a few steps from the counter. | grounded in the website line |
| restaurant, name and kind only | `null` | nothing to say |
| museum, Wikipedia "the oldest museum in Lithuania" | Lithuania's oldest museum, founded in 1855. | superlative stated in the facts |
| bar, website "The best cocktails in town!" | `null`, or a line from other facts | the slogan is not a fact |
