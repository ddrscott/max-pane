# A key expands and collapses a gallery tile

The owner asked (2026-09-24): *"do we have a shortcut to toggle lane
expansion?"* We do not. Expanding is a double click and collapsing is a click
on the gallery background; every call to `expandTile` / `collapseExpandedTile`
comes from the click monitor (`StripViewController.swift` ~504-531) or from the
internal focus rule added by `e5fe14a`. There is no `Command` for either.

## Why it matters now

The keyboard reaches everything around expansion and not expansion itself. ⌘G
enters the gallery; ⌘J, ⌘[ and ⌘] **move** the expansion — but only once a tile
is expanded, so the one step that starts reading needs a mouse. A keyboard user
can arrive in the gallery and be stuck looking at thumbnails.

## Acceptance Criteria

- **One toggle command**, `toggleExpandTile` (suggest that name), in
  `Commands.swift`, rebindable, in the View menu, in the ⌘/ sheet and in ⌘E.
  In the gallery: expands the focused lane's tile, or collapses it if that lane
  is already the expanded one. **Outside the gallery it is greyed**, with the
  `unavailable()` wording the app already uses ("only in the gallery", matching
  the phrasing used elsewhere) — the strip's equivalent is ⇧⌘↩ Maximize Pane
  and this must not become a second one.
- **The chord**: ⌘↩ is the natural reading of "open this", and ⇧⌘↩ is already
  Maximize Pane, so the pair would read together. Check ⌘↩ against
  `Commands.swift`, `Keymap.reserved` and macOS before taking it; if it is
  spoken for, pick another and say which and why.
- **Esc collapses** an expanded tile when the gallery has one, and does nothing
  else — it must not leave the gallery (⌘G is the only way out; that rule is in
  ADR-0011 and the README, so honour it) and must not steal Esc from a terminal
  or a page when no tile is expanded. If the app's existing Esc handling makes
  this awkward, say so and ship the command without the Esc half rather than
  bending the rule.
- **A docked lane refuses to expand** — since `f4b77a5` a docked lane is a wall
  and is not a tile. Focusing one and pressing the key must say why in one line
  rather than doing nothing silently, or move to the nearest expandable lane;
  pick one, say which.
- Motion is the existing tile animation; a repeat mid-flight turns round from
  where the tiles are drawn.
- Tests: expand, collapse, toggle on the already-expanded lane, greyed outside
  the gallery, the docked-lane case, and that Esc does not leave the gallery.
  The two-pass test run from `da68187` applies: these assert values, so the
  parallel pass, with no `serial pass:` marker.
- README's gallery section and the ⌘/ sheet; CHANGELOG; a line in ADR-0011's
  amendments if the Esc rule is touched at all.

## Constraints

- Identity and motion rules as ever; no instant transitions.
- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it.
