# ADR 010: Nightly data job publishing static files (amends ADR 001)

**Status:** accepted in principle (user, 2026-11-05). Design comes in ROADMAP phase 4.

**Context.** The bundled data is static and goes out of date: new and niche places are missing, and events can't be bundled at all.

**Decision.** A scheduled job (GitHub Actions, nightly) collects places and events from several sources, merges
and scores them, and publishes static JSON files (same schema family) to cheap hosting. The app downloads the
current file at launch and falls back to the bundled one. Still no app server and no database. Sources must allow this
use (terms and robots), and the job must be thorough and reviewable (diffs, counts, a quarantine for doubtful items).
Finding sources per city is an open problem; Vilnius starts with sources the user names.
