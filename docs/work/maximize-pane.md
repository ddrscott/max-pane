# ⇧⌘↩ maximizes the focused pane to the visible viewport, and again puts it back

## Problem

There is no way to give one pane the whole screen for a minute. A long diff, a
wide log or a dense page has to be read inside a portrait lane, or the lane has
to be dragged or cycled to **xl** and then put back by hand. iTerm has
**Maximize Active Pane** on ⇧⌘↩: the active pane fills the tab, the same key
restores the split exactly as it was. The owner uses it by reflex and wants the
same key to do the same thing here.

## What the owner asked for

> I need `shift-cmd-enter` to expand a pane to the visible viewport similar to
> iTerm's fill visible area. This should work as a toggle so using the same
> shortcut will return the pane to its original size.

## Reading of it (assumptions, made because the owner was not there to ask)

- **The unit is the focused pane, not the lane.** In a split lane the focused
  pane alone fills the viewport and its siblings are covered, as in iTerm. In a
  lane of one pane the two readings are the same thing.
- **"Visible viewport" is the strip's visible area**: the window minus the
  sidebar and minus any docks, which stay where they are and stay usable. If
  that turns out wrong in use, the alternative is the whole window content
  area; say which was built and why.
- **It is a view state, not a size.** Nothing is written to the lane's width,
  span or zoom in the ledger, the `s | m | xl` indicator does not change, and a
  relaunch comes back un-maximized. "Returns to its original size" is then true
  by construction, because the original size was never touched.

If building it shows one of these is wrong, surface it per README Conventions
rather than quietly reinterpreting.

## The invariant this touches

README and PRD: *a lane is a portrait-bounded column; the lane never widens
past its max.* A maximized pane is wider than any lane. The way through is the
one ADR-0014 and the gallery (ADR-0011) already took: the lane does not widen;
the pane is presented over the strip under a transform or as an overlay, and
the strip underneath keeps its layout. **Write an ADR** stating this, since it
is the third time a pane is shown larger than its lane and the rule for when
that is allowed should be written once.

## Acceptance Criteria

- A new command (suggest `toggleMaximizePane`, title **Maximize Pane** /
  **Restore Pane**) in `Commands.swift`, default shortcut **⇧⌘↩**, rebindable
  through `[keys]` like every other, listed in the ⌘/ sheet and in the **View**
  menu with its title reflecting state.
- ⇧⌘↩ on a focused pane grows it to fill the visible strip viewport. ⇧⌘↩ again
  returns it to exactly the frame it had, with sibling panes' split ratios, the
  lane's width and the strip's scroll offset all as they were.
- **Animated both ways** with `Motion.pane` or `Motion.lane` easing, ease-out,
  landing at once under Reduce Motion. Never an instant jump.
- **A terminal pane follows ADR-0007**: decide whether maximizing resizes the
  pty. The ADR says terminal panes never resize the PTY, and `xl` already gives
  a terminal more columns, so read both and state which rule this follows. One
  reflow at the end of the animation at most, none per frame.
- **A web pane** lays out at the new width (the page's `innerWidth` changes),
  and chrome bar, find bar and downloads bar stay usable.
- **Works for both pane kinds, in split lanes and single-pane lanes, and in a
  docked lane.** For a docked lane decide whether it fills the strip viewport
  or is refused, and say which.
- **While maximized:** the pane keeps focus and takes keys normally. State what
  each of these does and test it: focus left/right/up/down, ⌘O opening a new
  lane, ⌘W closing the pane, ⌘G, a session going BLOCKED in a covered lane
  (the sidebar still shows it; clicking it should restore, then go there).
  The simplest consistent rule is *any command that moves focus or changes the
  strip restores first*; pick a rule and hold it everywhere.
- **Esc does not restore** unless the pane has no use for Esc, which a terminal
  always does. The toggle key is the way back.
- **Some visible sign that the pane is maximized**, in the identity: a label
  chip or header state, green family per ADR-0015, no single-edge colour rail.
  Without one, a maximized single pane is indistinguishable from a broken strip.
- Interaction with **page full screen (ADR-0014)**: a page that asks for full
  screen while its pane is maximized fills the maximized pane; leaving full
  screen leaves it maximized.
- **No conflict on the key.** Nothing binds ⇧⌘↩ today (`Keymap.swift` knows
  `return`/`enter`; no command uses it). Check the terminal does not need it:
  libghostty's app keybindings were cleared (ADR-0009), confirm this chord is
  not forwarded to the pty when the command claims it.
- Tests: the toggle is its own inverse (frames, split ratios and scroll offset
  compared before and after), the ledger is untouched by a maximize/restore
  round trip, the command appears in the keymap with the default chord and can
  be rebound, and the focus-change rule above.
- README: a paragraph under the lane size section or beside splits, the ⌘/
  sheet entry, and the CHANGELOG line.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Commands.swift` — the command registry and
  default shortcuts.
- `swift/MaxPane/Sources/MaxPaneKit/Keymap.swift` — chord parsing; `return` is
  already a known key name.
- `swift/MaxPane/Sources/MaxPaneKit/StripWindowController.swift` — where
  commands are dispatched.
- `swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift` — the
  strip, its scroll offset, the visible rect.
- `swift/MaxPane/Sources/MaxPaneKit/Views/LaneView.swift`,
  `Views/PaneSplit.swift` — panes inside a lane and their split ratios.
- `swift/MaxPane/Sources/MaxPaneKit/Views/GalleryLayout.swift` and ADR-0011 —
  the precedent for showing a lane under a transform without moving it.
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift` and ADR-0014 —
  the precedent for a pane's content filling more than its usual box.
- `swift/MaxPane/Sources/MaxPaneKit/Terminal/TerminalPaneController.swift` and
  ADR-0007 — the pty resize rule.
- `swift/MaxPane/Sources/MaxPaneKit/Views/LaneSizePreset.swift` — must *not*
  change: maximize is not a fourth preset.

## Constraints

- No instant transitions; subtle, ease-out, Reduce Motion aware.
- The strip's scroll view must not gain content insets for this (an
  `NSVisualEffectView` lands over inset regions and swallows clicks).
- Greens for state, grey at rest, Signal Orange only for DONE.
- Nothing durable: no schema change, no migration, no new ledger column.
- Do not launch the built app from the agent's shell to verify; the owner
  relaunches from the Dock.
