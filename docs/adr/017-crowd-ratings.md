# ADR 017: Crowd ratings from anonymous swipes

**Status:** proposed (user idea 2026-11-07: "build a db with the likes, thus knowing which places are actually the best
in the city"). Scheduled after swipe walks (ADR 016) work on the phone with local memory only.

## Why
No free source offers ratings we may store (docs/research/vilnius-sources.md). Users' swipes are our own rating signal,
and the strongest one we could have for niche places.

## Proposed design
- **What's sent:** anonymous events `{placeId, reaction: love|like|nope, day}`, batched and sent at most once a day.
  No account, no device id, no location trail, no IP stored. Clear notice plus an opt-in toggle (EU: aim for no
  personal data at all).
- **Abuse protection:** Apple App Attest on the request (only the genuine app can submit), per-install daily caps,
  server-side rate limits, outlier dropping.
- **Server:** the first server component (amends ADR 001/010). Candidates: Supabase (already connected to the
  workspace; free tier; Postgres plus an edge function) or a Cloudflare Worker with D1. The choice is made in the
  design phase.
- **Use:** the nightly job pulls per-place aggregates (counts, love share, Wilson score) into a new `signals.crowd`
  (0–1). Scoring and tiers blend it in as sample sizes grow, so a niche place loved by many users can become a
  must-see. Published files carry only aggregates.
- **Later:** the same backend can serve social mode (ADR 011) when it comes.

## Open
- Supabase or Cloudflare; App Attest setup (needs the Apple Developer Program for production, ties into ARC-2).
- Minimum sample size before the crowd signal affects tiers.
