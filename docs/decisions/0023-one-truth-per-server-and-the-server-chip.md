# ADR 0023 — One truth per server, shown everywhere at once; the one mark of a remote session is the server chip

**Status:** Accepted · 2026-09-19
**Decides:** how fast a dead remote server is noticed and by whom; how the
session list's verdict and a lane's own wire inform each other; what a
disconnected server looks like on every surface; what happens to typing while
a lane is offline; and what marks a remote session as remote.
**Supersedes:** the sentence of [ADR-0020](0020-a-session-belongs-to-a-server.md)
and of plan §0 that says the one mark of a remote lane is the server's name
where the directory sits (`WSL:/home/spierce`). The mark is now the server
chip. Everything else in ADR-0020 stands, the ledger's `host:path` tag
included.
**Evidence:** the work item [`docs/work/remote-presence.md`](../work/remote-presence.md);
`RemotePresenceTests.swift` (a fake server that accepts TCP and never
replies, one slow response, a missed pong, a lane losing its wire, the
sidebar model, the chip, the render sheets, and `LivePresenceTests` against
the real server frozen with `kill -STOP`).

## The facts

1. **The owner, first day of real use (2026-09-19):** "We need some kind of
   indicator when we can't connect to the remote server any more … I also
   think we need to be able to distinguish the sessions in some other way."
2. **The relaytty.com tunnel dies silently.** The TCP stays up and nothing
   answers; seen seven times in two days. A frozen server is the same from
   here: the edge still answers a WebSocket upgrade with 101 and then says
   nothing (spike M7 §3).
3. **Before this, the two halves learned separately and slowly.** The list
   (`RemoteSessionSource`) flipped only when `GET /api/sessions` failed on a
   15 s timeout; a lane learned from its own socket, `PING` every 10 s and a
   zombie at 45 s. For up to 45 s a dead lane looked alive and swallowed
   typing, and a dead server's sessions kept their last `working` and
   `BLOCKED` in the sidebar, the status bar and ⌘O.
4. **The one mark was not enough.** A remote sidebar row was pixel-identical
   to a local one, and `WSL:` in front of a path was one more run of grey
   text in a path.

## Decision

### 1. One truth per server, held by the registry

A server's state is the state of its session-list source, and the registry
stamps it on every session of that server (`SessionTelemetry.connection`) on
every reading and on every change of the server's state. Every surface that
holds a telemetry value therefore already has it: there is no second channel
to disagree with.

**Offline is `.unknown`.** While `connection` is anything but connected,
`SessionTelemetry.state` is `.unknown` and `badgeText` is `offline`. A server
that has stopped answering cannot vouch for `working` or `BLOCKED`, and a
stale BLOCKED is worse than none: it pulls the owner across the room to a
prompt he cannot answer. Masking it in the one value rather than at each
surface is what keeps the sidebar, the header, the tile, ⌘O, ⌘P, the status
bar's BLOCKED count and the Dock bounce (there is no Dock badge) from
disagreeing. DONE is still decided on what the server *reported*
(`reportedState`), so an agent that finished during an outage is DONE when
the server comes back; and on recovery the source publishes the fresh list
*before* its state, so no stale state is shown for even one turn.

**The two halves inform each other.** When the source goes quiet the strip
tells every pane on that server (`TerminalPaneController.serverStateChanged`):
the banner changes at once, and the attachment is asked to prove its wire —
a `PING` with a 4 s deadline, after which a half-open socket closes as a
zombie and enters the reconnect loop. A wire that answers is left alone: the
list being down is no reason to cut a session that works. The other way,
an attachment whose wire goes on its own — a zombie, a failed read, a
reconnect that cannot open — reports it (`onWireLost`), and the registry
makes that server's source check now (`laneLostWire`). Recovery runs the same
road: a lane waiting out a backoff of up to 15 s reconnects the moment its
server is back, and one whose attempt is hanging on a silent 101 is tested
the same way.

### 2. The numbers

| | | why |
|---|---|---|
| list request timeout | **4 s** (was 15) | a healthy answer through relaytty.com is well under a second; 4 s is slow-network generous and still leaves room for a retry inside the window |
| verdict | **two failures in a row** | one slow or dropped response must not flip the sidebar to RECONNECTING and back; the first failure while connected is retried half a second later (two failures a millisecond apart, as after a wake, are one failure), the second is believed |
| poll | `session_poll_seconds`, default **5 s** | unchanged |
| `/ws/events` protocol ping | every **5 s**, pong within **4 s** | a missed pong is the same evidence as a timed-out request: it counts as the first failure and the list is asked for now, which is the retry. Through a tunnel the edge may answer pings for a server frozen behind it, so this is a helper, not the detector |
| lane's pong deadline once its server is off | **4 s** | one round trip is tens of milliseconds; 4 s matches the list's timeout |
| `RECONNECTING` → `UNREACHABLE` | **60 s** | the same condition with a more honest word; still retried on the poll |

Worst case from a silent death to `RECONNECTING` with the default poll:
5 + 4 + 0.5 + 4 = **13.5 s**. With a longer `session_poll_seconds` the ping path
bounds it at the same 13.5 s where pings reach the server, and the poll
bounds it otherwise. Recovery is the first list that arrives.

**Measured against the real server** (relay-tty 1.23.0 behind relaytty.com,
frozen with `kill -STOP` on its node process, two rounds, shipped numbers):
the source went offline **11.5 s and 9.9 s** after the freeze, error `The
request timed out.`; the lane's own wire agreed 4.0 s later in both (in the
app the banner, the header and the sidebar change with the source, not with
the wire); after `kill -CONT` the source was back in **under 0.1 s and
0.7 s**, and the lane had re-attached within **0.1 s** (the attempt hanging
on the edge's 101 completes its handshake the moment the server thaws). In
20 s of a healthy server the source made 4 list requests — the polls and
nothing else — so the ping is answered end to end and does not churn.

### 3. What disconnected looks like

Greens for state, grey at rest, no new colour, no single-edge rail, and
every change eased (`Motion.fade`, the strip's 0.22 s ease-out for the tile).

- **Sidebar.** The server's section header carries the state as a square
  outlined chip in the accent green — `RECONNECTING`, `UNREACHABLE`,
  `TOKEN REFUSED` — beside its session count, with the last error as the
  tooltip (and on its row in Settings, and in `maxpane server ls`). Every row
  under it drops to the at-rest grey: hollow square, grey title, `—` where
  the state glyph was, `OFFLINE` where the rate or `idle` was, no chip. Its
  project groups count `N OFFLINE`, not `N RUNNING`. A remote lane restored
  while its server was already gone — so the registry has never seen its
  session — reads `offline`, not `gone`/`EXITED`.
- **Lane header.** The server's state takes the state chip's place and shape
  (outlined, accent green, never filled or moving: those are BLOCKED's), a
  glyph when there is no room for the word, and the status square goes hollow.
- **Pane banner.** `RECONNECTING · INPUT IS NOT BEING SENT` (or
  `UNREACHABLE · …`), from the server's verdict or the wire's, whichever is
  first.
- **Gallery.** A tile of a lane on a dead server dims to 0.45. No chip
  survives thumbnail scale, and the gallery is where the owner looks for
  "which one needs me". On the strip the lane is not dimmed: the chip and the
  banner say it at full size, and reading the scrollback is the one thing
  still possible.
- **Status bar.** `5 sessions · 3 offline`; offline sessions are never in
  the BLOCKED or working counts.
- **CLI.** `maxpane sessions` prints `offline` for such a session, never the
  `idle` it last was; `maxpane server ls` prints `reconnecting` or
  `unreachable` and the error. `maxpane server add NAME '<line>'` with a name
  that exists replaces that server's token (same host only), which is what a
  restarted server needs from a shell.

### 4. Typing while offline: not sent, and said

The banner says `INPUT IS NOT BEING SENT`, and that is the choice: input is
**not queued for the length of an outage**. The adapter already holds what is
typed at a pane with no wire (`PendingInput`, up to 64 KB) and sends it if the
wire returns within **5 s** of the first held byte, so a blip of a reconnect
loses nothing; anything older is dropped, and the pane now says so in one line
when it happens (`N BYTES TYPED WHILE DISCONNECTED WERE NOT SENT`) rather than
only in the log. The alternative — queue 4 KB and replay it on reconnect — was
rejected: what is on the other end is usually an agent at a prompt, and a
`y⏎` typed at one question must not land on a different one a minute later.
A keystroke lost and said is recoverable; a keystroke delivered to the wrong
prompt is not.

### 5. The one mark is the server chip

`ServerChip`: a small square outlined chip with the server's name, at-rest
grey outline and text (identity, not state, so not green), cut with an
ellipsis past ten characters, tooltip the server's URL host. One component,
defined once, used in: the sidebar's session row (leading the second line,
under the start of the title, so the title keeps every character and the
state text is not pushed), the lane header beside the path — and so the
gallery tile's header —, ⌘O's session and launch rows, and ⌘P's session and
search-hit rows. No colour per server; if the chip is not enough, that is
the next round.

With the chip present the path stops repeating the server: a remote group
reads `/home/spierce`, a remote header path `/home/spierce/m7out`, a ⌘O
launch row `/home/spierce/proj` or `~` for the server's home. The path is as
the server gave it and is never abbreviated against this Mac's `$HOME`;
relay-tty does not report the server's home, so `~` is not derived for a
remote path. The ledger's `host:path` tag, the group's key and the `Recent`'s
remembered place are unchanged: this is presentation.

The sidebar's server header is a section: `// WSL` in the house `// CAPS`
treatment (slashes in the accent green, as the ⌘/ sheet's are), with the
count and the state chip. Beside at least one server, this Mac gets a
matching `// LOCAL`, so the blocks are parallel. Path groups still carry no
`//`: they are literal paths, and `//` is path syntax.

**With no server configured nothing changes, pixel for pixel**: no section
header, no chip is ever built, `connection` is nil. Verified by rendering the
existing local sheets (lane headers at three widths, sidebar rows in every
state, the bookmarks bar) before and after and comparing the PNGs byte for
byte.

## Consequences

- A `session_poll_seconds` raised well past 5 slows detection where the
  tunnel's edge answers pings on the server's behalf; the README says so.
- `ServerState` gained `.unreachable`; anything that switched on it says what
  it does with the new case.
- A server that answers its list but whose session sockets are dead is shown
  per lane by the wire's own banner, as before; the server's chip stays off.
