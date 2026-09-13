# ADR 0011 — The gallery: a lane drawn smaller, over the same ordinals

**Status:** Accepted · 2026-09-13
**Decides:** where the gallery layout collides with the rest of the strip —
docked lanes, gather, the memory policy, Esc — and how a tile is drawn at all.
**Evidence:** [Spike M5](../spikes/05-gallery-scale.md), and the work item
[`docs/work/gallery-layout.md`](../work/gallery-layout.md), whose decisions are
the owner's and are not re-opened here.

## Decision

The gallery is a second layout over the same lanes. **⌥⌘G** toggles it; the
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
Docked lanes survive the filter in the core (so ⌘G cannot destroy your music),
so they stay tiles here too. Leaving gather view has no key in the gallery —
see Esc below — and is still in the menu.

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
agent's prompt from its thumbnail is the use, and `ungather` holding Esc would
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
