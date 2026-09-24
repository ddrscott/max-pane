# In the gallery, anything that focuses another lane moves the expansion to it

The owner (2026-09-24): *"anytime we're using a shortcut to focus on a pane/lane
while we're in expanded mode, we should compress the current and animate to the
newly focused lane so that we don't need to double click the selected lane to
read its contents."*

## Where this stands today

`8f8b494` gave **⌘[ / ⌘] and ⇧⌘[ / ⇧⌘]** exactly this behaviour, through
`StripViewController.cycleExpandedTile(from:direction:)`. Every other way of
focusing a lane still leaves the expansion where it was, so the keystroke
selects a tile you then have to double-click to read. Since 0.8.0 that is a
long list, and two of its entries are the app's newest keys:

⌥⌘[ / ⌥⌘] into a dock · **⌘J / ⇧⌘J Next and Previous Attention** · ⌥⌘J's list ·
⌘P · ⌘O attaching a session or opening a lane · ⌘E rows that focus · **a
`[[apps]]` web-app chord** · `maxpane attach` and `maxpane app` · a sidebar row
click · the status bar's BLOCKED count · a search hit.

## The rule

**While a tile is expanded, anything that lands focus on a different lane
expands that lane instead, and the one that was expanded compresses back into
its slot. While nothing is expanded, nothing changes.**

It is one rule at one place, not a case per command. Find the choke point where
"focus has landed on lane X" is true — `focus(_:)` calls `ensureVisible(_:)`,
and `select(laneId:paneId:)` and `reveal(laneId:flash:)` are the public doors —
and put it there. If the three do not share one point, make them, rather than
patching each caller.

## Acceptance Criteria

- Every path in the list above moves the expansion, and the pane that was
  focused within the newly expanded lane keeps the keyboard.
- **Not moved by:** ⌘G (it leaves the gallery), a click on the gallery
  background (it collapses, as now), a focus change *inside* the expanded lane
  (a split lane's other pane stays put and the tile does not re-expand), and
  any focus that lands on the lane already expanded (no animation, no flicker).
- **A single click on another tile while one is expanded** should move the
  expansion too: the screen is already given over to one tile, so taking it is
  no loss, and it is the same complaint. With **nothing** expanded a single
  click must still only focus, and the double click still expands. Say in the
  commit whether you kept this bullet; if it feels wrong when you look at the
  render, drop it and say why.
- **Motion**: the existing one. `expandTile` → `layoutGallery(animated: true)`
  already moves both tiles at once from where they are drawn, so a fast repeat
  turns round mid-flight rather than stacking. Nothing new, nothing instant.
- **`cycleExpandedTile` probably becomes redundant** once the general rule
  exists. Delete it if it does, but keep its one piece of real knowledge: the
  ⇧ pair steps between panes *within* a split lane and only crosses to the
  neighbour at the top or bottom edge. Say which you did.
- Tests over the `MaximizeRig` strip: the expansion follows ⌘J, a palette hit,
  an attach, a sidebar selection and a web-app chord; it does not follow ⌘G, a
  background click, or a focus move inside the expanded lane; the ⇧-pair's
  split-lane rule still holds; and no path leaves two tiles expanded.
- README's gallery section gains a sentence; CHANGELOG; ADR-0011 gains an
  amendment line beside the `8f8b494` one.

## Constraints

- Identity and motion rules as ever; no instant transitions.
- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it.
- Never capture `self` weakly in a callback on an object nobody else holds.
