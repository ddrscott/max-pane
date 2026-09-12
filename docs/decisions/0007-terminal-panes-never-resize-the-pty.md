# ADR 0007 — Terminal panes never resize the PTY

**Status:** Accepted · 2026-09-12
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

**A MaxPane terminal pane attaches normally and never sends `RESIZE`.**

It learns the PTY's size from the inbound `RESIZE` frame that precedes every
replay, follows the host whenever that changes, and fits the content inside the
lane — scrolling horizontally rather than reshaping the terminal.

M2 measured the mitigation directly: a client that never sends `RESIZE` learned
the host size purely from inbound frames (`["72x36", "100x30"]`), received
1 459 bytes of redraw across the whole fight, and **caused zero `SIGWINCH`s
itself**. It is a guest in the session rather than a claimant on it.

## Consequences

- **Inbound `RESIZE` must always be honoured.** It is the only signal that
  something else just reshaped the PTY, and ignoring it desynchronises
  SwiftTerm's grid from the real one.
- **Never read the live size from the session JSON.** M2 caught this directly:
  after the fight, the live PTY was 100×30 while the JSON still said 50×50,
  because pty-host flushes metadata on a 5-second timer. The wire is the
  authority for size; the file is not.
- **Wide content scrolls inside the lane.** Which is already the PRD's central
  design invariant — §1 states it for web panes, and this makes terminals obey
  the same rule instead of being the exception.
- **A lane narrower than the PTY shows part of a wider terminal.** That is the
  trade. It is the right one: an agent session's size should belong to the agent
  and whoever started it, not to whichever viewer most recently resized a column.

## Rejected

- **Propagate the size, as §11 specifies.** Measured above: a full TUI redraw on
  every other client, every flip, and the phone and the lane permanently
  fighting.
- **`OBSERVE` mode (0x26).** It avoids the problem completely — an observer is
  not counted as an attached client — but it gets **no replay**, so the pane
  would be blank until the next byte of output. For watching agents that are
  often idle, that is worse than the problem.
- **Resize only when we are the sole attached client.** Sounds reasonable, races
  badly: the phone attaches mid-session, and now the PTY is whatever the lane
  last set. Conditional ownership of shared state is worse than no ownership.
- **Propose a per-client viewport to RelayTTY.** This is the right long-term
  answer and it is a protocol change, which PRD §0.3 forbids without a proposal.
  Not needed for Phase 1: the mitigation costs a horizontal scroll, and PRD §0.3
  exists precisely so this kind of thing gets written down instead of built.

## What would make us revisit

- RelayTTY growing a per-client viewport, which would make §11 implementable as
  written. If Phase 1 shows horizontal scrolling in terminals is a daily
  annoyance, that proposal belongs in `docs/proposals/`.
- Scott deciding a given session belongs to MaxPane alone, which would make
  resizing safe for that session. A per-lane "own this session's size" toggle is
  a small change on top of this decision, not a contradiction of it.
