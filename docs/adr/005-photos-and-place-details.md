# ADR 005: Place photos from the place's own Commons data; Apple place card only on a confident match

**Status:** accepted (2026-11-02).

**Decision.** Photos come only from the place's own `commonsImage` (OSM tag or Wikidata P18) and its
`commonsCategory` (OSM tag or P373), never from "photos near this point", which often show another
building. A photo or category shared by 3 or more places is dropped (series-level Wikidata items), and
`curation.csv` `image` rows remove wrong ones. Apple's place card (iOS 18+) shows only for a
name-matched result within 60 m; when unsure, nothing is shown. Every photo shows author and licence.
