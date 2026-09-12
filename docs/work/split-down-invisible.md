# Split down (⇧⌘D) adds a pane that never appears

## Problem

Pressing ⇧⌘D does nothing visible. The lane looks unchanged.

The pane is actually created — the ledger gets it, and the session is spawned
and running. It is the *view* that never arrives. Evidence from a live strip:
one lane held three pty panes (`fcab8184`, `f7f41127`, `b59d7be3`) after Scott
pressed split-down twice, and `maxpane ls` listed all three, while the lane on
screen showed only the first. Two Relay sessions were running with nothing
rendering them.

## Cause

`LaneView.setPaneView(_:for:at:)` has exactly one call site:
`StripViewController.materialize(_:)` (`Sources/MaxPaneKit/Views/StripViewController.swift:387`),
which runs only when a lane view is *built* — on first materialization, or after
the lane is recycled and comes back.

`apply(_ state:)` diffs a new snapshot and calls `laneView.apply(lane)` for
every lane, which refreshes the header and focus ring but never reconciles the
lane's pane views against the snapshot. So a lane that is already on screen and
gains a pane keeps showing exactly the panes it had when it was built.

Corollary worth checking while fixing: the same gap should make **closing** one
pane of a stack leave its view behind, and it means scrolling the lane far
enough off-screen and back is a workaround that makes the missing pane appear.

## Acceptance criteria

- ⇧⌘D on a focused pty pane shows a second terminal in the same lane
  immediately, without scrolling the lane away and back.
- Splitting again gives a third, and the stack divides the lane's height evenly
  (`NSStackView` is already `.vertical` / `.fillEqually`).
- ⌘W on one pane of a stack removes that pane's view and leaves the others,
  with the remaining panes re-laid out.
- Closing the last pane of a lane still closes the lane (`close_pane` in the
  core already does this).
- The new pane takes focus and accepts keystrokes — see the focus-on-attach fix
  in `TerminalPaneController.takeFocus()`; a pane created into an existing lane
  goes through a different path and may need the same treatment.
- A test covers the reconcile: a lane view that already exists, given a snapshot
  with one more pane, ends up with both pane views installed in position order.

## Relevant files

- `swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift` —
  `apply(_:)` (the diff), `materialize(_:)` (the only installer),
  `retire(_:laneId:destroyPanes:)`.
- `swift/MaxPane/Sources/MaxPaneKit/Views/LaneView.swift` — `setPaneView`,
  `clearPaneViews`, `installedPaneIds`, the `stack`.
- `swift/MaxPane/Sources/MaxPaneKit/StripWindowController.swift` — the
  `.splitDown` case, for how the pane is created.

## Constraints

- Reconcile, do not rebuild. `apply(_:)` runs after every mutation and must
  touch only what changed — rebuilding a lane's panes on each snapshot would
  destroy and re-create a `WKWebView` (27–95 MB and an OS process each, per
  spike M1) and drop a terminal's scrollback on every keystroke that publishes
  a snapshot.
- Pane controllers must survive. `paneControllers` is keyed by pane id and
  already outlives lane views on purpose (ADR-0004); the fix belongs in which
  *views* are parented, not in controller lifetime.
- `installedPaneIds` already exists on `LaneView` and is the natural thing to
  diff against.

## Open question (does not block)

⌘D now opens the new-pane picker, so split-down moved to ⇧⌘D. Once it works,
worth deciding whether a vertical split should be a *placement* offered by the
picker ("below this pane" vs "to the right") rather than a separate command —
the strip's model is columns, and the stack is the one exception to it.
