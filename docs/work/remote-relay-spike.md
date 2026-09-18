# Spike: one remote relay-tty lane through relaytty.com

Phase 0 of [`docs/plans/remote-relay-servers.md`](../plans/remote-relay-servers.md).
Read that plan first; §1 has the facts and citations, §4 the owner's decisions.

## Problem

Max Pane can only attach to relay-tty sessions on this Mac, over Unix sockets.
The owner wants remote servers' sessions as lanes, and is travelling, so the
path that matters is the relaytty.com tunnel. Before any plumbing is built,
prove the transport works through it and find out what auth actually looks
like on the wire, because the research says the WS upgrade arrives at the
server with no cookie (`~/code/relay-tty/server/tunnel-client.ts:248-253`).

## What to build

A throwaway, not a feature. Nothing lands in the shipped app's behaviour.

- `WebSocketTransport` under `RelaySession` (`swift/MaxPane/Sources/RelayClient/RelaySession.swift`):
  `URLSessionWebSocketTask`, one binary message == one `[type][data]` payload
  with no length prefix either way, text frames ignored, `PING (0x20)` every
  10 s, treat no `PONG` for 45 s as dead, close codes 4001/1008 as final.
  `RelaySession.handle` must not change; the point is that it does not have to.
- A way to point one pane at it: an env var or a hidden config key read only
  by the spike build (`MAXPANE_SPIKE_REMOTE=wss://<slug>.relaytty.com|<session-id>|<token>`),
  so the owner can run it against a real session. Do not add a Settings row.
- A spike program under `spikes/` if that is easier to measure with than the
  app, in the style of the existing ones (see `spikes/README` or the M-series
  reports in `docs/spikes/`).

## What to measure and report (`docs/spikes/m7-remote-relay.md`)

1. **Byte-exactness.** Replay of a long session (≥100 000 lines) through the
   tunnel compared to the same replay over the local socket, as spike M2 did.
2. **Keystroke latency** through the tunnel vs LAN-direct vs local: median and
   p95 for a key echo, measured, not felt.
3. **Reconnect.** Kill the network for 10 s, 60 s, and 3 min; sleep the Mac
   and wake it. What the pane shows during, and whether replay resumes from the
   right offset after.
4. **Auth, on the wire.** With `JWT_SECRET` set on the server: does
   `/ws/sessions/:id` through the tunnel accept a connection with no cookie?
   With a wrong cookie? Does `?token=` do anything today? Same three for
   LAN-direct. State each as a fact with the evidence (server log line, or the
   HTTP status of the upgrade).
5. **Agent state and cwd.** After a fresh attach, how long until the sidebar
   could know the session is BLOCKED (`SESSION_UPDATE` arrival time), and does
   OSC 7 give cwd sooner.
6. **Stale pty-host check.** The version of pty-host behind the test session,
   and whether a paste over 1 022 bytes arrives whole.

## Acceptance Criteria

- A remote Claude Code session on the home box renders in a lane on this Mac
  through relaytty.com, resizes, takes input, and the report has a number
  next to every claim above.
- The report ends with a go/no-go on Phase 1 and a list of what Phase 0b (the
  upstream `?token=` change) must do, written precisely enough to be the
  relay-tty ticket.
- No change to the shipped app's default behaviour; the spike code is either
  under `spikes/` or behind the env var, and the commit says which.
- Tests for the transport's framing (prefix stripped and re-added, text frames
  dropped, PING cadence) against a local fake WS server, so Phase 1 starts
  with them.

## Relevant Files

- `swift/MaxPane/Sources/RelayClient/` — `RelaySession.swift` (the seam:
  `connect()` lines ~68-114 and `drain()` are the only Unix-specific parts),
  `Wire.swift` (encoders; needs a no-prefix variant and `SESSION_UPDATE 0x15`),
  `FrameParser.swift` (not used over WS).
- `swift/MaxPane/Sources/MaxPaneKit/Terminal/RelayAttachmentAdapter.swift` —
  reconnect loop at ~185-199 reconnects unconditionally; the spike must not.
- `docs/reference/relay-integration.md` §1 (framing), §12 (auth), §13 (remote).
- `~/code/relay-tty`: `server/ws-handler.ts`, `server/auth.ts`,
  `server/tunnel-client.ts`, `shared/client/transport-ws.ts`.
- `docs/spikes/` for the report format.

## Constraints

- The server is the owner's: `yorkshire-alien4090` (WSL2, has relay-tty via
  npm). Coordinate with the owner for the tunnel URL and the startup token;
  never commit a token, and never print one into the report.
- Do not modify relay-tty in this task. Write the ticket instead.
- Do not launch the built Max Pane from the agent's shell, and do not touch
  `/Applications/MaxPane.app`. A spike build goes to `MAXPANE_APP=build/spike.app`
  for the owner to launch himself, or the measurement runs from `spikes/`.
