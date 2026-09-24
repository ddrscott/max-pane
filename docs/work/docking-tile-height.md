# A docked tile is laid out at the wrong height and hangs below its row

From [`docs/critiques/docking.md`](../critiques/docking.md) § 5.

## The short version

`realSize(of:)` gives a docked lane `view.bounds.height` while every other tile
gets `galleryStripHeight`, which is the clip view, less the toolbar and the
status bar. `layoutGallery` then sizes the frame against a slot laid out at the
shorter height, so a docked tile hangs below its grid row and overlaps its
neighbours. This contradicts ADR-0011's own "nothing inside is resized".

## Notes beyond the finding

- In the gallery a docked lane's tile takes `galleryStripHeight` like every
  other lane, and its own strip `width_pt` rather than the dock width, so
  docking does not change a lane's shape in a layout that has no wall.
- **Fix it whether or not `docking-gallery-walls.md` lands.** With a wall the
  docked lane is not in the grid at all and this is moot; without one it is a
  visible defect today. If the walls task has already landed, verify the defect
  is genuinely gone and reject this item (`- [~]`) saying so, rather than
  changing code that no longer runs.
- A render sheet of the gallery with a docked lane, before and after, looked at.

## Constraints

- The owner's sentence is the spec: *"The purpose of docking is to pin one or
  more lanes in expanded mode so I can keep them readable as I navigate some
  other lanes temporarily."* Where an ADR disagrees with it, the ADR is what
  changes, and the amendment says so.
- Identity and motion rules as ever: greens for state, Signal Orange only for
  DONE, square corners, no instant transitions (`Motion.*`, Reduce Motion lands
  at once).
- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it. The orchestrator installs.
- Never capture `self` weakly in a callback on an object nobody else holds.

