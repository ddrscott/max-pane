# Proposal for relay-tty: an agent state that ignores redraws

Max Pane reads relay-tty's session files and does not change them. This lists
the changes to pty-host that would let Max Pane drop its own workaround, which
is to trust Claude Code's title glyph over relay's `agentState` (see
`AgentState.derived`). Nothing here is required. Max Pane works as it is.

## What was measured (2026-09-13, the owner's live sessions)

| session | title glyph | file `agentState` | `bps1` | last output |
|---|---|---|---|---|
| Post workshop survey | ✳ | idle | 0 | 2 m |
| Trey agent improvement | ◑ | working | 67 | 3 s |
| IDE file viewer and editor integration | ◑ | **idle** | 492 | 5 s |

Relay's state was also WORKING for about a minute on every idle Claude session
after a relaunch, because each reattach makes Claude Code repaint.

## Proposed changes

1. **A short-window rate in the session file**, such as `bps5s` over the last
   five seconds, next to `bps1/5/15`. `bps1` is `ThroughputTracker`'s
   sixty-second average, so a single redraw burst stays above 1 B/s for a
   minute. A client that wants "is it producing output now" has nothing
   shorter to read.
2. **A WORKING rule that is not `bps1 ≥ 1`.** Either use the short window from
   (1), or skip output that follows a resize or a client attach within a short
   grace period. A resize repaint is not work.
3. **Look at why an actively working session was classified `idle`**
   (`a7ab2d3b`, ~500 B/s, spinner in its title). The tail heuristic in
   `agent_state.rs` (`classify`) appears to have missed it. The terminal title
   (OSC 0/2) is already tracked and could be a signal: Claude Code sets a
   spinner (`◐ ◓ ◑ ◒`) while working and `✳` while idle.

## What Max Pane does meanwhile

- It reads the state in this order: relay BLOCKED, then EXITED, then the title
  glyph, then relay's state.
- The rate badge is green only while that derived state is WORKING.
- Each session file replaces the previous reading, with nothing carried
  forward.
