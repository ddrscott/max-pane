# Closing a pane hands focus to a predictable neighbour

## Problem
Scott's everyday loop is ⌘D (split a pane below), run a command, ⌘W (close it). After the close, focus
should land back where he came from. Today it doesn't reliably, and with several lanes it's easy to lose
your place. `LanedCore::close_pane` (`crates/laned-core/src/lib.rs`, ~line 402) deletes the pane and never
chooses an heir, so focus falls to whatever fallback repairs a dangling `focused_pane_id` (see the
`KEY_FOCUSED_PANE` repairs near lines 185 and 594), or to whatever the Swift side does after
`StripStore.closePane`. Find out which one wins today before changing anything.

## Rule (reading order: up, then left)
Only applies when the closed pane had focus. Closing an unfocused pane (a ⋯ menu, a sidebar ✕, a
web page's `window.close()`) leaves focus alone.
1. **The pane has a pane above it in its lane** → focus the pane directly above.
2. **It's the top pane and there are panes below** → focus the pane that's now on top (the one that was
   directly below it).
3. **It was the lane's last pane (the lane closes)** → focus the **bottom** pane of the nearest visible
   lane to the **left**.
4. **No visible lane to the left** → the bottom pane of the nearest visible lane to the right.
5. Nothing left → no focus, as today.

"Visible" means the same test `set_hidden_lanes` uses for its heir: not docked, not hidden by the
sidebar, and inside the gather filter if one is on. A docked lane's pane closing stays inside its dock
(its own stack follows rules 1 and 2; its last pane closing hands focus back to the strip's last focused lane).

## Acceptance Criteria
- ⌘D then ⌘W puts focus back on the exact pane ⌘D started from, every time, in lanes and in an
  expanded gallery tile.
- Close the middle pane of three → the top one gets focus. Close the top pane → the new top pane gets it.
- Close a lane's only pane → the bottom pane of the lane to its left gets focus and the strip scrolls
  to show it (the usual `ensureVisible` path, animated per the no-instant-transitions rule).
- Close the leftmost lane's only pane → the bottom pane of the lane to its right.
- Hidden, docked and gathered-out lanes are skipped as heirs.
- Closing an unfocused pane doesn't move focus.
- The rule lives in the core (`close_pane` picks and writes the heir with `touch_focus` +
  `KEY_FOCUSED_PANE`), with Rust tests for each case above and a Swift test for ⌘D → ⌘W round-tripping.

## Relevant Files
- crates/laned-core/src/lib.rs (`close_pane`, `set_hidden_lanes` heir logic to reuse)
- swift/MaxPane/Sources/MaxPaneKit/StripStore.swift (`closePane`)
- swift/MaxPane/Sources/MaxPaneKit/StripWindowController.swift (~1248, the ⌘W path)
- swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift (~1993)

## Constraints
- Don't change what ⌘W closes, only where focus goes afterward.
- Focus moves animate (Motion.lane/pane, reduce-motion aware); no jump cuts.
- Update README's shortcuts/behaviour notes and CHANGELOG Unreleased.
- Workers must not launch, quit or replace the installed app.
