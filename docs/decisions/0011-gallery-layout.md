# ADR 0011 — The gallery: a lane drawn smaller, over the same ordinals

**Status:** Accepted · 2026-09-13
**Decides:** where the gallery layout collides with the rest of the strip —
docked lanes, gather, the memory policy, Esc — and how a tile is drawn at all.
**Evidence:** [Spike M5](../spikes/05-gallery-scale.md), and the work item
[`docs/work/gallery-layout.md`](../work/gallery-layout.md), whose decisions are
the owner's and are not re-opened here.

## Decision

The gallery is a second layout over the same lanes. **⌘G** toggles it; the
choice is the `strip_layout` key in `app_state`, committed before a view moves,
and it is the only thing a switch writes.

A tile is the lane's own `LaneView` — the same object, with the same Ghostty
surface and `WKWebView` inside — reparented into a view whose **bounds are the
lane's real size and whose frame is its tile**. One scale for every tile, the
largest that fits every lane on screen, capped at 1.

## Why a transform, and not a smaller backing

Spike M5 measured both. It is not close:

| | Grid at scales 0.75 → 0.25, lane at 80×58 | Surface under a 12-tile gallery (2×) | Streaming CPU, 12 tiles |
|---|---|---|---|
| **Transform** (bounds kept, frame shrunk) | **80×58 at every scale, 1× and 2×; zero resize reports** | 1312×2000 each, 120 MB | 7.5 cores |
| Smaller backing (fewer pixels per point) | 1×: 80×57, 76×59, 79×54, 70×55, 83×56, 68×53, 76×60 — 2×: six of seven differ | 524×800 each, 19.5 MB | 7.9 cores |

Ghostty's cells are whole pixels, so a surface given fewer of them re-derives
its grid, and a grid that changes is a `RESIZE` for the phone too (ADR-0007).
That alone rules the smaller backing out; the CPU column shows it would not even
have bought anything, because a streaming terminal's cost is the terminal and
not the pixels. For a web page the same holds for a different reason: `pageZoom`
and `magnification` both widened the layout viewport (`innerWidth` 656 → 1312
at half size), where a transform left it at 656 with `devicePixelRatio` 2.

What the transform costs is sharpness below half a device pixel per lane point,
and that is what the minification filter is for — see *Consequences*.

## Where it collides with the rest of the strip

### Docked lanes are ordinary tiles

At their ordinal, with the width they have at the wall and the window's height,
so nothing inside is resized. A dock is a promise about *the strip's* edges; the
gallery has no edges to hold anything at. They are still never evicted and
never unparented — that part of docking is about the page, not the wall — and
they go back to the wall when the gallery closes.

### Gather narrows the gallery to its tag

The gallery draws `state.lanes`, which a gather filter has already narrowed.
Docked lanes survive the filter in the core (so a gather cannot destroy your
music), so they stay tiles here too.

**Amended 2026-09-13.** Gather and Leave Gather now ship with no key. The
owner found gather too surprising to be one keystroke — or one double click on a
header, which also entered it — away, and it was the precondition for the sidebar
attaching one session five times. ⌘G is the gallery's, both ways, because
⌥⌘G is where Google Drive lives. Reaching this section now means someone bound
gather in `keys` on purpose.

### Memory: distance is measured from the lane you are in

The eviction policy ranks pages by distance from the viewport. In the gallery
every lane is on screen, and passing that through literally is actively
harmful: distance 0 everywhere means **every evicted page rehydrates at once on
entry**, and — since only an off-screen page is a candidate — **no page can ever
be evicted**, so nothing stops WebKit walking past the hard mark.

So the gallery hands the policy a one-lane viewport at the focused lane (or the
most recently focused strip lane, with focus in a dock). Consequences, all from
the existing policy rather than a second one:

- Pages within `rehydrateDistance` of the focused lane come back; the rest show
  their placeholder snapshot until one is clicked, which focuses it.
- Under pressure the victims are the policy's usual deterministic order —
  furthest from the focused lane first, then least recently focused — and the
  focused lane is never a candidate. This is Relay TTY's lesson from
  `webgl-budget.ts`: budget live renderers deterministically, never let the
  platform pick victims at random.
- `Unparent` is ignored. It exists for a page scrolled out of sight, and an
  unparented tile is a blank tile.

### Esc and Return belong to the tile

In the gallery the window's key monitor matches no chord without ⌘. Answering an
agent's prompt from its thumbnail is the use, and `ungather` bound to Esc would
take exactly the key that answers it.

### Tiles do not edit the strip

No width handle, no pane grips, no seam drags, no header reorder: the gallery
writes the layout key and focus and nothing else. The header's ⋯ menu still
works, because an explicit command is not the gallery reordering anything.

### Clicks

A single click on a tile focuses the pane under it, through the same click
monitor as the strip — AppKit converts through the tile's transform, so a click
lands on the cell under the pointer. A double click is taken from the tile
(a word selection in a thumbnail is not wanted) and leaves for Lanes at that
lane, which is what ⌘P does. The session sidebar follows the same two gestures
in the gallery and keeps its behaviour on the strip.

## Consequences

- **Minification filter by device pixels per lane point.** Bilinear above 0.5,
  trilinear at or below. M5: on a 2× panel bilinear was closer to a Lanczos
  downscale at every scale down to 0.33 (mean error 5.8 against trilinear's
  6.8); at 1× and a scale of 0.4 bilinear's error was 9.0 against trilinear's
  5.8. Applied to terminal surfaces; a `WKWebView`'s layers are WebKit's.
- **Auto Layout rounds to the tile's pixels, and terminals hold their size
  against it.** AppKit rounds every constrained frame to device pixels in the
  window, internally — `backingAlignedRect` is never consulted, which was
  checked — so inside a tile a pane can land a point off its strip size (483 →
  482.5 pt, measured at 0.4 on 1×). The spike's terminal had a fixed frame and
  could not show this. A point can be a column, so a terminal in a tile leaves
  its edge constraints and keeps its strip size, adopting a new one only when the
  space around it moves by more than one tile pixel plus one strip pixel
  (`GalleryLayout.heldSize`). A `WKWebView` is left to the rounding: a page may
  see its width move by that much, and no PTY is involved.
- **The focus outline is drawn thicker in lane points**, by 1/scale, so it lands
  on screen at the 2 pt it has on the strip rather than sub-pixel.
- **Every visible terminal renders.** Idle surfaces cost ~0.04 cores for twelve;
  twelve streaming ~30 lines a second each cost ~7 cores in the spike process,
  at any scale. The strip only ever renders what is on screen, so the gallery can
  cost several times the strip while many agents are printing at once.

## Rejected

- **A smaller backing** — measured above.
- **Re-flowed grids** (each tile a small terminal of its own shape) — the
  owner's decision, and a `RESIZE` storm on every other client.
- **All lanes treated as visible for eviction** — above; it disables eviction.
- **Docks kept at the wall in the gallery** — the gallery would lose the edges'
  width to lanes it is not laying out, and a docked lane would be the one lane
  not on the grid.

## What would make us revisit

- CPU complaints with many agents streaming at once: budget live terminal
  surfaces the way Relay TTY budgets WebGL contexts (top-N by recent output,
  focused pinned, hysteresis), pausing the rest with `setSurfaceVisible(false)`.
- A 1× panel at small scales looking worse than the spike's in-process
  `CARenderer` numbers suggest — WindowServer composites, and it may filter
  differently.

### Amended 2026-09-13: double click expands in place

The owner, after using it: *"When expanding a gallery thumbnail it should expand
in place. not go to lanes view so it behaves like RelayTTY."* A double click on a
tile — or on its session row while the gallery is up — no longer switches to the
strip. It expands the tile over its own slot at the lane's real size, clamped
inside the gallery (`GalleryLayout.expanded`), and raises it so AppKit's hit
testing hands clicks to it rather than to the neighbour it covers. A double click
on its header, a click on the gallery between tiles, or expanding another tile
puts it back; inside an expanded tile's pane a double click is the program's
again. Which tile is expanded is held in memory only. Because a tile's bounds are
always the lane's own size, expanding changes a frame and resizes nothing.

### Amended 2026-09-14: tiles rearrange the strip

The owner: *"The dragging should also be available in gallery mode which is
arguably more important since gallery lets us see all the lanes at once."* The
section above — *Tiles do not edit the strip* — is narrowed to **tiles do not
resize anything**.

A tile's header drags its lane, through the same `PaneDrag.drop` the strip uses:
each tile is a `LaneBox` laid out at the lane's real size and scaled into the
tile's frame, which is the transform AppKit is already applying to the views. The
top or bottom of a pane stacks the lane there (`move_lane_into`); the left or
right moves it beside that lane (`move_lane`). One write per drag, as on the
strip.

What did not change, and why:

- **No width handle, no seam drags, no size presets.** A tile is the lane drawn
  smaller; a width or a height set from a thumbnail is a number chosen without
  seeing what it does to the grid inside.
- **No pane grips.** At a gallery scale of 0.3 a 14 pt grip is four points
  square. A stacked pane is taken out of its lane on the strip; in the gallery
  the lane moves as one.
- **The space between tiles is not a target.** On the strip, past the last lane
  is where a new column goes; in a wrapped grid the gap between two tiles is
  between two rows as often as between two lanes, and a target that means
  different things in different gaps is not one.
- **Docked tiles are targets and sources like any other**, at their ordinal. A
  dock dropped beside a lane leaves its edge — `move_lane` now clears the dock,
  which is `move_pane_to_new_lane`'s existing rule for a lane of one — and a dock
  dropped into a stack is gone with its lane.

### Amended 2026-09-16: an expanded tile's seams are the strip's

The owner: *"I should be able to change (adjust the heights) of stacked panes
by dragging the separator in the same way as lanes layout mode."* The rule
above — **tiles do not resize anything** — is narrowed to **unexpanded tiles do
not resize anything; an expanded tile's seams behave as the strip's**.

The reason a tile's seams were inert was stated for a thumbnail: at a scale of
0.3 a 14 pt grip is four points square, and a height chosen from a thumbnail is
chosen without seeing what it does to the grid. Neither holds for the expanded
tile (amended 2026-09-13), which is the lane at its real size, or as near it as
the gallery's height allows. So in the expanded tile the seam between two
stacked panes drags exactly as on the strip — the same `PaneSplit` arithmetic,
the same grab band, the same cursor, the same `set_pane_heights` write once on
the drop, the same live-resize word to each terminal (ADR-0007: the lane is
sized to the session, never the PTY to the lane) — and the pane grips come back
with it. The heights it produces are the lane's real heights: leaving the
gallery shows the strip with the panes where the drag left them, and a relaunch
keeps them.

What made it correct rather than merely enabled:

- **The pointer is measured in lane points, not window points.** A tile is
  drawn through a scale, and a seam that took its delta from the window moved
  slower than the pointer in any clamped tile. `PaneDividerView` now converts
  the pointer into the lane's own coordinates through the same transform AppKit
  hit-tests with, which is the window's y exactly on the strip and the scaled y
  in a tile.
- **A threshold, recorded in `PaneSplit.minimumLiveScale` (0.5).** An expanded
  tile is only smaller than real size when its lane is taller than the gallery.
  At 0.5 the 11 pt grab band is 5.5 pt on screen — still wider than the 2 pt
  lit rule that advertises it — and the 14 pt grip is 7 pt. Below that the band
  is thinner than the seam it draws on the strip, and the handles stay hidden
  rather than flicker.
- **An inert seam is not there to the pointer.** On an unexpanded tile the seam
  is still drawn, because a split lane's tile keeps its proportions, but it
  refuses the hit, takes no hover and sets no cursor, so a resize cursor never
  appears over a seam that will not move. Before this the cursor changed and
  the drag did nothing.
- **A press on a live seam is a seam, not the tile.** A drag released and
  re-grabbed inside the double-click interval must move the seam again, not
  put the tile back; the click monitor treats a live seam as pane content.

What did not change: no width handle and no size presets on any tile, and an
unexpanded tile's seams and grips are exactly as inert as before. The 2026-09-14
amendment's *no pane grips* and *no seam drags* now read with "on an unexpanded
tile" in front of them.
