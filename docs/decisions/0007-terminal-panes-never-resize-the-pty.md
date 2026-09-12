# ADR 0007 — Terminal panes never resize the PTY

**Status:** **Superseded on the central point · 2026-09-12.** Scott, using it:
*"resizing a terminal pane should notify the xterm of the size so the text can
reflow."* Max Pane now reshapes the PTY when a lane's width changes. Everything
below about *what that costs* still holds and is why it was worth asking about —
the cost was real, it was just the wrong trade for the person who has to use it.
A lane you drag wider that gives you no more columns is not a terminal.

Still true, and still load-bearing:
- The size a session is *born* at is chosen from the lane, where we are the only
  client and take nothing from anyone.
- Inbound `RESIZE` is always honoured for the emulator's grid — it precedes
  every replay, and ignoring it renders the buffer at the wrong width.
- The lane is **not** derived back from the session. Doing both directions is a
  fight; the lane is the user's choice and the PTY follows it.
- Never read the live size from the session JSON; it lags by seconds.

**Original status:** Accepted · 2026-09-12
**Amends:** PRD §11 — "Resize → propagate to Relay; verify cell-accurate reflow."
**Evidence:** [Spike M2](../spikes/02-m2-relay-attach.md),
[RelayTTY integration reference](../reference/relay-integration.md).

This one is not an open decision from §14. It is a requirement that turned out to
contradict the system it depends on, surfaced per PRD §0.6 rather than quietly
reinterpreted.

## The conflict

PRD §11 says a terminal pane propagates its size to Relay. Three other parts of
the PRD make that unworkable together:

- **§8** bounds a lane to 420–900 pt — roughly 40 to 100 columns. A MaxPane
  terminal is a narrow portrait column by design.
- **§3** keeps RelayTTY's existing mobile client reaching the same sessions.
  Nothing about that changes.
- **RelayTTY's PTY resize is global last-writer-wins.** One PTY, one `winsize`,
  no per-client viewport. Every client's `RESIZE` feeds one channel; the last one
  wins *for everyone*, does `TIOCSWINSZ`, sends `SIGWINCH` to the foreground
  process group, and broadcasts the new size to all clients.

So a 50-column lane and a 100-column phone attached to the same agent session do
not each get the size they asked for. They take turns reshaping the PTY out from
under each other.

## What it costs, measured

M2 attached two clients at different sizes to one session and flipped between
them, with a third innocent client watching:

| Session | Per flip, forced on every other client |
|---|---|
| ruler fixture | **825 bytes** of redraw |
| `htop` — a real full-screen TUI | **6 671 bytes** of redraw |

After eight flips the live PTY was 100×30 — the phone wrote last, so it owned the
terminal for everyone. The MaxPane lane had asked for 50×50 and was being fed a
100-column screen it had no room for.

A full-screen TUI redraw per flip, on every attached client, is not a rough edge.
For an app whose entire premise is watching several agents at once, it is the
app fighting itself.

## Decision

**A MaxPane terminal pane attaches normally, never sends `RESIZE`, and sizes the
*lane to the session* rather than the session to the lane.**

M2 measured the mitigation directly: a client that never sends `RESIZE` learned
the host size purely from inbound frames (`["72x36", "100x30"]`), received
1 459 bytes of redraw across the whole fight, and **caused zero `SIGWINCH`s
itself**. It is a guest in the session rather than a claimant on it.

The concrete rule, in order:

1. **Never send `RESIZE` automatically.** Not on attach, not on focus, not on
   lane resize, not on window resize, not on reconnect. This is a deliberate
   divergence from `cli/attach.ts`, which asserts its size on every transition to
   connected — right for a single-client CLI, harmful with a phone on the same
   session.
2. **Take `cols`/`rows` from the inbound `RESIZE` frame.** It is the first frame
   of every handshake and is broadcast on every change.
3. **Derive the lane's width from the session:**
   `clamp(hostCols × cellWidth + gutter, LANE_MIN, LANE_MAX)`, re-derived on every
   inbound `RESIZE` — animated, because a phone can change it under the user.
4. **Scale the font only when `hostCols × cellWidth + gutter > LANE_MAX`,** down to a 9 pt
   floor (84 columns at 420 pt, 180 at 900 pt). Below that, clip with a visible
   affordance.
5. **One explicit escape hatch:** a "claim this session at this width" command
   that sends exactly one `RESIZE`, as a deliberate and visible act. Re-asserting
   a size already in effect is free, so a claimed pane may safely re-assert on
   reconnect — but never a *different* size without being asked again.

### Why sizing the lane is better than scrolling it

An earlier draft of this ADR said the pane would scroll horizontally inside a
fixed lane. M2 rendered all three options and that one is wrong:

| Option | Verdict |
|---|---|
| **Clip** | No. 13 columns amputated from every line; because the TUI had already wrapped, the cut lands mid-word on 44 of 53 lines. Prose becomes unreadable, not merely truncated. |
| **Horizontal scroll** | No. Scrolling sideways to finish every sentence in a pane you are *supervising, not driving* is the opposite of the point. A supervision surface is read at a glance. |
| **Size the lane to fit** | **Yes.** |

And it turns out to be easy, because the PRD's own lane range already
accommodates real sessions. At 12 pt a cell is 7 pt wide:

| Host columns | Lane width needed | Inside 420–900 pt? |
|---|---|---|
| 52 | 364 pt → clamps to `LANE_MIN` | yes, with slack |
| 73 | 511 pt | yes |
| 100 | 700 pt | yes |
| 126 | 898 pt | yes, at the very top |
| 128 | 912 pt | no — M2 quotes 896 for the grid; 16 pt of lane chrome tips it over |
| > 126 | > 900 pt | no — scale the font |

The real sessions on this machine run **52 to 73 columns**. Every one fits in a
PRD lane at a normal font size. Font scaling is the fallback for the rare
>128-column session, not the mechanism.

## Consequences

- **Inbound `RESIZE` must always be honoured.** It is the only signal that
  something else just reshaped the PTY, and ignoring it desynchronises
  SwiftTerm's grid from the real one.
- **Never read the live size from the session JSON.** M2 caught this directly:
  after the fight, the live PTY was 100×30 while the JSON still said 50×50,
  because pty-host flushes metadata on a 5-second timer. The wire is the
  authority for size; the file is not.
- **A terminal lane's width is not entirely the user's to choose.** It is derived
  from the session and clamped to §8's range. Dragging a terminal lane's edge is
  therefore a font-size gesture more than a width gesture, and the lane may move
  on its own when a phone reshapes the PTY. That is worth an animation and worth
  being visible.
- **The design invariant holds.** §1's "wide content scrolls inside the lane;
  the lane never widens past its max" is unchanged — the lane is still bounded by
  `LANE_MAX`, and past 128 columns the font shrinks rather than the lane growing.

## Rejected

- **Propagate the size, as §11 specifies.** Measured above: a full TUI redraw on
  every other client, every flip, and the phone and the lane permanently
  fighting.
- **Horizontal scrolling inside a fixed lane.** What an earlier draft of this
  ADR specified. M2 rendered it and it fails the product: a supervision surface
  is read at a glance, not scrubbed sideways.
- **`OBSERVE` mode (0x26).** It avoids the problem completely — an observer is
  not counted as an attached client — but it gets **no replay**, so the pane
  would be blank until the next byte of output. For watching agents that are
  often idle, that is worse than the problem.
- **Resize only when we are the sole attached client.** Sounds reasonable, races
  badly: the phone attaches mid-session, and now the PTY is whatever the lane
  last set. Conditional ownership of shared state is worse than no ownership.
- **Propose a per-client viewport to RelayTTY.** The real long-term fix, and a
  protocol change, which PRD §0.3 forbids without a proposal. **No proposal is
  being filed**, because it is not needed: a silent client already gets
  everything MaxPane requires — authoritative size, full replay, live output —
  and the PRD's own lane range accommodates every real session width. If Phase 1
  shows the phone reshaping sessions disruptively often, the cheaper answer is a
  MaxPane-side convention (a preferred size in `laned-core`, re-asserted only on
  explicit user action) before anything in RelayTTY is touched.

## What would make us revisit

- RelayTTY growing a per-client viewport, which would make §11 implementable as
  written. If Phase 1 shows the phone reshaping sessions often enough to be
  disruptive, that proposal belongs in `docs/proposals/` — after the cheaper
  MaxPane-side convention has been tried.
- A session wider than 128 columns becoming common, which would make the 9 pt
  font floor the normal case rather than the rare one.
- Scott deciding a given session belongs to MaxPane alone, which would make
  resizing safe for that session. A per-lane "own this session's size" toggle is
  a small change on top of this decision, not a contradiction of it.
