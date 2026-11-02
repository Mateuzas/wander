# ADR 006: Architect Protocol roles map onto existing directories

**Status:** accepted (user, 2026-11-02).

**Context.** The Architect Protocol suggests `backend/`, `frontend/` and `infra/` folders. Wander is an
iOS app with no server.

**Decision.** Keep the current layout and assign ownership by directory (AGENTS.md):
Backender = `Packages/RouteEngine/` and `Data/`; Frontender = `App/` (without generated resources or
signing config); DevOps = `.github/`, `scripts/`, `secrets/` and `App/Config/`; Architect = `docs/` and
the top-level guides.

**Why.** Moving `App/` and `Packages/` would break the hand-written Xcode project paths, CI and every open
branch, with no benefit. The protocol's server defaults (containers, health endpoints) don't apply.
