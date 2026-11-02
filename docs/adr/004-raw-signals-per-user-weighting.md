# ADR 004: Ship raw signals and let the app weight them per user

**Status:** accepted (user, 2026-11-02).

**Decision.** Each POI carries `signals` (photos, fame, quality, independent) besides the default
`score`. The engine values POIs as Σ weight × signal using `WeightPreset` route styles. Ratings are
reserved as a future signal: no free source has them, and Google's terms forbid storing them.

**Note.** Shop and food scores use independence as a multiplier, capped at 70, so cafés don't
outrank landmarks (PLAN §5.3 weights put 244 food places in the Łódź top 300).
