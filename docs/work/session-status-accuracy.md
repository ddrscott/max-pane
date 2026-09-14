# Session status tells the truth: green only while an agent is actually working

The owner, with a screenshot of the sidebar: *"I think there's something wrong with
the session sidebar status. I know many sessions are actually idle, but the bytes
per second indicator is showing green. I don't think they should be. It's very
distracting."* And, asked whether green should follow the WORKING state: *"this
assumes the working state actually works. I'm not 100% it is accurate."* He was right.

## What was measured (2026-09-13, his live sessions)

In the screenshot every running session showed a green rate — 181 to 615 B/s — on
agents idle for minutes to hours. At the same time their relay session files read:

| session | title glyph | file `agentState` | `bytesPerSecond` | `bps1` | last output |
|---|---|---|---|---|---|
| Post workshop survey | ✳ | idle | 0 | 0 | 2 m |
| SSH tunnelling setup | ✳ | idle | 0 | 0 | 3.4 h |
| askscottpierce.com repositioning | ✳ | — | 0 | 0 | 3.4 h |
| Trey agent improvement | ◑ | working | 67 | 67 | 3 s |
| IDE file viewer and editor integration | ◑ | **idle** | 492 | 492 | 5 s |

Three separate faults produce what he saw.

1. **The registry never lets a rate fall (this app's bug, and the main one).**
   `SessionRegistry.adopt` (`Terminal/SessionTelemetry.swift` ~301) keeps the
   *existing* `bytesPerSecond` — and its `state` — whenever it is larger than the
   file's, on the grounds that "a live wire reading is fresher than the file". But
   nothing feeds live readings: `observeLive` has no caller, and
   `RelaySession.onMetrics` (the 0x14 SESSION_METRICS frame) is decoded and dropped.
   So the peak rate from whenever an agent last worked, and the state it had then,
   are carried forward every five seconds indefinitely.
2. **`bps1` is a one-minute rolling average.** Relay's pty-host (`ThroughputTracker`,
   read-only) averages the last 60 s, and the badge turns green at ≥ 1 B/s
   (`throughputText`). A redraw burst — Claude Code repainting when a client
   reattaches or resizes, which a relaunch does to every session at once — lights a
   session for a full minute even with fault 1 fixed.
3. **Relay's agent state is unreliable in both directions.** Its WORKING rule is that
   same `bps1 ≥ 1` (or a spinner/phrase in the tail), so the redraw burst also reads as
   WORKING for a minute; and a session visibly working (◑ in its title, ~500 B/s) was
   filed as `idle`. Claude Code's own title glyph — a spinner `◐◓◑◒` while working, `✳`
   when idle — matched real activity for every Claude session measured.

## Decisions already made (do not re-open)

- **Green means the agent is actually working.** The throughput badge is green only
  while the session's *derived* state is WORKING; otherwise it is a dim `idle`, with
  no trickle numbers.
- **Derive the state better, in this app:**
  - a session whose title carries Claude Code's spinner glyph is WORKING; one whose
    title carries `✳` is idle;
  - relay's BLOCKED still wins over the title — a permission prompt is the one thing
    that must never be hidden;
  - everything else (no recognised title glyph, other programs) keeps relay's state.
- Relay TTY stays read-only. If a relay change would genuinely help (a per-second
  rate in the session file, a WORKING rule that ignores redraw bursts, the `idle`
  misclassification), write it up in `docs/proposals/` and work around it here.

## Acceptance Criteria

- `adopt` no longer holds a larger stale rate or state: a session's rate and state
  fall the moment its file says so. Either delete the max-merge, or feed
  `observeLive` from `RelaySession.onMetrics` for attached sessions *with a
  freshness time* so a live reading only wins while it is recent (seconds, not
  forever). Say which and why.
- One derived state (title glyph → relay BLOCKED → relay state) drives every surface:
  sidebar rows and chips, lane headers, ⌘P rows, the status bar's `N working`, and
  gallery tiles. No surface computes its own.
- A Claude session that is idle (`✳`) shows no green anywhere, even during a
  reattach/resize redraw burst.
- A Claude session with a spinner title shows WORKING and a green rate, even when
  relay's file says `idle` (the measured `a7ab2d3b` case).
- A BLOCKED session stays BLOCKED whatever its title says.
- Tests: `adopt` decay (rate and state fall on the next file); the derivation table
  (spinner / ✳ / no glyph × relay idle / working / blocked / done / exited); badge
  text and colour per derived state; a redraw-burst fixture (`bps1` > 0, title `✳`)
  stays idle. Render sheet of sidebar rows in every state, light and dark, looked at.
- README: the session-browser section says what green means and where the state
  comes from.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Terminal/SessionTelemetry.swift` — `SessionTelemetry(info:)`
  (`bytesPerSecond: info.bps1`), `throughputText` / `badgeText` / `badgeIsThroughput`,
  `SessionRegistry.adopt`, `observeLive`.
- `swift/MaxPane/Sources/MaxPaneKit/Terminal/RelaySessionDirectory.swift` — the
  session-file fields (`bps1/5/15`, `agentState`).
- `swift/MaxPane/Sources/RelayClient/RelaySession.swift` — `onMetrics`, decoded and
  unused.
- `swift/MaxPane/Sources/MaxPaneKit/Views/SidebarModel.swift` — `titleGlyphs`,
  `splitGlyph` (the title glyph is already parsed for display).
- `Views/SidebarRowViews.swift` (badge colour ~134), `Views/LaneView.swift` (~1075),
  `Views/SearchPalette.swift` (~544, ~619), `Views/StatusBar.swift` (working count).
- Read-only reference: `/Users/spierce/code/relay-tty/crates/pty-host/src/main.rs`
  (`ThroughputTracker`, session file fields) and `agent_state.rs` (`classify`).

## Constraints

- Do not modify relay-tty.
- Queued before the green-palette task: that task's pulsing BLOCKED and green roles
  assume states that are right.
- Nothing appears or disappears abruptly: a badge turning dim, a chip changing, eases
  on `Motion`.
