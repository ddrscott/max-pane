# In the gallery, ⌘[ ⌘] (and ⌘{ ⌘}) move the expanded tile to the neighbour

The owner (2026-09-23): *"When in gallery mode and a pane is expanded, using
`cmd-{` and `cmd-}` should auto contract and expand the next/previous lane so
we can quickly cycle through them with shortcuts."*

## What the keys are today

- ⌘[ / ⌘] are `focusLeft` / `focusRight` ("Focus Lane Left/Right",
  `Commands.swift:217`), walking the strip; in the gallery `moveFocus` moves
  focus between tiles but never changes which tile is expanded.
- ⌘{ / ⌘} are ⇧⌘[ / ⇧⌘], `focusUp` / `focusDown` ("Focus Pane Up/Down",
  `:219`), the pane above/below in a split lane.
- A tile expands on a double click or `expandTile(laneId:paneId:)`; one at a
  time; `collapseExpandedTile()` puts it back; ADR-0011 and its amendments.

## Acceptance Criteria

- **With a tile expanded in the gallery**, ⌘] collapses it and expands the next
  lane in strip order, ⌘[ the previous; focus follows to the newly expanded
  lane's focused (or first) pane. At the ends: stop (no wrap), the key does
  nothing and the tile stays; say so in the README. Docked lanes are tiles in
  the gallery (ADR-0011) and are in the cycle at their ordinal.
- **⌘{ / ⌘} cycle too**, so the owner's stated keys work: when the expanded
  lane has one pane, ⇧⌘[ / ⇧⌘] do exactly what ⌘[ / ⌘] do. When it is a split
  lane, they keep their meaning inside it (pane above/below) **until the edge**:
  ⇧⌘] on the bottom pane goes to the next lane, ⇧⌘[ on the top pane to the
  previous. That keeps every pane reachable and makes the ⇧ pair a strict
  superset of the plain pair for the common case. Document this rule in one
  sentence; if it proves confusing in the README's own telling, drop the split
  case and let the ⇧ pair cycle lanes unconditionally, and say which you chose.
- **With no tile expanded**, both pairs behave exactly as today.
- **Motion**: the old tile shrinks back into its slot and the new one grows out
  of its own, at once, with the existing tile animation
  (`layoutGallery(animated:)` / `animateTile`); a fast repeat of the key mid-
  animation turns round from where the tiles are drawn (the presentation-layer
  rule already in `layoutGallery`), never stacking or snapping.
- ⌘/ sheet: the two focus rows mention the gallery behaviour.
- Tests on the `MaximizeRig`-style strip: cycle forward and back across three
  lanes, the ends, a docked lane in the cycle, the split-lane rule for the ⇧
  pair, focus following, and no change with nothing expanded.
- README (the gallery section), CHANGELOG (Added), a line in ADR-0011's
  amendments.

## Constraints

- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it.
- No instant transitions.
