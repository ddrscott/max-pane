# ADR 0019 — A maximized pane is lifted over the strip; the lane never widens

**Status:** Accepted · 2026-09-17
**Decides:** how ⇧⌘↩ (Maximize Pane / Restore Pane) shows a pane larger than any
lane without breaking *"a lane is a portrait-bounded column; the lane never
widens past its max"*, and — since this is the third time a pane is shown larger
than its lane — the rule for when that is allowed at all.
**Evidence:** the work item [`docs/work/maximize-pane.md`](../work/maximize-pane.md);
`MaximizePaneTests.swift` (a real `StripViewController` over a real ledger, and a
real Ghostty surface with a recording attachment); `WebMaximizeTests.swift` (a
real `WKWebView`).

The owner was not there to ask when this was built. The work item recorded three
readings of his request as assumptions. All three were kept, and none was found
wrong by the code; they are restated under *Assumptions* so he can overrule one
in a sentence.

## The rule, written once

A pane may be shown larger than its lane when all three hold:

1. **The lane's own geometry does not change.** Not its width, its span, its
   slot in the row, its panes' height weights or the strip's scroll offset.
   Whatever is drawn larger is drawn *somewhere else*, or under a transform.
2. **Nothing durable is written.** It is a way of looking, not a fact about the
   strip. A relaunch, or a `kill -9`, comes back without it.
3. **It ends by itself when the thing it was showing moves.** Nothing is left
   floating over a strip that has changed under it.

The three cases, and how each satisfies it:

| | what grows | where it is drawn | what ends it |
|---|---|---|---|
| Gallery tile expanded in place (ADR-0011) | a lane | its own tile, under a bounds-versus-frame scale, raised over the grid | another tile expanding, a click on the grid, leaving the gallery |
| A page's full screen (ADR-0014) | an element of a page | inside the pane's own web view, which takes the bars' room | the page, Esc, a navigation |
| **Maximize Pane (this ADR)** | one pane | an overlay over the strip's visible window | the same key, the chip, or `MaximizeRule` |

`LaneSizePreset` is deliberately not on this list and was not touched: `xl` *is*
a lane width, written to the ledger, bounded by the lane's maximum. Maximize is
not a fourth preset, the `s | m | xl` switch does not move, and ⌘\ is unchanged.

## Decision

**The pane's view is lifted out of its lane's stack into `MaximizedPaneView`, a
sibling of the scroll view in the strip controller's view, framed to the strip's
visible window. A `MaximizePlaceholderView` takes its slot in the stack.**

- The placeholder is the whole of "exactly as it was". The stack still has the
  same panes with the same weights, so the siblings keep their heights — and a
  sibling terminal is therefore not reshaped for the length of someone else's
  maximize. The lane keeps its width, the row keeps its layout, and the scroll
  view is not scrolled: `StripViewController`'s sideways-scroll capture stands
  down while the overlay is up, because a strip that moved underneath would not
  be the one the pane goes back to.
- The re-parenting is within one window, the same move a dock and a gallery tile
  already make, so a Ghostty surface is not rebuilt and a page does not reload.
- It is in memory only (`PaneMaximizer`). No schema change, no migration, no
  column. The test compares the whole `StripState`, revision included, before
  and after a round trip, then asks the core whether it has moved on: it has not.
- No content insets were added to the strip's scroll view. The overlay is a
  view, framed; nothing about the clip view changes.

### The viewport

The strip's visible window, in the strip controller's own view: between the edge
rails, inside an inset dock, clear of an overlay dock. The sidebar is outside
that view altogether, and the toolbar and status bar are siblings of it. So the
sidebar, both docks, the toolbar, the rails and the status bar all stay where
they are and stay usable — which is what makes "a session in a covered lane went
BLOCKED" answerable at all: the sidebar is still showing it.

### Motion

The overlay's frame is final the moment it is on screen and its **layer** eases
from the rect the pane had, on `Motion.lane` (0.22 s) with `Motion.easeOutTiming`
— `GalleryLayout.moveTransforms`, the gallery's way of growing a tile. Coming
down is the same animation reversed, held at its end until the view lands back
in its slot. Under Reduce Motion neither runs and both directions land at once.
A pane closed while maximized has no slot to shrink into, so the overlay fades
on `Motion.pane`, the way a pane leaves a stack.

The consequence worth stating: **the pane inside is laid out once per toggle, not
once per frame.** Going up, that one layout is at the start (the content is
drawn at its final layout, under the transform, for the length of the ease);
coming down, it is at the end. The work item asked for "one reflow at the end of
the animation at most"; going up it is one reflow at the *start*. That was chosen
over holding the old layout and popping at the end because it is the idiom the
gallery already proved, and because the alternative is a visible pop on the frame
the eye is resting on.

### The PTY (ADR-0007)

ADR-0007's headline — *terminal panes never resize the PTY* — was superseded by
the owner on 2026-09-12: a lane's width reshapes the PTY, and `xl` gives a
terminal the columns the wider lane holds. **Maximize follows the superseded
rule, the one the code follows today**: the terminal gets the columns the window
holds. A maximized terminal that kept 80 columns in a 1 600 pt window would be,
in ADR-0007's own amended words, "not a terminal".

What ADR-0007 still protects is the *cost*, and that is held: the far end is told
**one size going up and one coming down**, and the second is the size it started
with. Measured on a real Ghostty surface with a recording attachment: exactly one
`claimSize` per direction, the first with more than twice the columns, the last
equal to the start; and nothing is sent while the restore is still easing. It
goes through the ordinary `gridChanged → claim` path — no new way for a size to
reach the far end was added.

This does mean every ⇧⌘↩ on a shared session is a `SIGWINCH` for a phone attached
to it, twice. That is the same trade `xl` and a width drag already make, and the
owner made it knowingly. If it proves disruptive, the cheaper answer is a config
switch that holds the grid while maximized (the gallery's `ThumbnailHold` is the
mechanism), not a different overlay.

### A docked lane

**Allowed, not refused.** A docked lane's pane fills the same window — the
strip's, not the dock's — and its dock stays at the wall with the placeholder
showing in the slot (`maximized  ⇧⌘↩`), which is the one place the placeholder is
visible. Refusing would have been simpler to state, but a docked lane is where a
reference page lives, and "read this wide for a minute" is exactly the request.
Docking is not written, the dock's width is not touched, and the dock's other
panes stay usable.

### Leaving maximize without the key

One rule, held everywhere (`MaximizeRule`, asked of every snapshot in
`StripViewController.apply`):

> **A snapshot that moves focus off the maximized pane, or changes the shape of
> the strip, restores first.** Shape is each lane's id, order, width, span and
> dock, and the ids of its panes.

Because it is asked of snapshots rather than wired to commands, it needs no list
and cannot miss a door — the CLI and the shim included. What each case the work
item named does:

| | |
|---|---|
| ⌘[ ⌘] ⇧⌘[ ⇧⌘] (focus left/right/up/down) | restores, and focus goes where the key says |
| ⌥⌘[ ⌥⌘] (into a dock) | restores — it moves focus |
| ⌘O | the picker opens over the maximized pane and changes nothing; Esc from it leaves the pane up. The lane *arriving* restores |
| ⌘W on the maximized pane | the pane closes; the overlay fades with it |
| ⇧⌘W, ⌘D, ⇧⌘D, ⌘\\, ⌃⌘= ⌃⌘-, docking, moving a lane, gather | restore — each changes the shape |
| ⌘G | restores at once, then changes the layout, in either direction. At once because the gallery re-parents every lane view, this pane's included. The switch itself is a motion since ADR-0011's 2026-09-17 amendment; the maximized pane still comes down at once, before it |
| A covered session goes BLOCKED | nothing moves; the sidebar shows it. Clicking its row focuses it, which restores, then reveals it |
| ⌘= ⌘- ⌘0, ⌘R, ⌘L, ⌘F, a navigation, a title, telemetry, Keep Lane Loaded | stay maximized: neither focus nor shape |
| Esc | never restores. A terminal always has a use for Esc, and one rule for both kinds is worth more than Esc working on pages only |
| A page asks for full screen | fills the maximized pane (ADR-0014 works inside the pane's own view); leaving full screen leaves it maximized |
| The window resizes, the sidebar collapses | the overlay follows the visible window |

### In the gallery (amended 2026-09-17)

As first built the command was greyed out in the gallery, on the grounds that a
double click already grows a tile in place. The owner used it for a day and
overruled that: *"the pane full expand only works in lanes mode. It should also
work from gallery thumbnail and gallery expanded."* He is right that they are
different things. An expanded tile is a lane at the size of a lane; maximize is a
pane at the size of the window.

So ⇧⌘↩ works from a tile and from an expanded tile, through the same overlay and
the same rule. Three things differ:

- **The viewport is the whole gallery**, not the strip's window less its docks. A
  dock is an ordinary tile in the gallery (ADR-0011), so there is no wall to stay
  clear of.
- **A terminal lets go of its `ThumbnailHold` going up and is held again on
  landing.** A tile holds its terminal at the strip's size and draws it small;
  left held, the pane would fill the window with a lane-sized terminal in its
  corner. `layoutGallery` skips the lifted pane while it is up, or a window resize
  would freeze it at the window's size. The far end hears one size each way, as
  on the strip, and ends where it began (`terminalInATile`).
- **A double click inside the overlay is the program's.** The gallery's monitor
  would otherwise read it as "expand this tile" or "collapse this one", because
  the overlay covers both.

Restoring goes back into the tile, and an expanded tile is still expanded.
Nothing is written in either case. A pane in a tile sits within a point of where
it was rather than exactly there: AppKit snaps a scaled tile's contents to
backing pixels on every layout pass, maximize or no maximize.

### The sign

A header row across the top of the overlay, the lane header's height: the lane's
title, and at the right a `MAXIMIZED` chip — accent green text, a 1 pt accent
outline on all four sides, square corners — with the key beside it. Green because
the accent means focus (ADR-0015) and a maximized pane always has it. No
single-edge rail, no fill, no pulse: pulse is BLOCKED's. The chip is also a
button; the mouse is optional, not forbidden.

### The key

⇧⌘↩, rebindable as `toggleMaximizePane` in `[keys]`, listed in the ⌘/ sheet and
Settings from `Command.allCases` like every other. The View menu item reads
**Maximize Pane** or **Restore Pane** by state (`CommandHandling.title(for:)`).
Nothing else bound Return. From a terminal: Ghostty's bindings are cleared
(ADR-0009), and its `performKeyEquivalent` only takes Return with ⌃ held —
tested on a real surface holding the keyboard: it answers *not mine*, so the
menu gets the chord and it is not forwarded to the pty. From a page:
`Command.claims` is true for it, so the web pane's container sends it on to the
menu before the `WKWebView` can hand it to the site.

## Assumptions, kept

1. **The unit is the focused pane, not the lane.** Kept. In a split lane only the
   focused pane rises; the placeholder keeps the split.
2. **The viewport is the strip's visible area; sidebar and docks stay.** Kept. It
   is also what makes the BLOCKED case work. The alternative — the whole window
   content area — would cover the sidebar; if he wants it, it is a change to
   `maximizedViewportRect` and the overlay's host view, nothing else.
3. **A transient view state; nothing in the ledger.** Kept, and tested.

## Rejected

- **Widen the lane** (a fourth preset, or a temporary width). Breaks the
  invariant, writes to the ledger, reflows every neighbour's position, and makes
  "exactly as it was" something to restore rather than something never disturbed.
- **Draw the pane under a scale transform, as the gallery does.** A transform
  does not re-lay-out: the page's `innerWidth` would not change and a terminal
  would get bigger text, not more columns. The opposite of the request.
- **Take the slot out of the stack while maximized.** The siblings would grow,
  and a sibling terminal would be reshaped twice for someone else's maximize.
- **Wire "restore first" into each command.** A list that the next command
  forgets, and blind to the CLI.
- **Esc restores on a page.** Two rules for one key.

## What would make us revisit

- The owner wanting the whole window, sidebar included (assumption 2).
- The two `SIGWINCH`s per toggle proving disruptive on a session a phone shares.
- The stretched first frames of the ease reading badly on a real screen: the
  pane's content is drawn at its final layout through a non-uniform transform
  for 0.22 s. **Not yet seen on a screen** — no app instance was launched to
  build this; the tests check that the animation exists, its key path and its length, not
  how it looks.
