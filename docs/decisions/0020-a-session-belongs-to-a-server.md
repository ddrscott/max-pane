# ADR 0020 — A session belongs to a server; the local server is implicit; the key is the pair

**Status:** Accepted · 2026-09-17
**Decides:** how a relay-tty session on another machine is identified in the
app, given that every id-keyed structure in the app assumed one namespace;
why the local server is never named; and why the key is `(server, id)` and
not a synthesised id. Phase 1 of
[`docs/plans/remote-relay-servers.md`](../plans/remote-relay-servers.md).
**Evidence:** the spike report
[`docs/spikes/07-m7-remote-relay.md`](../spikes/07-m7-remote-relay.md); the
work item [`docs/work/remote-relay-phase1.md`](../work/remote-relay-phase1.md);
`tests/sessions.rs` (the same id on two servers), `RemoteRelayTests.swift`
(the registry, the sidebar, ⌘O, the fake relay server).

## The fact

A relay-tty session id is eight hex characters minted per machine
(`SessionStore` reads its own `~/.relay-tty/sessions` and nothing else; there
is no hub). Two servers will one day mint the same one. The app keyed on the
bare id in six places — the registry, the attached set, DONE, the ledger's
`pane.relay_session_id`, `refuse_second_pane`, and every sidebar and strip
lookup — and each would have silently merged two sessions into one, rarely,
in a way no test would catch (plan §6).

## The decision

**A session is identified by the pair `(server, id)`, everywhere.** `server`
is the name of a `[[servers]]` table in `config.toml`, or `nil` for this Mac.

- In the Rust core, `pane.relay_server TEXT` (migration 0015, NULL = local)
  beside `relay_session_id`; `refuse_second_pane` compares both; the portable
  export carries it and a file without it reads back as local.
- In the shell, `SessionKey { server: String?, id: String }` is the key of
  the registry, the attached set, `doneSince`, `dismissed`, the sidebar's
  rows and the strip's telemetry. `Pane.sessionKey` is the one way a pane
  names its session. A bare string literal is a local key, because the local
  server is implicit; a `String` value never converts.

**The local server is never named.** `[[servers]]` lists remotes only; an
empty list is the app exactly as it was before servers existed, byte for
byte, and the existing suite is the proof. Naming it `local` would have put a
word in every existing ledger row, every session file's path and every log
line for the sake of symmetry the code does not need: the disk source and the
Unix socket are the default case, and a default case is what `nil` is for.

**Why not a synthesised id.** The tempting alternative was one string,
`yorkshire:0368d543`, and no second field. It would have left the six
structures as they were. It was rejected because:

1. **The ledger would lie about its own column.** `relay_session_id` is the
   id pty-host wrote; every other tool on this machine (`relay attach
   4f2a…`) names the session by exactly that string. A column that sometimes
   holds the id and sometimes the id with a prefix is a column whose meaning
   depends on parsing it.
2. **The split would be done in twenty places, each its own way.** The socket
   path, the WebSocket path, the session file, the sidebar's copy-id menu
   item, the ⌘O row and the log all need the bare id back; a pair hands it
   over, a joined string makes each caller find the colon — and a server
   name is the one string a user types, so the colon rule would have had to
   be enforced on it forever.
3. **The compiler could not help.** With a pair, a place that forgot the
   server does not compile (`[SessionKey: …]` refuses a `String`); with a
   joined string, a place that forgot the prefix compiles and merges two
   sessions on the rare day the ids collide, which is the bug this ADR
   exists to prevent.

The pair costs two new core doors (`attach_remote_session`,
`add_remote_pane`) so `create_lane`'s forty local callers stay as they are,
and one test adapter so the sidebar tests written against bare ids keep
reading as they did.

## Consequences

- A remote project root is `host:path`, tagged by `observe_cwd` without
  walking this Mac's tree (plan §4.2); a remote project gathers with itself
  and never with a local path that happens to match.
- The one mark of a remote lane is the server's name where the directory
  sits: `yorkshire:/home/spierce` in the lane header, on the sidebar group,
  and before the id on a ⌘O row. Nothing else changes colour or shape.
- The token is not part of the key and not in the file: it is a Keychain
  item against the server's host (`RelayServerTokens`), which is why a
  server is a name and a URL and nothing more in `config.toml`.
