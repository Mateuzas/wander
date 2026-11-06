# ADR 012: Fewer, better places: score floors, tiers and zoom layering

**Status:** accepted (Architect, 2026-11-05; user feedback #8: "way too many places, quality turns bad").

**Context.** Vilnius has 998 POIs: 612 food (median score 30), 59 popular sights (20 of them only through
the fame rule, some scoring 25). The map shows up to 60 beads at every zoom, so mediocre places crowd out good ones.

**Decision.**
1. **Data floors** (pipeline): drop places below a per-category score floor: photo < 30, shop < 30, food < 35.
   Tunable in `score.py`; a curation `boost`/`popular` still rescues a known gem.
2. **Tiers** (pipeline), per category after the floor:
   - tier 1 (must-see): the top 4% by score (minimum 1), plus sights with fame ≥ 0.8; sights capped at 25.
   - tier 2 (notable): the next 15% by score.
   - tier 3: everything else.
   `popular` stays in the file, equal to `tier == 1`, for compatibility.
3. **Zoom layering** (app), by visible latitude span:
   - wider than 0.04° (≈ 4.5 km): tier 1 only
   - 0.015–0.04°: tiers 1 and 2, on a 64 pt grid
   - narrower than 0.015°: all tiers, on a 44 pt grid, at most 60 ordinary beads

   Route highlights and the selected place always show. Interest filters apply at every zoom.

**Consequences.** The engine sees fewer, better candidates, which is fine because weak places were rarely chosen.
The thresholds are first guesses, tuned on the phone at three zoom levels.
