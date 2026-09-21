# Plan: remote relay-tty servers as lanes

**Status:** Decided 2026-09-17 (§4). Phase 0 is queued. Nothing else is built.
**Goal, in the owner's words:** connect to other relay server instances from
within Max Pane, so it can operate the local sockets *and* every session an
authorized remote server serves, with libghostty's rendering for all of them.
**Sources:** `docs/reference/relay-integration.md`, the relay-tty tree at 1.23.0
(`~/code/relay-tty`), relaytty.com (`~/code/relaytty.com`), and the Max Pane
tree at `82a1f3b`. Citations are `path:line` in the respective tree.

## 0. The bar to beat, and the feel

The owner, 2026-09-17: *"I can currently access the remote relay servers via a
browser in a browser pane; I just think we can get a better, more integrated
experience, so the bar to beat is that."* And: *"I was thinking more feature
based comparison than latency. There is no way using relay app in multiple web
panes is a good idea for the memory footprint and redundancy. I want remote
relay sessions to feel like local sessions and have simple distinguishing
features."*

So two rules for every phase:

**Feature for feature, not a benchmark.** The relay-tty web app in a web lane
already lists a server's sessions, attaches, spawns, shows agent state, and
handles files. Native does not need to prove it is faster; the memory and
redundancy case against one web app per pane is already made. Each phase says
what a user can *do* here that the web pane cannot, and what the web pane
still does better:

| The web pane | What native adds |
|---|---|
| Sessions listed inside the page, one server per page | Every server's sessions in **the one sidebar**, ranked with the local ones, BLOCKED pulsing the same green, one ⌘O to reach any of them |
| Log in by visiting the auth URL in the page, per page | Paste the URL once in Settings; the token is in the Keychain; every server's state in one place |
| Spawn from the page's form, on that server only | ⌘O / ⌘T / ⌘D on a remote lane start on that server in that directory, with the same recents and picker |
| A session is a tab inside a page | A session is a lane: it splits, docks, gathers by project, maximizes, and survives eviction and relaunch like any other |
| Files through the page's own viewer | The same server API, but a file opens as a lane beside the terminal that named it (Phase 4) |

Where native is not better, say so: the web pane's file browser and upload UI
are the server's own and stay the fuller ones until Phase 4.

**Feels local, distinguished simply.** A remote session is a lane exactly like
a local one: same header, same chips, same keys, same menu, same behaviour in
the gallery and in a dock. The difference is one mark, used consistently:
the **server chip** — a small grey outlined square with the server's name —
on the session's sidebar row, beside the path in the lane header, and on its
⌘O and ⌘P rows, with the sidebar's servers as `// NAME` sections; the path
beside it no longer repeats the name. (Amended 2026-09-19 by
[ADR-0023](../decisions/0023-one-truth-per-server-and-the-server-chip.md):
the first rule was the server's name where the directory tag sits, and in
use that was not enough.) No second colour family, no icon language, no
"remote mode", no colour per server. A server that stops answering says so
at once, in the accent green, on its header, its rows, its lanes and its
tiles. If a thing cannot work on a remote lane yet,
the lane says so in one line when the thing is tried, not with a permanent
badge. The test of the design is that a user who has never read this plan
can tell which box a lane is on at a glance and otherwise never thinks about it.

## 1. What the research settled

Five facts decide the shape of this feature. Three are good news.

1. **The pane already does not care where bytes come from.** A terminal pane
   attaches to `RelayAttachment` (`TerminalPaneController.swift:11-30`), a
   protocol that carries a session id and byte callbacks and nothing about a
   socket. `RelaySession.handle` — the offset arithmetic, gzip replay, delta
   detection, exit — is transport-agnostic. Only `connect()` and the framing
   are Unix-socket-specific. A WebSocket transport slots in under the pane
   with no change to the pane.
2. **relay-tty already has the remote client half.** Since 1.22 every CLI
   command takes `--host`, backed by `GET /api/sessions`, `/ws/events`,
   `/ws/sessions/:id` and `POST /api/sessions {command,args,cwd,cols,rows}`
   (`server/api.ts:107-150`, `server/ws-handler.ts:154-249`). Everything Max
   Pane reads off the local disk today has an HTTP or WS twin.
3. **One relay server is one machine.** There is no hub. `SessionStore` reads
   its own `~/.relay-tty/sessions` and nothing else (`server/session-store.ts`).
   relaytty.com is a reverse tunnel to one machine per account, not an
   aggregator. So "all authorized connections the server serves" means: Max
   Pane holds N connections to N servers and merges them itself. Nothing
   upstream will do the merge.
4. **Auth is a cookie, and the cookie does not cross the tunnel on WebSocket.**
   `verifyWsAuth` reads only `Cookie:` (`server/auth.ts:431-452`). Through
   relaytty.com the WS upgrade carries the path and nothing else
   (`server/tunnel-client.ts:248-253`), so the server sees a loopback socket
   and grants the localhost bypass. Consequence: over the tunnel, HTTP is
   authenticated and WS is not. LAN-direct, both are. And if `JWT_SECRET` is
   unset the server is open to the whole network on `0.0.0.0:7680`.
5. **Session ids are eight hex characters minted per machine, and every
   id-keyed structure in Max Pane assumes one namespace.** `SessionRegistry`
   (`SessionTelemetry.swift:252-262`), `pane.relay_session_id` in the ledger
   (`migrations/0001_initial.sql:15-27`), `refuse_second_pane`
   (`laned-core/src/lib.rs:1785-1796`), and every sidebar and strip lookup key
   on the bare id. Two servers will eventually mint the same one.

Two more that bound what a remote lane can be:

- **A remote path is only a path on the remote machine.** ⌘-click on a file
  checks `FileManager.fileExists` (`TerminalToken.swift:50-76`, whose own
  comment already says the honest question is "exists on the host running the
  session"); project roots come from walking the *local* tree for `.git`
  (`laned-core/src/project.rs:44-51`); sidebar groups abbreviate against the
  local `$HOME` (`SessionTelemetry.swift:236-243`). Each would silently give a
  wrong answer for a remote cwd rather than fail.
- **The `maxpane` CLI and the `BROWSER` shim are Unix-socket-local**
  (`crates/maxpane-open/src/lib.rs:104-117`, `OpenServer.swift:48`). A remote
  shell cannot reach this Mac's open socket, so "open this URL as a lane to my
  right" needs a reverse channel that does not exist.

## 2. Shape

**A server is a first-class thing; a session belongs to one.** Local is the
server named `local`, backed by the disk and Unix sockets exactly as today, so
nothing changes for the existing setup. A remote server is a base URL, a
display name, and a credential. Every session id in the app becomes a
`(server, id)` pair; the ledger stores the server on the pane.

```
                     ┌──────────────┐
  SessionRegistry ◄──┤ SessionSource│  local: disk + fs watch      (as today)
  (merged, keyed     │   per server │  remote: GET /api/sessions
   on server+id)     └──────────────┘          + /ws/events
                     ┌──────────────┐
  TerminalPane ──────┤ RelaySession │  RelaySession.handle unchanged
  (RelayAttachment)  │  + Transport │  local: AF_UNIX + length prefix (as today)
                     └──────────────┘  remote: URLSessionWebSocketTask, no prefix,
                                              PING every 10 s, zombie at 45 s,
                                              close 4001/1008 = stop reconnecting
                     ┌──────────────┐
  ⌘O / ⌘T / ⌘D ──────┤ SessionSpawn │  local: fork relay-pty-host (as today)
                     │   per server │  remote: POST /api/sessions, 201 = ready
                     └──────────────┘
```

Three seams, each a protocol over code that exists, each with the local
implementation being the current code moved behind it. The Rust core learns
one column. The UI learns that sessions and lanes have a host.

**What a remote lane is and is not.** It is a terminal with the same
rendering, resize, replay, agent state, title, BLOCKED and DONE as a local one.
It is not a file browser: ⌘-click on a path is off unless the server can answer
"exists", `maxpane open` from inside it does nothing to this Mac, and its
project root is `host:path`, never merged with a local project of the same
path. The sidebar groups it under its host.

## 3. Phases

Each phase ships on its own and is useful on its own.

### Phase 0 — spike: one remote lane, by hand (1–2 days)

Prove the transport before building the plumbing, **through relaytty.com**,
because that is how it will be used (§4.1) and because the WS-without-cookie
fact in §1.4 needs to be seen, not read. A `WebSocketTransport` under
`RelaySession`, a hard-coded URL and token in a throwaway build, one lane
attached to a session on the home box through its tunnel. Measure what the
spikes in `docs/spikes/` measured for local: byte-exactness across a long
replay, keystroke latency through the tunnel, and behaviour through a dropped
connection and a sleep/wake. Confirm on the wire whether the WS upgrade
reaches the server with or without the cookie, and what `?token=` does today.
Do the LAN-direct run as the control. Report goes in `docs/spikes/`.

Exit: a remote Claude Code session renders, resizes, and goes BLOCKED in the
sidebar with numbers next to each claim, and the auth finding is stated as a
fact with a packet capture or server log behind it.

### Phase 0b — upstream: authenticate the tunnelled WebSocket

Before Phase 1 ships to a build the owner travels with: relay-tty accepts
`?token=` on `/ws/sessions/:id` and `/ws/events` (§5.1). Until it does, a
tunnelled remote lane is readable and writable by anyone who knows the slug
and a session id, and Phase 1 must refuse `wss://` hosts that are tunnels, or
ship with that sentence in the README. The owner's call; this plan assumes the
fix lands first, since it is a one-line change in a repo he owns.

### Phase 1 — servers exist (the plumbing)

- `RelayTransport` protocol; `UnixSocketTransport` is today's `connect`/`drain`;
  `WebSocketTransport` drops the 4-byte prefix both ways, ignores text frames,
  sends PING, treats close 4001/1008 as final, reconnects on
  `NSWorkspace.didWakeNotification`. `WSMsg` gains `SESSION_UPDATE (0x15)`,
  filtered on session id because the server broadcasts it to everyone.
- `SessionSource` protocol; `DiskSessionSource` is today's directory + watcher;
  `RemoteSessionSource` is `GET /api/sessions?includeExited=1` plus
  `/ws/events`, polled on `session_poll_seconds` as fallback. Liveness is the
  server's `status`, not `kill(pid, 0)`.
- `SessionRegistry` merges N sources and re-keys on `(server, id)`. Every
  bare-id lookup in §1.5 follows.
- Migration `0015_pane_relay_server.sql`: `ALTER TABLE pane ADD COLUMN
  relay_server TEXT` (NULL = local), through `model.rs`, `ledger.rs`,
  `portable.rs`, and `refuse_second_pane` keyed on the pair. Export/import
  round-trips it.
- `StripViewController.makeController` picks the transport from the pane's
  server.

Exit: a remote session already running can be attached from ⌘O's session list
and survives a relaunch. No spawning yet, no settings UI yet.

### Phase 2 — you can add a server

- Config: a `[[servers]]` array of tables — `name`, `url`, `enabled`. This is
  the second nesting `config.toml` earns (the first was `[keys]`, argued for at
  `Config.swift:169-172`), so it needs a `ConfigControl` case or an explicit
  exemption in the schema-coverage test, and `ConfigToml.swift` must be checked
  for `[[…]]` support.
- The token lives in the Keychain, never in the file: `kSecClassInternetPassword`
  against the server's host, the store the passwords feature already uses.
  Settings gets a Servers section: paste the URL the server printed at startup
  (`{base}/api/auth/callback?token=…`) and Max Pane splits it into the base
  URL and the token itself, test the connection, see the session count. The
  token is the JWT the server minted, with no expiry, so it is stored once.
- The sidebar groups by host; a remote group header carries the server name and
  a connection state (green family: connected, reconnecting, refused).
- Attach and spawn errors say which server and why, in one line, and a 401 says
  "token refused" rather than looping.

Exit: the owner adds `yorkshire-alien4090` from Settings and its sessions
appear in the sidebar with the right BLOCKED state.

### Phase 3 — you can start things there

- `SessionSpawning` protocol over the three `spawn` overloads;
  `RemoteSpawner` is `POST /api/sessions`. It must send the no-`exec` wrapper
  Max Pane sends locally (`command: <shell>, args: ["-li","-c","<cmd>; exit $?"]`,
  see `RelaySessionSpawner.swift:176-186` for why), or every remote agent is
  `idle` forever and BLOCKED never fires.
- ⌘O gains a host: the picker's command row says where it will run, defaulting
  to the focused lane's server, with the server's own cwd — never
  `homeDirectoryForCurrentUser` for a remote. ⌘T and ⌘D beside a remote lane
  spawn on that lane's server in that lane's cwd. Recents remember the host.
- Project root for a remote cwd is `host:path` with `project_source = cwd`,
  found by asking the server (`GET /api/sessions/:id` carries cwd; a git root
  needs either a server endpoint or a `git rev-parse` run in the session, which
  is the ADR-0005 question again, one machine over).

Exit: ⌘O, type `claude`, ↩ on a remote server; it runs there, in a lane here,
and gathers with the other lanes of that remote project.

### Phase 4 — files and media, through the server's API

The owner's rule (§4.5): remote file and media management goes through the
relay server's API, the same way the relay-tty web app does it. Not through
this Mac's filesystem and not through a second protocol.

- **⌘-click on a remote path.** `POST /api/sessions/:id/exists` answers the
  tokenizer's "exists on the host" question; `GET /api/sessions/:id/files/*`
  serves the file. A text file opens in a web lane pointed at that URL on the
  relay server, with the session cookie, exactly as the web app's file viewer
  does. `$EDITOR` opens in a session spawned on that server (Phase 3).
- **Images and uploads.** `IMAGE (0x17)` frames already arrive over the WS
  and are fanned to every client of the session; `upload` and `upload-dir`
  (`server/api.ts:685-…`) are the way a file gets *to* the host. A drop onto a
  remote lane uploads there.
  **Landed first (2026-09-20): ⌘V of a picture in a remote lane.**
  `RelayUpload` (`Terminal/PastedImages.swift`) is `POST /api/upload` with the
  raw bytes, `X-Filename` and the session cookie, as the web client's
  `uploadOne` does it (`app/routes/sessions.$id.tsx:735`,
  `server/api.ts:713`); the `path` in the answer is pasted. It sends no
  `X-Upload-Dir`, so the file lands in the server's configured upload
  directory. A drop of local files onto a remote lane is the same call per
  file and is the next piece; it still pastes this Mac's paths today.
  ADR-0027.
- **`maxpane open` from a remote shell.** Still needs a reverse channel the
  server does not have; the cleanest is the shim posting to the relay server
  and Max Pane hearing it on `/ws/events`. Ask upstream (§5); until then
  `BROWSER` is not injected for remote spawns, so the remote's own rule applies.
- **Throughput and sparklines** from `GET /api/sessions/:id/sparkline`.

## 4. Decisions (the owner, 2026-09-17)

1. **Tunnel first.** *"Because I'm traveling."* relaytty.com is the path that
   matters, LAN-direct is the control. This makes §5.1 a prerequisite (Phase
   0b) rather than a wish, and puts the spike through the tunnel.
2. **A remote project root is `host:path`.** A remote project gathers with
   itself and never with a local path that happens to match.
3. **The local server stays implicit.** `[[servers]]` lists only remotes; an
   empty list is today's app, byte for byte.
4. **The token is pasted from the server's startup URL.** Settings takes the
   whole `…/api/auth/callback?token=…` line and keeps the token in the Keychain.
   A device flow (§5.5) can come later.
5. **Remote files and media go through the server's API, as the relay-tty web
   app does.** Nothing is refused for being remote if the server has an
   endpoint for it; Phase 4 is that mapping, not a set of exceptions.

## 5. What to ask of relay-tty (the owner also owns it)

Small changes there remove the worst of the client-side work. In order of
value:

1. **Accept `?token=` on `/ws/sessions/:id` and `/ws/events`**, the shape
   `/ws/share` already uses (`ws-handler.ts:201`). This is the one-line fix
   that makes tunnelled WebSockets authenticated at all.
2. **Send `SESSION_UPDATE` once on attach**, so a fresh connection learns agent
   state, cwd and title without a second HTTP call and without waiting for the
   next change.
3. **`/ws/events` carries the session list**, or at least a per-session diff,
   instead of the bare text `"sessions-changed"` that forces a full refetch.
4. **`GET /api/server`**: hostname, version, machine id. Today a native client
   has nothing to label a host with but the URL the user typed.
5. **A token endpoint** for owners (`POST /api/auth/token` behind the existing
   cookie), or a device-code flow, so the token never has to be copied from a
   terminal.

Draft these as `docs/proposals/relay-remote-clients.md` when Phase 0 has
numbers to attach.

## 6. Risks

- **Ids collide across servers.** Every structure re-keys or the bug is
  silent and rare. Phase 1's tests should mint the same id on two fake
  servers on purpose.
- **Stale pty-hosts.** A session keeps the pty-host it was started with.
  1.22 dropped a control frame sent in the same read as `RESUME`; 1.23 fixed
  input truncation past 1 022 bytes on macOS. A remote session may be on any
  version; chunk pastes and never send `SET_TITLE` in the handshake read.
- **Backpressure inverts.** The WS bridge pauses the pty socket when the client
  is slow (`ws-handler.ts:290-295`); the local broadcast channel drops. A slow
  render of a remote lane throttles the program instead of losing frames.
  Different, not worse, but the eviction policy assumes the local behaviour.
- **The schema-coverage test and the TOML editor** may not take an array of
  tables. Find out in Phase 2's first hour, not its last.
- **Scope creep toward a remote file browser.** PRD §16 names creep toward a
  browser as the risk; this is the same risk one machine over. Phase 4 is
  optional for a reason.

## 7. Not in scope

Windows or Linux hosts as *clients* (ADR-0018). A hub that merges servers
upstream (§1.3 says there is none; building one is a relay-tty project). Remote
web lanes: a page is a page, it does not live on a host.
