# ADR 0047 — The window clamps, the ledger keeps

**Status:** Accepted · 2026-09-29

## What happened

A lane kept its stored width however narrow the window got. On a small window,
a half-screen split or beside an open dock, an `m` or `xl` lane ran off the
edge, so part of the terminal or page was always one scroll away. The owner
wanted the responsive-layout pattern: a lane that does not fit shrinks to the
space there is, and goes back to its own size by itself when the space comes
back.

## Decision

**A lane's stored width is a maximum. The strip draws it at
`min(its own width, the room)`, and never writes the smaller number anywhere.**

- **The room** is the strip's visible width, with any dock already off it (the
  one place docks are subtracted, `layoutDocks`), less a `lane_peek_pt` sliver
  each side when there are neighbours. The slivers keep the carousel working:
  a clamped lane is narrower than the window, so `StripReveal.isCarousel`
  holds, focus centres it, and a click on either sliver pages one lane. A lane
  alone gets the whole width. The room never goes below 160 pt
  (`LaneFit.floorPt`), because a lane with no columns is worse than a scroll.
- **One list.** `StripViewController.stripLanes` is the ledger's strip lanes
  run through `LaneFit.fit`, and every layout, scroll, snap, hit-test,
  materialisation and gallery question in the controller asks it instead of
  `store.stripLanes`. There is no second idea of how wide a lane is to fall out
  of step. `fit` keeps ids, order and count, so indices still line up with the
  ledger's list (the eviction invariant in `StripStore.stripLanes`).
- **Never written.** `width_pt`, span, zoom and the lit `s | m | xl` all stay
  the ledger's, so ⌘\\ still lights the stored size, and a relaunch, a wider
  window or a closed dock brings the real size back with nothing to remember.
  The core model is untouched.
- **What writes a width starts from the screen.** An edge drag starts from the
  width on screen and drops a real width, and ⌃⌘- narrows from the width on
  screen, so neither needs presses that change nothing visible. A size preset
  eases from and to the widths it is drawn at.
- **Motion.** A change of room that arrives on its own (a dock arriving, a
  second lane bringing the peeks) eases on `Motion.lane`. One that arrives
  within 0.1 s of the last one, or during a window's live resize, is part of
  something moving (an edge drag, the sidebar sliding) and is tracked
  directly. A column easing behind the pointer lags it. Reduce Motion lands at
  once.
- **Terminals** get the new width through the same live-resize hold a seam
  drag uses: the grid follows the view, and the far end hears one size once the
  widths have been still for `TerminalPaneController.settleDelay`. A window
  drag does not reshape the PTY sixty times a second.
- **Docks** already follow the same rule against the window
  (`DockGeometry.resolve` always leaves the strip `lane_min_pt`) and are not
  clamped again.

## Rejected

- **Clamping in the core** (`width_pt` capped to the window). The window is a
  shell fact, the ledger is shared with every client, and a clamp written down
  is a size lost the first time the window is small.
- **Scaling the lane down** the way a gallery tile does. That keeps the
  columns but shrinks the text, and the point is to read the whole lane at its
  real size.
- **No peek.** A lane exactly as wide as the window leaves nothing on either
  side to click, which breaks the carousel's click-a-sliver paging.
