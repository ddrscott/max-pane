# The traffic lights sit on top of the sidebar's + NEW button

## Problem

> "when not in full screen the 'new' button is obscured by the Mac window
> management buttons"

`StripWindowController` builds the window with `titlebarAppearsTransparent`,
`titleVisibility = .hidden` and `.fullSizeContentView`, so content runs to the
top of the frame. That is right — the strip is the interface and a title bar
full of nothing would be 28pt of waste. But windowed, macOS still draws the
close/minimise/zoom buttons over that content at the top left, and the first
thing there is the sidebar's `+ NEW`.

Fullscreen hides the traffic lights, which is why this only shows up windowed —
and why it went unnoticed: the app runs fullscreen by default and every agent
test instance runs `MAXPANE_WINDOWED=1` with nobody looking at the corner.

## The second half, which is easy to miss

The sidebar can now be collapsed (the footer's `◧` toggle, or ⌘B). **With it
collapsed the strip becomes the leftmost thing**, so the traffic lights land on
the first lane's header instead — its focus dot, its title, and the `⋯` menu.
Fixing only the sidebar moves the bug rather than removing it.

So whatever reserves the space has to reserve it from **whatever is currently at
the window's top-left**, in all four combinations: windowed or fullscreen,
sidebar open or collapsed.

## What to use

`NSWindow.contentLayoutGuide` is the supported answer — it is the region not
covered by the title bar, and it is correct in both fullscreen and windowed
without arithmetic. `contentLayoutRect` is the frame equivalent. A hardcoded
28pt inset applied unconditionally would leave a dead band across the top in
fullscreen, where there is nothing to avoid.

If a constraint against the layout guide is awkward given that this file
frame-positions most things deliberately (see ADR-0004 and the comments in
`StripViewController` about why), then observe the transitions instead —
`NSWindowDelegate.windowWillEnterFullScreen` / `windowWillExitFullScreen`, plus
the sidebar's own collapse — and recompute. Say which you chose and why.

## Acceptance criteria

- Windowed, sidebar open: `+ NEW` and the sort controls beside it are fully
  visible and clickable, with the traffic lights clear of them.
- Windowed, sidebar collapsed: the first lane's header is fully visible —
  its dot, title and `⋯` all reachable.
- Fullscreen, either way: no reserved band, no wasted vertical space. The strip
  goes to the top of the screen as it does now.
- Toggling fullscreen, and toggling the sidebar, both update it live rather than
  needing a relaunch.
- Screenshots of all four states, looked at, with the traffic-light area checked
  rather than assumed.

## Relevant files

- `swift/MaxPane/Sources/MaxPaneKit/StripWindowController.swift` — the window's
  style mask and title bar configuration, the split view, the sidebar item
- `swift/MaxPane/Sources/MaxPaneKit/Views/SidebarViewController.swift` — the
  `+ NEW` row
- `swift/MaxPane/Sources/MaxPaneKit/Views/LaneView.swift` — the lane header, for
  the collapsed-sidebar case

## Constraints

- Do not solve it by putting the title bar back. The whole window design is that
  the strip is the interface; §5.2 wants it fullscreen with the menu bar hidden.
- Do not solve it by moving `+ NEW` somewhere else. It is where it is because it
  is the first thing in the sidebar, and the collapsed case proves the problem is
  the corner, not the button.
- The app launches fullscreen by default and test instances run
  `MAXPANE_WINDOWED=1`; check both, because the bug exists only in one and the
  waste would exist only in the other.
