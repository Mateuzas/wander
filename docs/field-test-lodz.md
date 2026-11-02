# Łódź field test

What we want to learn (PLAN.md §3): do people pick the Wander route over the fast one, and do they see things they would have missed?

## Before the trip

- [ ] **Reinstall the app the day before you leave.** A free Apple ID install stops opening after 7 days. Plug in, open `App/Wander.xcodeproj`, ⌘R.
- [ ] Walking mode (milestone 5) is merged and installed. Without it you can only test planning.
- [ ] Phone charged plus a power bank: GPS with the screen on uses a lot.
- [ ] Mobile data works in Poland (routes need internet; the places are in the app).
- [ ] Optional: try a walk from home first with `scripts/fake-location.py walk fabryczna manufaktura`.

## During each walk

Keep it light. Jot notes in the phone's Notes app; exact wording doesn't matter.

1. Plan the walk in **Direct**, **Relaxed** and **Explorer**. Note which one you'd actually pick, and why.
2. Walk it. When a highlight comes up, look: was it worth it?
3. Right after, answer the three questions below.

Note any **place problem** in one line: `name — problem`, for example:
- `Passage of Roses — locked gate, couldn't get in`
- `Pizza Pronto — boring, shouldn't be a highlight`
- `Tuwim's Bench — pin is 50 m off`
- `missing: <a place you passed that should have been suggested>`

Send me the list and I'll fix them in `Data/curation.csv`, one line each.

## The 10 walks

Same pairs as the engine's golden routes, so we can compare what it predicted with what happened. Do as many as fit; 5 good ones beat 10 rushed ones.

| # | From → to | Direct, min (engine estimate) |
|---|---|---|
| 1 | Łódź Fabryczna → Manufaktura | 26 min |
| 2 | Plac Wolności → OFF Piotrkowska | 30 min |
| 3 | Manufaktura → Księży Młyn | 58 min |
| 4 | EC1 → Park Źródliska | 19 min |
| 5 | Poznański Palace → Grand Theatre | 23 min |
| 6 | Łódź Kaliska → Piotrkowska 104 | 33 min |
| 7 | OFF Piotrkowska → Herbst Palace | 31 min |
| 8 | Stary Rynek → EC1 | 31 min |
| 9 | MS1 Museum of Art → Cathedral | 43 min |
| 10 | Park Źródliska → Plac Wolności | 42 min |

### After each walk

```
Walk #:
Mode picked (Direct / Relaxed / Explorer) and why:
1. Did you see something you would have missed?
2. Would you choose this over the fast route next time?
3. Did any highlight feel not worth it, or did the route do something odd?
Place problems:
```

## If you walk with other people (3–5 testers is the goal)

Hand them the phone with a destination already chosen and say nothing about the modes. Note **which mode they pick on their own**: that's the most honest signal we'll get.

## Success, from PLAN.md §3

- Explorer stays within its extra time, ±10%
- Explorer shows at least 2 highlights on at least 8 of the 10 walks
- **No waypoint is unreachable or clearly not worth it.** This is the trust-killer, so report every one.
