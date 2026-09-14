# Carousel: when fewer than three lanes fit, the focused lane is centred

## Problem

On a narrow viewport (a small window, a docked lane eating the strip, or an
xl lane) only one or two lanes fit across. Today focus does not move the
strip, and the snap settles the strip on a lane edge, so the focused lane can
sit hard against one side with nothing to click on that side. Paging through
many lanes then means the sidebar, ⌘[ / ⌘], or dragging.

Wanted: a carousel. Whenever fewer than three lanes fit in the visible strip,
the focused lane sits in the centre of the available space with both
neighbours peeking by equal partial widths. Clicking the sliver left or right
of the centre lane focuses that lane, which recentres it, which reveals the
next sliver. Click, click, click through the whole strip.

## Acceptance criteria

- **Trigger: any focus change.** A mouse click on a pane, ⌘[ / ⌘], the sidebar,
  ⌘P, ⌘O and a new lane arriving all land focus, and every one of them
  recentres when the rule applies. Reuse `reveal(laneId:flash:)` /
  `StripReveal.centred` rather than a second scroll path; the focus setter at
  `StripViewController.focus(_:)` is the one place to hook.
- **Rule: fewer than three lanes fit.** "Fit" is measured against the visible
  strip width (`viewport.width`, the part not covered by an inset dock),
  against the actual widths of the lanes near the focused one (s / m / xl
  differ). When three or more fit, nothing changes: the existing snap and
  peek behaviour stay exactly as they are, and the tests that hold them
  keep passing.
- **Exact centre.** The focused lane's centre is the viewport's centre, even
  with two full lanes fitting. The first and last lanes clamp to the strip
  edges as `StripReveal` already does, so there is no blank space past the
  end.
- **The snap agrees.** `LaneSnap` must not fight the centring: after a
  centring reveal, a snap on scroll-end must settle on the centred position,
  not pull the lane back to an edge. Under the rule, snapping a user's own
  drag should also settle on "nearest lane centred" so a flick pages one
  lane at a time.
- **Focus by click on a peeking sliver works.** The partial neighbour is
  clickable and clicking it focuses that pane (it already does through
  `onFocusPane`); confirm nothing in the lane header or the masked transition
  swallows the click.
- **Motion.** Same 0.22 s ease-out as every other strip move; instant under
  Reduce Motion. A focus change that is already centred does not scroll.
- **Tests.** Pure-function tests on `StripReveal` / `LaneSnap` for: one lane
  fits, two fit, three fit (unchanged), mixed s/m/xl widths, first and last
  lane clamping, and a dock inset reducing the viewport below the threshold.
  Extend `StripRevealTests` and `SnapAndConfigTests` rather than adding a
  new file if they fit.

## Relevant files

- `swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift` —
  `focus(_:)` ~2617, `reveal(laneId:flash:)` ~2455, `scroll(to:revealing:flash:)`,
  `snapToNearestLane()` ~2370, `LaneSnap` ~2766
- `swift/MaxPane/Sources/MaxPaneKit/Views/StripMotion.swift` — `StripReveal.centred` ~296
- `swift/MaxPane/Tests/MaxPaneKitTests/StripRevealTests.swift`
- `swift/MaxPane/Tests/MaxPaneKitTests/SnapAndConfigTests.swift`
- `docs/PRDSwift.md` §7.5 (search-to-scroll) for the existing centring contract

## Constraints

- Gallery layout and docked lanes are untouched: `reveal` already returns
  early for both, keep that.
- No new config key unless the threshold has to be tuned; three is the rule.
- Do not change behaviour when three or more lanes fit. That is the common
  case on his display and it is what every existing snap test pins.
- Do not launch the running app to verify; render sheets or the pure tests
  are the proof, and note what was not driven.
