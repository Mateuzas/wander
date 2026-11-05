# ADR 007: Vilnius is the only city; Łódź data is dropped

**Status:** accepted (user, 2026-11-05).

**Context.** Łódź was the field-test city. The user lives in Vilnius and will test and iterate there.

**Decision.** Ship only `pois-vilnius.json`. Remove Łódź data, curation rows, English names and golden routes;
they stay in git history (PRs #2–#24). The pipeline stays city-generic, so adding a city later is configuration.
