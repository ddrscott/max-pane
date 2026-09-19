# ADR 0022 — A remote spawn sends the no-`exec` wrapper over the API; a remote project root is the cwd itself

**Status:** Accepted · 2026-09-18
**Decides:** what `POST /api/sessions` is sent when Max Pane starts a session
on a remote relay-tty server; how ⌘O, ⌘T and ⌘D choose the server and the
directory; and what a remote lane's project root is when the server has no
git-root answer. Phase 3 of
[`docs/plans/remote-relay-servers.md`](../plans/remote-relay-servers.md).
**Evidence:** the work item
[`docs/work/remote-relay-phase3.md`](../work/remote-relay-phase3.md);
`RemoteSpawnTests.swift` (the bodies, the place rule, the grammar, the fake
server, and `LiveRemoteSpawnTests` against the real one);
`tests/sessions.rs::a_remote_project_gathers_with_itself_and_never_with_the_local_path`;
relay-tty 1.23.0's `server/api.ts`, `server/pty-manager.ts`,
`shared/spawn-utils.ts` and `crates/pty-host/src/agent_state.rs`, read, not
changed.

## The facts

1. **relay-tty's own spawn `exec`s.** `buildSpawnArgs` turns a non-shell
   command into `$SHELL -li -c 'exec <cmd>'`. The exec'd program is the session
   leader, and pty-host's classifier returns `Idle` whenever the foreground
   process group *is* the leader — so an agent started that way is never
   `blocked`. This is the reason `LocalSpawner.buildArgs` has not used `exec`
   since the sidebar existed. Measured again on the box, three runs: a program
   named `claude` started as `{"command": "<program>"}` is pid = pgid = sid and
   reads `idle / foregroundProcess: null` for as long as it waits.
2. **The server resolves a literal `$SHELL`, and treats a shell as a shell.**
   `api.ts` replaces `command == "$SHELL"` with the server user's shell, and
   `buildSpawnArgs` gives any shell `--login` and passes its args through
   untouched. So `{"command": "$SHELL", "args": ["-li", "-c", "<line>\nexit $?"]}`
   arrives at pty-host as `<shell> --login -li -c '<line>\nexit $?'`: the
   wrapper, unexec'd, with the login files read. No server change is needed.
3. **`cwd` is optional, and the answer names the directory.** With no `cwd`
   the server uses its `$HOME` and the 201 body's `session.cwd` says which
   directory that was. 201 is sent only after the session's socket accepts a
   connection, so it is readiness.
4. **The server has no git-root endpoint**, and a remote shell sends no OSC 7
   unless configured to (spike M7 §5). The cwd a client can know is the one in
   the session's metadata.

## The decision

**One seam, `SessionSpawning`, two spawners, one wrapper.** `LocalSpawner` is
the old `RelaySessionSpawner` under its new name and forks `relay-pty-host`;
`RemoteSpawner` is `POST /api/sessions` with the `session` cookie, then
`GET /api/sessions/:id` for the metadata pty-host wrote. Both take a cwd that
may be `nil` ("this machine's home") and complete on the main thread — the
local one before `spawn` returns, as it always did, the remote one when the
server answers, so a tunnel round trip never blocks the main thread. The
remote body is never the program's name:

| what was asked for | the body |
|---|---|
| a command line (`claude --model sonnet`) | `{"command":"$SHELL","args":["-li","-c","'claude' '--model' 'sonnet'; exit $?"],"cwd":…,"cols":…,"rows":…}` |
| a line only a shell can read (`yes \| head`) | `{"command":"$SHELL","args":["-li","-c","yes \| head\nexit $?"],…}` |
| a bare shell (⌘T, ⌘D) | `{"command":"$SHELL","args":[],…}` — the server adds `--login` |
| a shell named outright (`zsh`) | `{"command":"zsh","args":[],…}` — unwrapped, the leader, as locally |

`cwd` is present only when there is one. The `args` after the head are
word-for-word what the local argv carries, and a test compares them.

**A line runs where the focused lane is, and `@name` says otherwise.**
`SpawnPlace {server, cwd}` is one value and `SpawnPlace.resolve` one rule: an
explicit `@name` wins (a remembered directory only if it was on that server,
else the focused lane's if that lane is there, else the server's home);
`@local` is this Mac; otherwise a remembered place wins when it can be used
(a local directory that exists, a server that is connected), and the focused
lane's place is the fallback. ⌘T and ⌘D take the focused pane's place
directly. A remote place's unknown directory is `nil`, which the body omits —
never this Mac's `homeDirectoryForCurrentUser`. A prefix was chosen over a
server column or a chord because the field reads one line: a word at its front
costs nothing when absent, and `@` plus a server's name is what a person
guesses. A `@word` that names no server is left as typed and the row says so.
The LAUNCH row's second line is `server:dir` for a remote place and unchanged
for a local one; the ⌘/ sheet documents the grammar.

**Recents remember the server as `host:path`**, the form the ledger already
uses for a remote project root, in the `cwd` column that exists. No migration.
A recent whose server is not connected is not offered.

**A remote project root is `host:` plus the cwd itself.** No git walk: this
Mac's tree is the wrong tree (ADR-0020), the server offers no answer, and
running `git rev-parse` inside the user's session is typing into his terminal.
The cost, stated: two remote lanes in the same repository but different
subdirectories are two projects until the server can say what the root is
(plan §5; a `GET /api/sessions/:id/git-root`, or the root in the session
metadata, would make this rule one line shorter).

**A failed remote spawn is one line** — `yorkshire: could not start the
session — HTTP 500: <the server's error>` — and because it arrives after the
picker has gone, the picker comes back with `@yorkshire <line>` in the field
and the line in its footer. ⌘T and ⌘D say it in the usual alert.

## What was considered and not done

- **Sending `{"command": "claude"}` and asking relay-tty to drop `exec`.** It
  is the owner's server and the right long-term fix, but the wrapper through
  `$SHELL` needs nothing from the server and works on every relay-tty that
  exists today.
- **Blocking the main thread on the POST**, to keep one synchronous spawn
  shape. Measured at 209–319 ms through the tunnel when healthy, and unbounded
  when it is not.
- **A `recent.server` column.** A migration for a fact the existing column
  can carry in the form the ledger already reads.
- **`maxpane run` on a remote server.** The CLI reaches this Mac's socket; from
  a local shell it keeps spawning locally even beside a remote lane, and from
  a remote shell it does not exist (Phase 4).

## What would make us revisit

relay-tty dropping `exec` (the wrapper becomes redundant, and harmless); a
git-root answer from the server (the root rule); `?token=` on the WebSocket
(nothing here changes: the spawn is HTTP and already authenticated).
