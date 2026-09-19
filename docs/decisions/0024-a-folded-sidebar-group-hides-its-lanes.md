# ADR 0024 — A folded sidebar group hides its lanes; the hidden set is the gather filter's sibling, not its generalisation

**Status:** Accepted · 2026-09-19
**Decides:** what folding a directory group, a server's group or a whole
section in the session sidebar does to the strip and the gallery; where that
lives relative to the gather filter; which lanes a fold covers; what persists;
how a hidden lane still calls for you; and how everything that reaches a lane
reaches a hidden one.
**Amends:** [ADR-0023](0023-one-truth-per-server-and-the-server-chip.md) in one
place: a section header (`// LOCAL`, `// NAME`) now has a triangle and folds. A
click on a server's header still opens Settings › Servers; the triangle is the
fold.
**Evidence:** the work item [`docs/work/sidebar-collapse-hides-lanes.md`](../work/sidebar-collapse-hides-lanes.md);
`crates/laned-core/tests/hidden.rs`; `SidebarCollapseHidesLanesTests.swift`
(the model, the store against a real ledger, the strip with a real
`StripViewController`, and the render sheets `collapse-sidebar-*`).

## The facts

1. **The owner (2026-09-19):** "It would be nice to have an autohide feature
   if any server or directory is collapsed in the session bar." Read as: a
   fold means *I am not working on this right now*, so its lanes leave the
   strip and the gallery and come back when it is opened. The reading was put
   to him and not corrected.
2. **A sidebar group is not a project tag.** A session files under its live
   *cwd* (`SessionTelemetry.groupPath`); a lane's tag is the resolved project
   root, which for a local lane is the git root. `~/code/max-pane/swift` and
   `/Users/…/code/max-pane` are the same lane. Only the shell hears a cwd;
   the core has never seen one.
3. **Gather is one include-by-tag, in the core, unpersisted.** `Core::gather`
   sets `Inner.gather = Some(root)` and `snapshot` narrows `StripState.lanes`
   to that tag, docked lanes excepted. Everything that must see past it
   already does: `all_lanes`, search, export, `lane(holdingSession:)`,
   `leaveGather(ifItHides:)`.
4. **The snapshot is what the shell retires from.** A lane that leaves
   `state.lanes` has its column closed by the strip's own departure, its tile
   dropped by the gallery, and — until now — its pane controllers torn down
   (`reapPaneControllers` read `state.lanes`).
5. **The collapse set was a `Set<String>` inside the sidebar's view
   controller**, shared with the bookmarks section's folds and gone at quit.

## Decision

### 1. A sibling of the gather filter, through the same door

The core gains a second, independent narrowing: `Inner.hidden`, a set of
**lane ids**, applied in `snapshot` straight after the gather filter, with
the same exemption for a docked lane. `StripState.hidden_lane_ids` reports
what it took out of *this* view, in ordinal order, so a lane a gather had
already left out is not counted twice.

It is not a generalisation of the gather filter ("a set of excluded tags"),
for three reasons, in order of weight:

- **The membership is not expressible in tags** (fact 2). A fold covers the
  lanes whose *rows* are under the header, and a row's group is a cwd. An
  excluded-tag set in the core would hide the wrong lanes whenever an agent
  works below its git root, which is most of the time.
- **They differ in every other property.** Gather is one tag, included, for
  the length of a look, gone at quit. A fold is many groups, excluded,
  standing, and persisted. One field carrying both would be an enum with two
  unrelated arms.
- **They compose.** Gathered on a project with one of its directories folded
  is a real state, and two narrowings applied in turn give it for free.

What it shares is the part worth sharing, and it is why this is not a second
filter *system*: one place narrows (`Core::snapshot`), one list is the strip
(`state.lanes`), and one set of doors sees past it (`all_lanes`, search,
export). Nothing downstream — the strip's diff, the gallery, the rails,
`maxpane ls`, ⌘[ ⌘], the status bar's lane count — learned a new rule.

The shell says *which* lanes (`Core::set_hidden_lanes(ids, hand_off_focus)`);
the core says what hidden *means*.

### 2. Which lanes a fold covers (`SidebarModel.hiddenLanes`)

- A lane files where its rows are: under the directory of each of its
  sessions the registry knows; with none known — a web lane, a terminal whose
  session is gone, a remote one not heard from yet — under its project tag.
  This is `SidebarModel.rows`' own rule, so a header hides exactly the lanes
  whose rows fold under it.
- A group is folded by its own header or by its section's (`host:` for a
  server, `// LOCAL` for this Mac). `// LOCAL` counts only while a server is
  configured: with none there is no header to open it by.
- **A mixed lane** (panes in two groups) is hidden only when every group it is
  in is folded.
- **An untagged lane** (the `Web` group, `-` in `maxpane ls`) is never hidden:
  it belongs to no project, so no project being put away can take it.
- **A docked lane** is never hidden, for gather's reason: it is not in the
  strip, and leaving the snapshot is how the shell destroys it.

### 3. Hidden is not closed

Nothing about a lane is written: not its ordinal, width, panes or state, and
nothing is sent to a session. Pane controllers of hidden lanes are kept
(`reapPaneControllers` now unions `store.hiddenLanes`): terminals stay
attached, pages stay loaded, and coming back rebuilds nothing. The eviction
plan is handed hidden lanes as *further than any lane* (`plan_with_hidden`):
they hold no strip index, are unparented, are first in line under memory
pressure, and are not rehydrated until they are back — a lane scrolled a long
way off, which is what they are. Gather's hidden lanes still lose their
controllers, as before; that was not this task's to change.

### 4. Persisted in the ledger, twice

`app_state.sidebar_collapsed` holds the folded keys and
`app_state.hidden_lane_ids` holds the lanes. No migration: `app_state` is
key–value. The second is derivable from the first, and is stored anyway so
that `Core::open` narrows the *first* snapshot: the strip a relaunch draws
first is the strip as it was left, rather than every lane for a frame and
then a mass departure. The bookmarks section's folds are not persisted and
not moved: they stay in the sidebar, unchanged.

### 5. You can always tell

A folded header that is holding lanes says `N LANES HIDDEN` where its count
was, grey, at rest; when a session under it is BLOCKED it says `N BLOCKED`
beside that in the blocked green, breathing, as every BLOCKED does. The
status bar reads `4 lanes · 3 hidden`. An empty strip that is empty because
everything was folded says so instead of offering to start something. The
status bar's and the footer's BLOCKED counts were never narrowed by anything
and are not now.

### 6. Reach-through: the group expands, then you are there

`leaveGather(ifItHides:)` became `bringBack(laneId:)` and does both: opens
every fold over the lane (`StripStore.expandGroups(hiding:)`), then leaves a
gather that hides it. A sidebar row, a double click, `attach` (the sidebar,
⌘O, `maxpane attach`), ⌘P, a click on `N ASKING`, and — new — a click on
`N BLOCKED` in the status bar, which goes to the next blocked agent with a
lane, all come through it.

Under that is a rule rather than a call site: **the lane with the keyboard is
never hidden by a recount.** If focus lands in a folded group — ⌘P, a lane
born there, the terminal you are typing in doing `cd` into it — the group
opens. Only the fold itself may take the focused lane away, and then the core
hands the keyboard on first: nearest lane still on the strip to the right,
else to the left, the rule closing a lane follows. With nothing left to hand
it to, it stays where it is and the next recount does not reopen what was
just folded.

The store settles the hidden set inside `publish`, before any observer sees
the snapshot, so a lane born into a folded group never opens its column only
to close it.

### 7. Motion

Lanes leave and return by the strip's own column close and open
(`Motion.lane`, ease-out, nothing under Reduce Motion, instant off screen as
ever). New: a fold takes lanes from anywhere, so the strip **holds one lane
still** while columns around it move — the focused lane if it is on screen
and staying, else the first that is (`StripAnchor`) — so a project folded
away to the left of what you are reading does not drag it off the screen. In
the gallery the tiles that stay slide by the existing tile motion and the
grid cross-fades over `Motion.lane` for the ones that come and go.

### 8. The setting

`sidebar_collapse_hides_lanes`, default **on**, under Lanes, applies live in
both directions (`ConfigStore.didChange` → `StripStore.refreshHidden`). Off is
the behaviour before this ADR exactly: folds fold rows, headers read as they
did, nothing is hidden, and a ledger that remembers hidden lanes forgets them
at the first count.

## Rejected

- **Filtering in the shell.** Every reader of `state.lanes` would need the
  second rule, and the eviction `Viewport` indexes the list the *core* plans
  against; two lists that disagree by the hidden lanes is the off-by-a-lane
  that evicts the pane you are looking at.
- **Excluded tags in the core.** Fact 2.
- **Making the whole server header fold.** ADR-0023 made that click the way
  to Settings › Servers on the day a server is refused; the triangle is a
  separate target instead.
- **Clearing focus when everything is folded.** A nil focus is a state half
  the app does not expect, to describe a moment that ends at the next click.

## Known limits

- A remote lane whose session has moved away from its tag's directory is
  filed by tag until its server answers, so for the seconds between launch
  and connect it can be on the wrong side of a fold, and then moves,
  animated.
- An undocked lane in a folded group goes straight to hidden: it returns to a
  place that is put away.
- A URL opened through the shim by an agent in a hidden lane lands at the end
  of the strip, untagged, as it does from a lane a gather hides
  (`lane(forRelaySession:)` reads the strip as drawn). Kept on purpose: the
  alternatives are a page nobody sees, or a folded project reopening itself
  whenever an agent runs `open`.
- `maxpane ls` lists the strip as drawn, as it does under a gather; hidden
  lanes are in `maxpane sessions` with `lane` in the third column.

## Revisit when

Gather gets a second life (then its hidden lanes should keep their
controllers too, by the same union), or folds want to be per-window.
