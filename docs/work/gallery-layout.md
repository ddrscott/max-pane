# Gallery: every lane on one screen, live, as a second layout

The owner: *"we need to implement the `gallery` view from Relay TTY so I can
see all my sessions and browsers in one shot … These are my 2 most used
layouts from Relay TTY and I need them here."*

## Problem

The strip shows three or four lanes at a time. Supervising twelve agents means
scrolling to find the one that is waiting on a `y`, which is the job the strip
exists to make unnecessary. Relay TTY answers it with two layouts — lanes and a
gallery grid of live thumbnails — and he lives in both. Max Pane has only the
first.

He is explicit about the bar: a tile does not have to be comfortable to read.
He can tell from its shape that it wants Enter or Esc. But it should be **as
sharp as the pixels allow**, so on a HiDPI display he can squint and make it out.

## Decisions already made (do not re-open)

- **Fit every lane on one screen.** The gallery picks the largest tile size that
  puts every lane in the window with no scrolling, and recomputes when a lane
  comes, goes, or the window resizes. No W/H steppers.
- **A sticky layout, not a temporary view.** Lanes ⇄ Gallery is a toggle, and
  whichever one you were in comes back after a quit *and* after a `kill -9`.
  Stored in the ledger's `app_state` (key/value, so no migration), committed
  before the UI moves — the project's first convention.
- **Stacked panes stay stacked.** A tile is a lane: its panes keep their order
  and their proportions inside it.
- **Single click** on a tile, or on its row in the session sidebar, focuses that
  pane *in the gallery* and the keyboard goes to it normally. Typing into a
  thumbnail is the point.
- **Double click** on a tile, or on its sidebar row, switches to the Lanes
  layout with that lane revealed and focused — what ⌘P does today.
- **Browsers live where possible, suspended where they must be.** The memory
  policy still wins; a suspended page shows its placeholder snapshot in the tile.

## Acceptance Criteria

- A command (menu, ⌘/ sheet, rebindable through `keys`) toggles Lanes ⇄ Gallery.
  **Not Esc**: in the gallery Esc and Enter must reach the focused tile, because
  answering a prompt from a thumbnail is the use. `ungather` holds Esc today —
  in the gallery it must not swallow it.
- Every lane on the strip is a tile, in strip order, wrapping into rows, all
  visible at once, none cropped. Tile geometry is a pure function (lane count,
  lane widths/spans, window size → rects) with tests in the default run.
- A tile is the lane's real layout scaled down, **never a re-flowed grid**:
  ADR-0007 forbids resizing a PTY, and a thumbnail that resized the session to
  fit would resize it on his phone too. The `73×53` a session reports must not
  change when he enters the gallery.
- Terminal output in a tile updates live. Text is rendered at the backing
  scale, not a 1× bitmap stretched: on a 2× display, squinting works.
- Single click focuses (keyboard goes there; the focused pane's orange outline
  shows in the tile); double click leaves for Lanes at that lane. In the gallery
  the double click is taken from the terminal — a word selection inside a
  thumbnail is not something anyone wants.
- The session sidebar follows the same two gestures while the gallery is up,
  and keeps today's behaviour in Lanes.
- Relaunch — clean or `kill -9` — returns to the layout that was showing.
  A durability test in `crates/laned-core/tests/durability.rs` proves it.
- Web tiles are live under the existing budget and fall back to their
  placeholder snapshot when evicted; entering the gallery with twelve web lanes
  must not put WebKit over the hard mark.
- A render sheet under `MAXPANE_SHOTS` draws a gallery of mixed lanes (split
  terminal, web, placeholder, focused) so a human can check sharpness.
- README: a "Gallery" section in the house voice, and the key in the table.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift` — owns
  lane views, reveal, focus, `sessionsChanged`, and the gather view this sits
  beside; `distanceFromViewport` drives web release/rehydrate and means
  something different when every lane is on screen.
- `Views/LaneView.swift`, `Views/PaneSplit.swift` — lane chrome, stacked panes,
  the focus outline a tile has to keep.
- `Views/StripMotion.swift`, `Views/StripEdges.swift` — current geometry
  (ADR-0004: lanes positioned by summing widths).
- `Terminal/TerminalPaneController.swift` — Ghostty surface, `fitToSize`,
  cell metrics; the scaling question lives here.
- `Web/WebPaneController.swift` + ADR-0006 — eviction and JPEG placeholders
  (1× by decision; revisit only with numbers if tiles need sharper ones).
- `Views/SidebarViewController.swift` — row click handling.
- `Commands.swift`, `Keymap.swift` — the new command and its default chord.
- `crates/laned-core/src/ledger.rs` (`app_state` / `set_app_state`),
  `src/lib.rs` (`KEY_FOCUSED_PANE` is the precedent for a new key).
- Config: `releaseDistance`, `rehydrateDistance`, `webMemory*Fraction`.
- **Relay TTY, read-only:** `app/components/grid-terminal.tsx`,
  `app/lib/webgl-budget.ts`, `docs/work/grid-cache-policy.md`. Its lesson is
  the one to port: live renderers are budgeted *deterministically* (top-N by
  recent output, the focused cell pinned, 5 s revoke hysteresis), because the
  platform's own eviction picks victims at random.

## Constraints

- **Measure the scaling before building on it.** Whether a Ghostty/Metal
  surface and a `WKWebView` stay sharp and cheap when scaled down — layer
  transform vs. a smaller backing — is the question this whole task rests on.
  Answer it with a spike under `spikes/` that stays runnable, and put the
  numbers in `docs/spikes/`.
- The system never reorders: the gallery is a view over ordinals and writes
  nothing but the layout key and focus.
- RelayTTY is read-only. No protocol change; if the gallery needs one, write a
  proposal in `docs/proposals/` and stop.
- Square corners, Signal Orange for focus only; no rounded thumbnail cards.
- Where a decision here collides with reality — docked lanes (tiles, or still
  docked?), gather while in the gallery — surface it in an ADR rather than
  guessing. Suggested default: docks become ordinary tiles in the gallery, and
  gather narrows the gallery to its tag.
