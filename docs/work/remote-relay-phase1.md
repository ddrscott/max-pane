# Remote relay, Phase 1: servers exist, and a running remote session can be a lane

Phase 1 of [`docs/plans/remote-relay-servers.md`](../plans/remote-relay-servers.md).
Read the plan (§1 facts, §2 shape, §4 decisions) and the Phase 0 spike report
in `docs/spikes/` first. Build on the spike's transport, do not redo it.

## Outcome

A remote relay-tty server's *already running* session appears in ⌘O's session
list and in the sidebar, attaches as an ordinary terminal lane rendered by
libghostty, resizes, takes input, reconnects, shows agent state (BLOCKED,
WORKING, DONE), and survives a relaunch. Configured by hand in this phase (no
Settings UI yet; that is Phase 2). Local behaviour with no remote servers
configured is unchanged, byte for byte.

## Acceptance Criteria

- **Transport seam.** `RelayTransport` protocol under `RelaySession`;
  `UnixSocketTransport` is today's code moved; `WebSocketTransport` is the
  spike's, hardened: no length prefix either way, text frames ignored, PING
  every 10 s, dead at 45 s without PONG, close 4001/1008 stop reconnecting,
  reconnect on `NSWorkspace.didWakeNotification`. `RelaySession.handle` is
  unchanged. `WSMsg` gains `sessionUpdate = 0x15`; the adapter filters it on
  its own session id.
- **Session source seam.** `SessionSource` protocol; `DiskSessionSource` is
  today's `RelaySessionDirectory` + watcher moved; `RemoteSessionSource` is
  `GET /api/sessions?includeExited=1` plus `/ws/events` (text
  `"sessions-changed"` → refetch; binary `SESSION_UPDATE` → patch), polled on
  `session_poll_seconds` as fallback. Liveness is the server's `status`; no
  `kill(pid, 0)` for remote.
- **One namespace per server.** `SessionRegistry` merges N sources keyed on
  `(server, id)`. Every bare-id structure follows: `attached`, `doneSince`,
  `dismissed`, `StripStore.lane(holdingSession:)`, `lane(forRelaySession:)`,
  `attachedSessionIDs()`, `SidebarModel` maps, `LaneView.currentSessionId`.
  A test mints the same id on two fake servers on purpose and proves nothing
  crosses.
- **Ledger.** Migration `0015_pane_relay_server.sql`: `ALTER TABLE pane ADD
  COLUMN relay_server TEXT` (NULL = local), through `model.rs`, `ledger.rs`,
  `portable.rs` (export/import round-trips it), and `refuse_second_pane`
  keyed on the pair. Registered in `ledger.rs`'s `MIGRATIONS`. Rust tests.
- **Attach chooses by server.** `StripViewController.makeController` builds
  the adapter for the pane's server. A remote pane's cwd seed comes from the
  remote source, not the disk.
- **Config, hand-edited for now.** `[[servers]]` array of tables in
  `config.toml` with `name`, `url`, `enabled` (default true). Local is
  implicit and never listed (§4.3). Find out in the first hour whether
  `ConfigToml.swift` parses `[[…]]`; if not, add it, with the line editor
  preserving comments as it does for everything else. The schema-coverage
  test needs a row or an explicit exemption; say which in the commit. Token
  storage: Keychain, `kSecClassInternetPassword` for the server's host, via
  the `Passwords/` store; for this phase, a `maxpane` CLI or a hidden command
  that stores a pasted startup URL is enough (`maxpane server add <url-with-token>`
  is fine), Settings UI is Phase 2.
- **Sidebar and ⌘O.** Remote sessions are grouped under their server's name,
  above or beside the local groups (`SessionTelemetry.groupPath` must not
  abbreviate a remote cwd against the local `$HOME`). ⌘O's session list shows
  them with the server name on the row. Attaching one is the same gesture as
  a local one.
- **Errors are one line and name the server.** A 401 says the token was
  refused and stops retrying; a refused connection says so and retries on the
  registry's cadence; the sidebar group header carries a connection state in
  the green family (connected / reconnecting / refused).
- **Off for remote, plainly.** ⌘-click on a path in a remote lane does
  nothing yet (Phase 4 maps it to the server API); `BROWSER`/`MAXPANE_SOCKET`
  are not relevant because nothing is spawned remotely yet. Project root for
  a remote pane is `host:path` (§4.2), and `ProjectResolver` must not walk
  the local tree for it.
- README: a "Remote servers" section stating what works in this phase and
  the `[[servers]]` shape. CHANGELOG: Added. ADR-0020: a session belongs to a
  server; why the local server is implicit; why `(server, id)` and not a
  synthesised id.
- Tests against a local fake relay server (HTTP + WS on loopback) for the
  source and the transport, plus the real server on the box for a by-hand
  check of the whole path, reported with what was and was not seen.

## Constraints

- Nothing about the local path changes when `[[servers]]` is empty; the
  existing test suite is the proof.
- Never commit a token; read the box's token per the spike task's recipe.
- Do not launch the built app from the agent's shell; do not touch
  `/Applications/MaxPane.app`. Build to `MAXPANE_APP=build/verify.app` if a
  bundle is needed for a test, and do not run it.
