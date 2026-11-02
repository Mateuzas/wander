# Wander – brand kit (Direction 2, "W route")

> In this repo: the app icon is `App/Wander/Assets.xcassets/AppIcon.appiconset`, the horizontal logo is the
> `WanderLogo` image asset (light and dark), and the mark is `App/Wander/DesignSystem/WanderMark.swift`
> (using the app's PLAN §10 colour tokens). The kit's `Brand.swift` was not added because `Colors.swift`
> already has the same colours. The app keeps its §10 dark surface `#161B22`, a hair darker than the kit's `#18212C`.
> The original kit (SVG/PNG sources) is `wander-brand-kit.zip`, kept outside the repo.

Wander is an iPhone walking-map app for tourists.
Pitch: "Get where you're going, but walk past the good stuff."
It plans a walking route that passes photo spots, independent shops and food on the way.

Feel: quiet, calm, glanceable, flat.
Never use: map pins, compasses, globes, footprints, gradients, 3D, drop shadows on the mark.

## The signature element: the Wander route

A bold violet line with small coloured "beads" strung along it. Each bead is a highlight on the walk.
Use the same idea in the UI: the planned walking route on the map is a violet polyline with beads at the highlights.

| Meaning | Colour | Hex |
|---|---|---|
| Route (light mode) | violet | `#5B3DF5` |
| Route (dark mode / on dark surfaces) | violet | `#8C7BFF` |
| Bead: sights / photo spots | amber | `#E9A21B` |
| Bead: shops (independent) | teal | `#1C9E8B` |
| Bead: food | coral | `#E5532D` |
| Surface light | | `#F3F5F6` |
| Surface dark / ink | | `#18212C` |
| Ink (text on light) | | `#18212C` |
| Text on dark | | `#F3F5F6` |

The violet is deliberately not blue so the app does not read as a standard navigation app.
Do not use system blue for tint, links or buttons: set the app accent to the violet.

Rules for the route + beads on the map:
- Bead diameter is about 1.25 × the route stroke width.
- Each bead has a knockout ring in the **surface colour** (ring width is about 1/5 of the stroke width) so it reads as strung on the line. On a map, use the map background colour for the ring.
- Colour never carries meaning alone: pair bead colour with an icon or label in lists and callouts.
- Ink and violet text pairs: `#5B3DF5` on `#F3F5F6` and `#8C7BFF` on `#18212C` are both fine for large text and UI. Use ink for body copy.

## Typography

- Wordmark: **Instrument Sans SemiBold (600)**, sentence case: "Wander". Tracking −1.5 %.
- The logo files have the wordmark converted to outlines, so they need no font installed. Use the files; do not retype the wordmark.
- In-app text: use the system font (SF) for body and UI unless the design asks otherwise. If Instrument Sans is wanted in-app, get the static TTFs from Google Fonts (SIL OFL), add them to the target and to `UIAppFonts` in Info.plist.

## Files

```
AppIcon.appiconset/          drop straight into Assets.xcassets (Xcode 15+/16, single 1024 size, light + dark + tinted)
app-icon/png|svg/            same icons as loose files (1024 × 1024, square, no alpha, iOS applies the corner mask)
logo/svg|png/                horizontal logo (mark + wordmark) and mark-only
                             "on-light" = for #F3F5F6 / white surfaces, "on-dark" = for #18212C / black surfaces
                             Backgrounds are transparent; bead rings and wordmark colour follow the named surface.
tokens.json                  colours / type / route rules as data
swift/Brand.swift            Color tokens (light/dark adaptive)
swift/WanderMark.swift       the W mark as a SwiftUI view (Canvas), for splash / onboarding / empty states
```

## App icon

- 1024 × 1024 master, three appearances:
  - Light: surface `#F3F5F6`, route `#5B3DF5`, beads in the three colours.
  - Dark: surface `#18212C`, route `#8C7BFF`, beads in the three colours.
  - Tinted: black background, white route, beads in three grey levels (`#D4D4D4`, `#9E9E9E`, `#707070`) so they stay distinct once iOS applies the tint.
- Do not add rounded corners, text or shadows. iOS masks the icon.
- Legibility: the W and the three beads were checked down to 29 pt.

## Logo

- Horizontal lockup: mark on the left, wordmark on the right, wordmark cap height centred on the mark.
- Clear space: at least 25 % of the mark height on every side.
- Minimum size: mark-only is fine down to 24 pt tall; the horizontal logo should not go below 20 pt mark height (≈ 60 pt wide).
- Do not recolour the beads, do not put the light-surface files on dark backgrounds (the bead rings would show as light halos).
- Where the mark sits on a photo or a map, use the mark-only file for the matching surface and keep the surrounding area flat.

## Geometry (if you need to redraw the mark)

Coordinates in the 1024 icon space, route stroke 96, round caps and joins:

```
route:  M190 290 L350 740 L512 430 L674 740 L834 290
beads:  (350,740) amber   (512,430) teal   (674,740) coral      radius 78, knockout ring 18 (stroke in surface colour)
```
The tight mark box (beads and rings included) is x 140, y 240, 744 × 594.
