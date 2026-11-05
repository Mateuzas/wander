# ADR 009: Background location during walks, for Live Activity navigation

**Status:** accepted (user, 2026-11-05). Amends PLAN §8 ("no background modes").

**Decision.** Between "Start walk" and the end of the walk, the app keeps receiving location in the background,
still with "While Using" permission (iOS shows the blue location indicator). That drives a Live Activity: the Dynamic
Island and Lock Screen show the next-turn arrow and distance, and the card expands with the name and type of a place
as the walker approaches it. No background location outside walks.
