# ADR 003: English display names for sights; local name kept for matching

**Status:** accepted (user, 2026-11-02).

**Decision.** Sights show reviewed English names from `Data/names-en/<city>.csv`, drafted once
because OSM rarely has `name:en` and Wikidata labels are unreliable. Shops and food keep their own names.
The original name ships as `localName`, so Apple place cards can be matched.
