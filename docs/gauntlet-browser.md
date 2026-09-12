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
| 1 | OAuth, popups, `window.opener` | `Web/WebPaneController.swift` | done, committed | **PASSES** (3 fixes routed) |
| 2 | History: record, search, surface | `crates/laned-core`, a new palette | round 1 committed | **THE BAR WINS** → [round 2](work/history-round-2.md) |
| 3 | Appear/disappear animations, and the split-down reconcile | `Views/StripViewController.swift`, `Views/LaneView.swift` | building | — |
| 4 | Browser chrome: URL, nav, security, find, zoom readout | a new chrome view + `Web/WebPaneController.swift` | building (worktree) | — |
| 5 | Terminal zoom | `Terminal/TerminalPaneController.swift` | lead, done | pending |
| 6 | Copy/paste between panes | `Terminal/TerminalPaneController.swift`, `RelayAttachmentAdapter.swift`, `AppDelegate.swift` | done, committed | — |
| 7 | Lane widths: one configurable default, and always visible evidence of more | `Views/StripViewController.swift`, `Config.swift`, `crates/laned-core` | building (worktree) | — |
| 8 | Horizontal splits: a visible seam, draggable to resize heights | `Views/LaneView.swift`, `crates/laned-core` | building (worktree) | — |
| 9 | ⌘O: one place anything starts | `Commands.swift`, the palettes | building (worktree) | — |

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

## Added mid-run, in the owner's words

> "horizontal splits need borders between them, too, so we can see which see and
> resize the splits and resize their heights." (piece 8)

> "The widths of the vertical panes seem too evenly distributed. i can't tell if
> there are more panes to the right or left. the vertical panels should default
> to a configurable width for consistency. and a high unlikelyhood of even full
> width distribution. a messy desk isn't perfect, but pages on a desk are
> usually uniform." … "all these ideas lead to spatial reasoning of the
> interface." (piece 7)

> "in our app, cmd-r should be refresh, not run. cmd-o is better for open/run
> and allow a direct command or url (with or without scheme) and fuzzy search
> history of everything. again, this app should be my full time terminal and
> browser!" (piece 9, and ⌘R goes to piece 4 — reload is a nav control)

Two bugs found while writing those briefs, before any builder started:

- **`Config.laneDefaultPt` is decorative.** `crates/laned-core/src/lib.rs` keeps
  its own `LANE_DEFAULT_PT` with a comment that it "must match" the Swift one,
  and `create_lane` uses the Rust constant — so editing the config file changes
  nothing about new lanes. A constant that must match by hand is a bug waiting
  for someone to edit one of them.
- **Esc is bound to nothing.** `Command.ungather` declares `("\u{1b}", [])` and
  is deliberately skipped when the menu is built, with a comment saying it
  "lives in the responder chain" — but nothing handles it. A keymap that lists a
  key nobody listens for is worse than one that omits it. Queued with the
  configurable-hotkeys work.

## Log

- **Round 0 (lead).** Captured the bar from the running Vivaldi window. Put the
  two seams in: the zoom command/protocol, and the isolated-instance env
  overrides. Wrote this page.

- **Round 0, a hazard found the hard way.** `build-app.sh` `rm -rf`s the bundle
  before reassembling it. Doing that while an instance is running from it kills
  the app — WKWebView loses the ability to spawn its XPC processes and the
  process dies with no message. It killed Scott's app mid-sign-in. The script
  now refuses, and `MAXPANE_APP` builds elsewhere. Every builder was told.

- **Round 0, piece 5 done and seen.** ⌘= / ⌘- / ⌘0 resize a terminal's text.
  Three presses took the grid from 80 columns to 53 and dispatched the resize,
  so the far end reflows rather than clipping.

- **Round 0, two symptoms from the owner mid-run**, both routed to builders
  rather than guessed at:
  - "This browser version is no longer supported" on Google apps → the user
    agent, handed to piece 1 with instructions to measure what the panes
    actually send rather than reason about it.
  - "copy/paste from browser pane to terminal pane is not working" → became
    **piece 6**, with evidence gathered first: ⌘C from a web pane *does* work;
    ⌘V into a terminal fails two different ways in one session — in one lane the
    text arrives as the literal `[200~PASTE_PROBE_123~` (bracketed-paste markers
    reaching zsh's line editor as text), in a freshly created lane nothing
    arrives at all. Two leads handed over: the local emulator's guess about a
    *remote* program's bracketed-paste mode, which it cannot actually know; and
    a `Task { @MainActor }` per outgoing write, which gives the byte stream no
    ordering guarantee at all.

- **Round 1, piece 1 done — and the cause was one thing, not two.** The panes
  were sending `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)
  AppleWebKit/605.1.15 (KHTML, like Gecko)` — measured off the wire against a
  local echo server, not reasoned about. No `Version/`, no `Safari/`: the
  canonical embedded-webview shape, which is exactly what Google refuses to
  sign in *and* what raises "this browser is no longer supported". The version
  token now comes from Safari's own Info.plist at launch rather than being
  pinned, so it is true today and still true in a year.
  The second half: `window.open` returned nil and loaded the URL in an unrelated
  lane, so the popup could never reach `window.opener` — the sign-in completed
  somewhere with no way to hand the result back, which is precisely "it triggers
  sessions outside the app". Proven fixed against a local server: the popup
  found its opener, posted to it, the opener received the payload, and the
  popup's own HTTP request carried the cookie the opener had been given —
  still carried after a restart.

- **Round 1, piece 2 judged: THE BAR WINS.** The critic did the thing that makes
  a critic worth having — it measured Scott's real Vivaldi profile instead of
  judging in the abstract. 112,840 URLs and 462,785 visits going back to
  February 2024, against our 5,000-row store whose search only scans the newest
  2,000. At his measured rate — 5,136 distinct URLs a month — that is a
  fortnight of searchable history, and the 90-day age cap never even fires
  because the row cap evicts him at 29 days first. It proved the cutoff with
  planted needles rather than trusting the constant: depth 1,899 found, depth
  2,499 "no page matches", with the row sitting in the table and the footer
  reading `0 OF 5013 PAGES`.
  The caps bought speed nobody was short of — the query costs 2 ms over 2,000
  rows, measured. Full list in [round 2](work/history-round-2.md); the two
  findings that change what is being built *right now* went to piece 9.

- **Round 1, piece 1 judged: PASSES.** Eleven popups across seven scenarios and
  the named failure mode — a popup with no `window.opener` — never occurred. The
  evidence that counts is cross-origin, which is the shape OAuth actually has:
  opener on `localhost`, popup on `127.0.0.1`, `has_opener=true`, and the
  message arriving with the right origin. The cookie jar was proved at the
  network layer — a `Set-Cookie` sent only to the opener came back on the
  popup's own document request and its subresource fetch, which a popup built
  from a fresh configuration could not have done — and it survived a restart.
  On the user agent: measured on the wire, byte-identical to
  `navigator.userAgent`, and `accounts.google.com` answered a fabricated
  address with "Couldn't find this account" — the normal answer, meaning the UA
  passed the gate that used to reject it. No unsupported-browser banner on Gmail
  or YouTube.
  Three fixes routed to piece 4, the biggest being that a popup opened while its
  opener is off-screen is created and focused but never scrolled to — fine for a
  machine-to-machine round trip, useless for a form you have to type into.
  The critic was straight about its boundary: it never saw a token come back, a
  consent screen, or a signed-in Gmail. That the whole flow completes is
  inferred from the parts, not observed.

- **Round 1, piece 6 done.** Copy/paste: three bugs wearing one costume — a
  bracketed-paste guess about a program on the far end of a socket, one paste
  arriving as three unordered Tasks, and a pane that lost the keyboard when the
  strip reparented its view.

- **A datum that narrows piece 1.** Scott's Gmail lane is signed in and the
  session survived a restart, so cookie persistence and the data-store sharding
  are fine. Whatever is wrong with OAuth is narrower than "logins do not stick".
