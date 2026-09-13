# A docked lane's page is laid out at the wrong width

## Problem

> "the right side dock doesn't resize the lane correctly. The webview should be
> expanded to fill up the space."

Screenshot: a Gmail lane docked on the right. The page inside is laid out wider
than the dock and runs off the right-hand edge of the window — Gmail's tab row
is cut mid-word (`Promot…`, `Soc`) and every message preview is truncated at the
window edge rather than wrapped to the column. The lane's own header renders
correctly across the dock's width, so it is the *page* that has the wrong size,
not the lane chrome.

**It does not correct itself.** The owner confirmed that dragging the dock's
inner edge and resizing the window both leave it wrong. That rules out a missing
layout pass — a fresh pass happens on both — and points at the pane being handed
a genuinely wrong width, not a stale one.

## Where to look

`StripViewController.layoutDocks()` sets the dock's lane view frame directly:

```swift
let frame = NSRect(x: x, y: 0, width: placement.width, height: view.bounds.height)
if laneView.frame != frame { laneView.frame = frame }
```

`placement.width` comes from `DockGeometry.resolve`, which clamps against the
viewport and degrades a dock to overlay when the window cannot afford it. Two
widths are therefore in play and they are not the same number:

- `lane.widthPt` — the lane's width **in the strip**, deliberately preserved so
  undocking gives it back at the width it was dragged to.
- `lane.dock?.widthPt` — the dock's own width, and then `placement.width` after
  clamping.

`LaneView` reads both, in two places:

- line ~160, in `init`: `frame.size.width = CGFloat(lane.widthPt)` — the strip
  width, at construction.
- line ~256, in `apply`: `desiredWidth = CGFloat(lane.dock?.widthPt ?? lane.widthPt)`
  — correctly dock-aware.

Suspects, in the order worth checking:

1. Something inside the lane sizes from `lane.widthPt` or from `desiredWidth`
   rather than from the lane view's actual `bounds`, so the pane is built at the
   strip width while the lane view is at the dock's — and the clamp in
   `DockGeometry.resolve` makes the two differ by exactly the amount clipped.
2. The pane container or the `WKWebView` is not tracking the lane's width.
   `WebPaneController.install` gives the web view `autoresizingMask =
   [.width, .height]` against its container; verify the container itself is
   actually resizing, and that nothing pinned it to a constant.
3. `LaneView.revealWidth` — the transition **mask**, which deliberately keeps the
   lane at its real width and clips. `nil` is the normal state. If a dock/undock
   transition leaves it set, the lane keeps a wider real width and is masked,
   which looks exactly like this. Check it is cleared when a lane lands in a dock.

Read commit `51b1ad0` first. The dock view work already hit one bug in this
family and its message describes it: constraint *constants* were being changed
from inside a layout pass, which schedules no further pass, and the "only write
it if it changed" guard then made the omission permanent — inset mode drew a
dock over a full-width strip, which looks exactly like inset mode working.

## Acceptance criteria

- A web page in a docked lane lays out at the dock's width: no horizontal
  clipping, and the page reflows as a narrow column the way it does in a strip
  lane of the same width.
- True on both sides, in both modes (inset and overlay).
- True after dragging the dock's inner edge — the page reflows live, or at the
  drop, but ends correct.
- True after a restart with a dock restored, and after the window is resized
  narrow enough that `DockGeometry` degrades an inset dock to overlay.
- True for a terminal pane too: a docked terminal's grid should match the dock's
  width, and per ADR-0007 the far end is told at the drop, not per frame.
- Undocking still returns the lane to its **strip** width, not the dock's — the
  two numbers stay separate, which is what `desiredWidth` is for.
- A test pins whatever the root cause turns out to be. The geometry in
  `DockGeometry` is already unit-tested; if the bug is in the pane layout, that
  arithmetic wants extracting the way `LaneSnap` and `PaneSplit` were.

## Relevant files

- `swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift` — `layoutDocks()`
- `swift/MaxPane/Sources/MaxPaneKit/Views/StripDock.swift` — `DockGeometry.resolve`
- `swift/MaxPane/Sources/MaxPaneKit/Views/LaneView.swift` — `init`, `apply`, `revealWidth`, `layout()`
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift` — `install`

## Constraints

- Reproduce it before changing anything. Dock a real page — Gmail or any site
  with a wide layout — to the right, in a throwaway profile, and see it.
- Do not fix it by making `lane.widthPt` follow the dock. Those are two durable
  numbers on purpose: the owner drags lane widths deliberately and undocking
  must give the lane back at the width he chose in the strip.
- The transition mask exists for a reason spelled out at `LaneView.revealWidth`:
  a live pane must not be walked to zero width, because Ghostty tears down a
  surface at zero and re-deriving a grid mid-animation is ADR-0007's forbidden
  move on a session with a phone attached. If the mask is implicated, clear it
  correctly — do not remove it.
