# The dock chords in the gallery either work or refuse, but never write state silently

From [`docs/critiques/docking.md`](../critiques/docking.md) § 4.

## The short version

`canPerform` enables Dock Lane Left/Right on any focused lane, gallery
included. The press writes `lane.dock` to the ledger and **nothing on screen
changes**, because `layoutDocks` has already returned. ⌃⌘= and ⌃⌘- resize a
dock nobody can see; ⌥⌘[ focuses a tile and scrolls nothing. A key that writes
persistent state with no feedback is worse than a key that refuses.

## Notes beyond the finding

- **If `docking-gallery-walls.md` has already landed, this task is moot**: the
  chords become real there. Check first, and if so reject this item (`- [~]`)
  with that as the reason rather than building a refusal for something that
  works.
- Otherwise: `canPerform` refuses the four dock commands while `isGallery`,
  with `unavailable()` text *"not in the gallery"* — the wording already used
  for `renameLane`. A refused command greys in the menu, in ⌘/ and in ⌘E, which
  is the feedback that is missing today.
- Either way, a lane that was docked before ⌘G must keep its `dock` value; this
  is about the keys, not about undocking anything.

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

