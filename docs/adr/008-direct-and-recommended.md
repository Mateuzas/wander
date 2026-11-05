# ADR 008: Two route options, Direct and Recommended; the engine decides the extra time

**Status:** accepted (user, 2026-11-05). Replaces the Relaxed/Explorer modes of PLAN §6–7.

**Decision.**
- **Direct:** the fastest route, still listing the highlights on the way.
- **Recommended:** a tourist detour shaped by the user's filters. The engine decides how much extra time is worth it,
  up to a cap, instead of the user picking a budget.

Which filters to offer is iterated with the user, so it doesn't feel overwhelming. Engine tuning ("perfecting the engine")
is scheduled after fresh data lands (ROADMAP phase 5), because good recommendations depend on up-to-date places.
