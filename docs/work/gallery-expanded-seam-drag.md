# Stacked panes resize by their seam in an expanded gallery tile

## Problem
On the strip, the seam between two stacked panes drags to change their heights
(`PaneSplit`, the grips in `LaneView`). In the gallery every handle is hidden
(`LaneView.thumbnailScale` → `grip.isHidden = isThumbnail`), and ADR-0011
records the reason: at a scale of 0.3 a 14 pt grip is four points square, and a
height chosen from a thumbnail is chosen without seeing what it does to the grid.

That reason does not hold for an **expanded** tile (ADR-0011, amended
2026-09-13): it is drawn at the lane's real size, or as close as the gallery's
height allows. The owner, 2026-09-16: *"I should be able to change (adjust the
heights) of stacked panes by dragging the separator in the same way as lanes
layout mode."*

## Acceptance Criteria
- In an expanded tile, the seam between stacked panes is grabbable and drags
  exactly as on the strip: same `PaneSplit` arithmetic, same hit slop, same
  cursor, same ledger write (`set_pane_heights` or whatever the strip's grip
  calls), same motion. The neighbouring pane gives way as it does on the strip.
- The heights the drag produces are the lane's real heights, so leaving the
  gallery shows the strip with the panes exactly where the drag left them, and
  a relaunch keeps them.
- Unexpanded tiles are unchanged: no grips, no seam drags. Putting a tile back
  hides the grips again; expanding another tile moves the grips with the
  expansion.
- When the expanded tile is clamped below real size (a lane taller than the
  gallery), the drag still works and maps pointer points through the tile's
  scale, so the seam follows the pointer rather than moving faster or slower
  than it. If the scale is under a threshold where the grip is smaller than a
  usable target (pick and record it; the strip's grip is the reference), keep
  it hidden and say so in the code comment.
- A terminal pane resized this way gets the same size treatment it gets from a
  strip drag (ADR-0007: the PTY is never resized; the lane is sized to the
  session — whatever the strip does today, the tile does).
- Amend ADR-0011: "tiles do not resize anything" becomes "unexpanded tiles do
  not resize anything; an expanded tile's seams behave as the strip's".
- Tests: a `LaneView` with two panes at a thumbnail scale hides its grips; the
  same view expanded shows them; a synthetic drag through the grip at a scale
  of 1 and at a clamped scale produces the heights the strip's arithmetic
  predicts; the render sheet for the gallery includes an expanded stacked tile
  with the seam visible, looked at in light and dark.

## Relevant Files
- `swift/MaxPane/Sources/MaxPaneKit/Views/LaneView.swift` (`thumbnailScale`, grips, `updateSizeSwitchVisibility`)
- `swift/MaxPane/Sources/MaxPaneKit/Views/PaneSplit.swift`
- `swift/MaxPane/Sources/MaxPaneKit/Views/GalleryLayout.swift` (`expanded`)
- `swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift` (`expandedLaneId`, the gallery hit-test order)
- `docs/decisions/0011-gallery-layout.md`

## Constraints
- The expanded tile is raised over its neighbours and hit-tested first; the
  grip's hit slop must not leak onto a covered neighbour.
- A double click on an expanded tile's header puts it back; a drag that starts
  on the seam must not be taken as a header drag (`PaneDrag`) or a double click.
- Motion rules: the seam moves with the pointer, and any settle at the end
  eases on `Motion.pane`. No instant jumps.
- Still no width handle and no size presets on tiles; this task is seams only.
