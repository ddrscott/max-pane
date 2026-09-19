# Remote sessions: you can tell they are remote, and you can tell when the server is gone

The owner, first time using remote lanes for real (2026-09-19), over Relay TTY:

> It's kind of working. We need some kind of indicator when we can't connect to
> the remote server any more. I do see the 3 sessions. I also think we need to be
> able to distinguish the sessions in some other way.

Two things, one task, because they are the same surface: how a remote session
presents itself in the sidebar, the lane header, the gallery and ⌘O.

Read first: `docs/plans/remote-relay-servers.md` §0 ("feels local, distinguished
simply"), ADR-0020/0021/0022, ADR-0015 (one green family), and the project
memory's identity rules. Look at the app as it is: the sidebar puts a small grey
server header (`WSL`) above groups titled `WSL:/home/spierce`, and the rows under
it are pixel-identical to local rows.

## Part 1 — the server is gone, and the app says so

### What happens today (read from the code, 2026-09-19)

- `RemoteSessionSource` (`Terminal/SessionSource.swift`) flips to `.reconnecting`
  only when a `GET /api/sessions` fails: request timeout 15 s, polled on
  `session_poll_seconds`. The relaytty.com tunnel's usual death is *silent* (the
  TCP stays up, nothing answers; seen seven times in two days), so the sidebar
  learns after ~15–20 s at best.
- A lane learns from its own WebSocket: PING every 10 s, zombie at 45 s, then
  the pane's status banner says reconnecting (`TerminalPaneController.swift`
  ~316). So for up to 45 s a dead lane looks alive and swallows typing.
- When the source is `.reconnecting` its sessions stay in the registry looking
  exactly as they did: same glyph, same `idle`/`working` text, stale.
- The only sign is one word, `RECONNECTING`, on the small server header.

### Acceptance Criteria

- **One truth per server, shared.** The source's state and a lane's transport
  state inform each other: when the source goes `.reconnecting`, every lane on
  that server shows it at once rather than waiting out its own 45 s; when any
  lane's transport goes zombie or fails to reconnect, the source checks now
  (`refresh()`) rather than on its next poll. Recovery propagates the same way.
- **Faster, without flapping.** Detect a silent death in ≤ ~15 s (tighten the
  list request's timeout and treat a missed `/ws/events` protocol ping or a
  failed poll as a reason to check now), and do not flip to disconnected on a
  single slow response: one retry inside the window first. State the numbers
  chosen and why in the ADR.
- **The sidebar says it where you look.** On a disconnected server: the server
  header carries the state as a chip in the accent green (`RECONNECTING`,
  `TOKEN REFUSED`, `UNREACHABLE` if retries have gone on past a minute) with the
  last error as its tooltip and in Settings; every session row under it drops
  to the at-rest grey, loses its live state text (no stale `working`), and
  shows `—` or `offline` where the state was; a BLOCKED count from a dead
  server is not counted in the status bar or the Dock badge.
- **The lane says it.** The lane header of a lane on a disconnected server
  shows the same state chip where a state chip goes (next to the title, the
  place `EXITED`/`DONE` use), and the existing pane banner stays. Typing into a
  disconnected lane is not silently dropped: either it is queued and sent on
  reconnect (bounded, say 4 KB, and said so in the banner) or the banner says
  input is not being sent. Pick one, say which and why.
- **The gallery says it.** A tile of a disconnected lane is visibly not live
  (the chip survives at thumbnail scale or the tile dims), since the gallery is
  where the owner looks for "which one needs me".
- **Coming back is quiet and correct.** On reconnect the chip goes, rows get
  their state back from a fresh list, lanes replay from their offset (the
  full-ring-as-delta case from the spike is already handled), with the normal
  fade, no flash.
- **`maxpane server ls` and `maxpane sessions`** report the same state, so it
  is checkable from a shell: a session on an unreachable server lists as
  `offline`, not `idle`.
- No instant transitions; greens for state, grey at rest, Signal Orange only
  for DONE; no new colour; no single-edge rail.

## Part 2 — a remote session is recognisably remote

The plan's rule was "one mark: the server's name where the directory tag sits".
In use that is not enough: the rows are identical and the header text is small.
The owner asked for "some other way". Keep it simple and singular, but make it
land:

- **A server chip, the same everywhere.** A small square outlined chip with the
  server's name (`WSL`), at-rest grey outline and text (it is identity, not
  state, so it is not green), in: the sidebar session row (leading the title or
  trailing, whichever fits the row's grid without pushing the state text), the
  lane header beside the path, the ⌘O session and launch rows, the search
  palette's session hits, and the gallery tile's header. One component, one
  place it is defined. Truncates with an ellipsis past ~10 characters; tooltip
  is the server's URL host.
- **The path stops repeating the server.** With the chip present, a remote
  group reads `/home/spierce` (or `~` relative to the *server's* home when the
  server reports one), not `WSL:/home/spierce`. The ledger's `host:path` tag is
  unchanged; this is presentation.
- **The sidebar's server section reads as a section.** The server header gets
  the `// CAPS` section treatment the identity uses, with the session count and
  the state chip from Part 1, so local and each server are visibly separate
  blocks. Local stays unlabelled unless at least one server is configured; then
  it gets a matching `// LOCAL` header so the blocks are parallel.
- **Optional per-server glyph/colour: no.** Do not add a colour per server. If
  the owner wants more after living with the chip, that is the next round.
- The local look with no servers configured is unchanged, pixel for pixel.

## Tests

- State sharing: a fake server that stops answering (accepts TCP, never
  replies) flips the source within the chosen window; lanes on it flip at the
  same time; one slow response does not flip it; recovery restores both.
- Sidebar model: rows under a disconnected server carry `offline`, no stale
  state, and are excluded from BLOCKED counts; header carries the chip state.
- The chip: present on remote rows/headers/⌘O rows, absent on local ones,
  absent everywhere when no server is configured; path presentation drops the
  `name:` prefix while the ledger tag keeps it.
- Render sheets (`MAXPANE_SHOTS`) for the sidebar connected/disconnected and a
  lane header connected/disconnected, and look at them.
- By hand against the real box, **driven over the control socket** (the owner
  is remote and the screen may be locked; `maxpane server ls`, `maxpane
  sessions`, `maxpane attach`, `maxpane run @NAME` exist for this): stop the
  relay server in its tmux session on the box, watch `maxpane sessions` go
  `offline` within the window, start it again, re-add the token if it changed
  (`maxpane server add` with the same name updates it? check; if not, say so),
  watch it recover. Report timings.

## Docs

README "Remote servers", CHANGELOG, ADR-0023 (supersedes the "one mark is the
name in the path" sentence of plan §0 with "one mark is the server chip", and
records the detection numbers and the typing-while-offline choice). Update the
plan's §0 paragraph to match.

## Constraints

- The app is installed and running at `/Applications/MaxPane.app`; the owner is
  using it remotely. Do not quit it, replace it, or launch anything from your
  shell. Build to `MAXPANE_APP=build/verify.app` and do not run it. The
  orchestrator installs.
- The test server: `docs/work/remote-relay-spike.md`, "The test server". In the
  owner's config the server is named `WSL`. Token read at run time, never
  printed or committed. If you stop the server for the by-hand test, start it
  again, and leave session `0368d543` as found.
