# The LANES | GALLERY switch shows icons, not words

The owner: *"Lanes and Gallery should use icons to toggle the view layout. No
need to spell it out."*

## Problem

The strip toolbar's layout switch is two text buttons, `LANES` and `GALLERY`
(`Views/StripToolbar.swift`). It is the widest thing in the row and says in two
words what two small pictures say at a glance.

## Acceptance Criteria

- Two icon-only buttons, still one switch sharing a border: **Lanes** is Lucide
  `columns-3` (portrait columns side by side — what the strip is) and **Gallery**
  is Lucide `layout-grid`. If either reads wrongly at 13–14 pt in the render sheet,
  pick the nearest Lucide alternative and say why.
- The lit half follows the layout exactly as today (`setLayout(isGallery:)`), and
  clicking either still asks for that layout; ⌘G is unchanged.
- The words move out of the row, not out of the app: tooltips `Lanes (⌘G)` and
  `Gallery (⌘G)`, and each button has an accessibility label, since it has no
  visible text.
- Buttons are square-ish (about 28 × 20 pt) rather than sized to words, and the
  find button and session count shift left accordingly.
- Colours come from `Theme` only. The lit state uses whatever accent the
  green-palette task (queued just before this) settles on — no colour hardcoded here.
- Icons are added through `scripts/gen-icons.py`, which generates
  `Views/LucideIcons.swift` — never by editing that file by hand — and the existing
  "every embedded icon decodes and draws" test covers the two new ones.
- `StripToolbarTests` updated (no button text to assert; assert icon, tooltip and
  accessibility label instead), and the `strip-toolbar-*` render sheets
  regenerated and looked at in both layouts.
- README's toolbar paragraph describes the icons rather than the words.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Views/StripToolbar.swift`
- `swift/MaxPane/Sources/MaxPaneKit/Views/SidebarRowViews.swift` — `SidebarButton`,
  which already draws an icon alone when its text is empty.
- `scripts/gen-icons.py`, `swift/MaxPane/Sources/MaxPaneKit/Views/LucideIcons.swift`
- `swift/MaxPane/Tests/MaxPaneKitTests/StripToolbarTests.swift`

## Constraints

- Square corners; no rounded segmented control.
- Do not change what the switch does, only how it is drawn.
