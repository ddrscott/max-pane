# A lane wider than the viewport fits it, and springs back when there's room

## Problem
In lane mode a lane keeps its stored width (`width_pt` × span, the s/m/xl presets or a drag) no matter
how narrow the window gets. On a small window, a half-screen split, or with a dock open, an `m` or `xl`
lane runs off the edge, so Scott can't see the whole terminal or page without scrolling the strip. He
wants the responsive-layout pattern: a lane that doesn't fit shrinks to the space that's there, and goes
back to its own size by itself when the space comes back.

## Rule
- **Displayed width = min(the lane's own width, the room there is).** "The room there is" is the strip's
  visible width minus any docks, minus the carousel's peek slivers on each side so the neighbouring lanes
  stay visible and clickable (see `StripReveal.isCarousel` and the carousel-centre task).
- It's a **display-only clamp.** Never written to the ledger. `width_pt`, span, zoom and the lit ⌘\ size
  are unchanged, so a relaunch, a wider window, or closing a dock brings the real size back with no
  memory needed.
- Applies to every lane, focused or not, strip lanes and the expanded gallery tile. A dock follows the
  same rule against the window, but always leaves the strip at least `lane_min_pt`.
- A lane already narrower than the room is untouched. Nothing ever grows past its own width.
- A split lane's panes all take the clamped width. Seams and heights are unchanged.

## Acceptance Criteria
- Shrink the window below an `m` lane's width → the lane is exactly as wide as the room, with no
  horizontal overflow; widen it again → it eases back to 656 pt (or whatever its own width is).
- An `xl` lane in a window that fits one `m` → fits the room; with more room → grows back to xl.
- Opening/closing a dock or the sidebar reclamps the same way.
- The lit ⌘\ size doesn't change while clamped; ⌘\ still sets the stored size (and the display clamps it).
- A terminal gets its new columns once the width settles (reuse the live-resize/settle path so a window
  drag doesn't spam the PTY), and reflows back when it widens. A web page just reflows.
- Transitions ease on the strip's `Motion.lane` timing; a live window drag tracks the pointer
  directly (no lag behind it); Reduce Motion lands at once.
- Dragging a lane's edge while clamped: the drag starts from what's on screen and writes a real width.
- Tests: layout math for the clamp (with docks, sidebar, carousel peeks, span 2); the ledger never sees
  the clamped width; widening restores the stored width.
- README (Lane sizes section: say the sizes are a maximum the window may clamp), CHANGELOG, and an ADR
  for "the window clamps, the ledger keeps".

## Relevant Files
- swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift (~845 width change, ~1545 layout,
  ~1976 lane size, ~2195)
- StripReveal / carousel code, StripDock.swift
- crates/laned-core/src/model.rs (`width_pt` — read only; don't change the model)

## Constraints
- No instant jumps (Motion.lane / pane, reduce-motion aware).
- Don't write the clamp to the ledger or the session's stored size.
- Don't break the carousel's "a click on a peeking neighbour pages one lane" behaviour.
- Workers must not launch, quit or replace the installed app.
