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

**The control that matters is the web pane.** The owner already uses the
relay-tty web app in a web lane pointed at the tunnel URL; that is the bar to
beat (plan §0). Measure it alongside: the same session in a web lane running
the web app's terminal, through the same tunnel.

1. **Byte-exactness.** Replay of a long session (≥100 000 lines) through the
   tunnel compared to the same replay over the local socket, as spike M2 did.
2. **Keystroke latency** through the tunnel vs LAN-direct vs local, *and vs
   the web app in a web lane through the same tunnel*: median and p95 for a
   key echo, measured, not felt. Also memory: the web lane's `WebContent`
   process against the native pane, as spike M1 measured.
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

## The test server (set up 2026-09-17, by the owner's leave)

A relay-tty 1.23.0 server runs on the home box for this spike, started with
its relaytty.com tunnel. Reach the box as `ssh yorkshire-wsl`.

- **Public URL:** `https://yourslug.relaytty.com`. LAN-direct, for the
  control run, is the ephemeral port in `~/.config/relay-tty/server.json` on
  the box (`http://localhost:<port>`, reachable over an ssh `-L` forward).
- **It runs in tmux** as session `relay-server`, logging to `~/relay-server.log`
  (mode 0600). `tmux attach -t relay-server` to see it; if it is gone, restart
  it the same way: `relay server start --tunnel 2>&1 | tee -a ~/relay-server.log`
  inside tmux, with `~/.nvm/versions/node/v22.23.2/bin` on `PATH`.
- **The token** is on the last `Auth URL (1y)` line of that log. Read it at
  run time, never copy it into the repo, the report, or a commit:
  ```sh
  ssh yorkshire-wsl 'grep -o "callback?token=[A-Za-z0-9._-]*" ~/relay-server.log | tail -1 | cut -d= -f2'
  ```
  It is the `session` cookie value: `Cookie: session=<token>` on HTTP, and on
  the WS upgrade for the LAN-direct run. Verified: `GET /api/sessions` through
  the tunnel is 401 without it and 200 with it.
- **A session is already running** for you to attach to: id `0368d543`, a
  bash loop printing the date every 30 s in `/home/spierce`, spawned through
  `POST /api/sessions` over the tunnel. Spawn more the same way; a Claude Code
  session for the BLOCKED measurement is `{"command":"claude","cwd":…}` on
  that endpoint, and Claude Code is installed on the box.
- `JWT_SECRET` was auto-generated by tunnel mode, so this server is *not* the
  wide-open case; the auth measurement is meaningful.

## Constraints

- Never commit a token, and never print one into the report.
- Do not modify relay-tty in this task. Write the ticket instead.
- Do not launch the built Max Pane from the agent's shell, and do not touch
  `/Applications/MaxPane.app`. A spike build goes to `MAXPANE_APP=build/spike.app`
  for the owner to launch himself, or the measurement runs from `spikes/`.
