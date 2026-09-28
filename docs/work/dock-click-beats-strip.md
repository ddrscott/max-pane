# A click on a docked lane goes to the dock, never to the strip lane under it

## Problem
Clicking a docked lane can scroll the strip to the lane underneath the dock instead of letting Scott use
the docked pane. The dock sits over the strip, so the strip's click handling appears to be seeing the
press first (or hit-testing through the dock) and treating it as a lane-changing click.

Likely suspects: `StripViewController.clickOnlyFocuses(paneId:)` / `revealWouldMove(laneId:)` (commit
a8e73d6) being asked about the strip lane under the pointer rather than the dock's pane; a strip-level
gesture/mouse monitor that runs before the dock's hit test; or `StripDock.swift` views that don't claim
`hitTest`/`acceptsFirstMouse` over their whole frame (gaps, headers, insets). Remember the known trap:
AppKit puts an `NSVisualEffectView` over ScrollView content-inset regions, which swallowed lane header
clicks once before.

## Acceptance Criteria
- A click anywhere on a docked lane (pane body, header, seams, edges, left or right dock) focuses that
  docked pane and never scrolls or refocuses the strip.
- Docks are "clicks that move nothing", so per the existing rule the click goes through to the pane:
  a terminal gets the press, a web page gets the click, a drag selects text.
- With the strip at rest and in the middle of a scroll/snap animation, the result is the same.
- Strip lanes outside the dock keep today's behaviour: a click that moves the strip still only focuses.
- Audit every mouse path while you're in there (local event monitors, gesture recognizers,
  `mouseDown` overrides, `hitTest` overrides, `acceptsFirstMouse`) and list in the commit what each one
  does over a dock. Fix any other place the strip can steal a dock's click (scroll wheel over a dock
  should also scroll the docked pane, not the strip).
- Tests: a synthesized click at a point over a docked lane, with a strip lane under it, focuses the
  dock pane and leaves `scroll_x` untouched; the same for mid-animation.

## Relevant Files
- swift/MaxPane/Sources/MaxPaneKit/Views/StripDock.swift
- swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift (`clickOnlyFocuses`, `revealWouldMove`)
- swift/MaxPane/Sources/MaxPaneKit/StripWindowController.swift

## Constraints
- Don't change the "a click that moves the strip only focuses" rule for strip lanes; Scott wants it.
- Focus changes animate per the no-instant-transitions rule.
- Workers must not launch, quit or replace the installed app.
