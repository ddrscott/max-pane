# Gauntlet: the browser half

**Goal.** Max Pane's web panes should be a browser Scott can live in, at
Vivaldi's level, inside a portrait column.

**The bar.** Vivaldi, as it is configured on this machine — captured from the
running window, not from marketing. What it gives, reading its chrome:

| Vivaldi has | Max Pane had, at the start of this run |
|---|---|
| back / forward / reload, always visible | nothing |
| the URL, shown and editable, domain emphasised | nothing — the lane header showed only the page title |
| a security indicator beside the URL | nothing |
| the hovered link's target on a status line at the bottom | nothing |
| find in page | nothing |
| zoom with a % readout and a Reset | nothing |
| history, searchable | nothing |
| a bookmark star | nothing |
| downloads | nothing |

The bar is directional, not a pixel target. A 656pt portrait lane cannot carry
Vivaldi's chrome, and copying it would eat the page. **The question a critic
asks is "can I do the thing", not "does it look the same".**

Reference screenshots live beside this file in the scratchpad for the run:
`bar-vivaldi.png` (Vivaldi, whole window) and `mp-now.png` (Max Pane, before).

## Weights — the owner's trade-off, verbatim

> we need to get the browser components up to par with vivaldi. so we have
> history, can show the URL (at the bottom or top), the top bar should have
> other standard browser bar features, too. You go through the list. `cmd =`
> and `cmd minus` should increase decrease font size for the pane in terminal
> or browser view. subtle animations must be used to indicate when/where items
> are appearing and disappearing otherwise the user loses spatial recognition.
> 3) browser oauth doesn't seem to be working. I can't login to google or
> youtube it seems to trigger sessions outside the app.

Ranked by the lead, on the principle that a broken thing beats a missing thing:

1. **OAuth** — a stated bug, and the one that makes a pane useless for real work.
2. **URL and navigation** — the largest visible gap against the bar.
3. **Zoom** — asked for explicitly, small, affects both pane kinds.
4. **Animations** — asked for explicitly; "otherwise the user loses spatial
   recognition" is the reason, so the test is legibility of *where things went*,
   not prettiness.
5. **History** — the one item with no partial version: either it is recorded
   from the first visit or the record has a hole in it.

## The pieces

Each gets a builder and, separately, a fresh-context critic that inspects the
running app — never the builder's account of it.

| # | Piece | Files it owns | Builder | Critic verdict |
|---|---|---|---|---|
| 1 | OAuth, popups, `window.opener` | `Web/WebPaneController.swift` | — | — |
| 2 | History: record, search, surface | `crates/laned-core`, a new palette | — | — |
| 3 | Appear/disappear animations, and the split-down reconcile | `Views/StripViewController.swift`, `Views/LaneView.swift` | — | — |
| 4 | Browser chrome: URL, nav, security, find, zoom readout | a new chrome view + `Web/WebPaneController.swift` | — | — |
| 5 | Terminal zoom | `Terminal/TerminalPaneController.swift` | — | — |

Pieces 1 and 4 both own `WebPaneController`, so they run in different waves.
The **seams are the lead's**, already in place before any builder starts:

- `Command.zoomIn/.zoomOut/.zoomReset` (⌘=, ⌘-, ⌘0) dispatch to the focused
  pane through `PaneController.setZoom(_:)`; `PaneZoom.next` is the ladder.
  Builders implement their side of that one method and nothing else.
- `MAXPANE_LEDGER` and `MAXPANE_DATA_SALT` let anyone run a throwaway instance
  — its own strip, its own cookie jars — without touching the one Scott is
  working in. **No builder or critic restarts the running app.**

## Kill criteria, registered before the round

A piece fails its round if, with a fresh critic driving a real instance:

1. **OAuth** — a Google sign-in started in a pane finishes in that pane, and the
   signed-in state is still there after the app restarts. A popup that opens a
   pane with no `window.opener` is a failure, not a partial pass.
2. **Chrome** — the critic can, without touching the keyboard shortcut sheet:
   see the current URL, edit it and go somewhere else, go back, reload, see
   where a link points before clicking it. Any one of those missing is a fail.
3. **Zoom** — ⌘= visibly enlarges a terminal's text *and* re-derives its grid
   (the far end is told, per ADR-0007's rules), and enlarges a page. ⌘0 returns
   to actual size. Zoom survives a restart.
4. **Animations** — a critic watching a screen recording can say where a new
   lane came from and where a closed one went, without being told. A cut with
   no motion is a fail; so is anything slow enough to wait for.
5. **History** — a page visited in a pane is findable by title and by URL after
   a restart, and the record has no hole where a redirect was.

## Log

- **Round 0 (lead).** Captured the bar from the running Vivaldi window. Put the
  two seams in: the zoom command/protocol, and the isolated-instance env
  overrides. Wrote this page.
