# The gallery gets walls: a docked lane stays pinned there too

From [`docs/critiques/docking.md`](../critiques/docking.md) § 1 (with § 2 and § 6 folded in, which the critic says shrink or dissolve once this exists). Read the whole critique first: §§ 1-5 establish what docking does in each layout, with citations, and the finding carries the acceptance criteria.

## The short version

⌘G throws the pin away. `layoutDocks` returns before placing any wall when
`isGallery`, and `syncGallery` lays every lane out flat, so the lane he docked
to keep readable becomes an ordinary tile among twenty. ADR-0011 rejected walls
in the gallery deliberately, on the grounds that the grid would lose the edges'
width. That reason is the price of docking, which is knowingly paid on the
strip, and the owner's sentence says he wants to pay it in both layouts.

## Notes beyond the finding

- Amends **ADR-0011** (docked lanes are ordinary tiles; the rejection of walls)
  and **ADR-0019** (the maximize viewport is the whole gallery — with walls it
  is the gallery less its docks, exactly as the strip's viewport is narrowed).
  Write the amendment into both; both are warranted.
- § 2 of the critique ("the gallery holds exactly one readable lane") is the
  same complaint seen from the other side and should not need its own work: a
  wall is a second readable lane that no keystroke can take away.
- § 6 (persisting `expandedLaneId`) becomes optional once a wall exists, since
  the durable thing is then `lane.dock`, which is already a ledger column. Say
  whether you did it; declining it is a fine answer.
- The ledger needs nothing new. `lane.dock` is already the truth in both
  layouts; only the drawing differs.
- Entering and leaving the gallery should move a docked lane **not at all**:
  ADR-0011's 2026-09-17 amendment already says a docked lane "comes from its
  wall", and with a wall on both sides it simply stays.

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

