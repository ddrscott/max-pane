# ADR 0048 — Park an idle Claude instead of ending it

**Status:** Accepted · 2026-11-16
**Decides:** what parking is next to ending a session and resuming one, who
does the work, what the sidebar and the pane show, how Park Idle Lanes picks,
how a parked lane stays bound to its conversation, and what happens against
an older relay-tty.
**Evidence:** relay-tty's park work (Thunder task tidzbr: `relay park` /
`unpark` / `keep`, `server/park.ts`, `shared/park.ts` `parkRefusal`); the
owner's machine on 2026-11-16 — 26 `claude` processes, 21 idle more than a
day, about 7 GB resident and heavy swap; ADR-0046; `Terminal/AgentPark.swift`,
`AgentParkTests.swift`.

## The problem

The owner runs twenty-odd lanes of `claude` and forgets to close them. Each
idle one still holds hundreds of megabytes. There were two ways to get the
memory back, and both cost something:

- **End Session (⌃⌘W)** kills the session. The lane goes, its scrollback
  goes, and getting the conversation back means a new lane and a `claude
  --resume` by hand.
- **`/exit` in the lane** keeps the shell and the scrollback, but the pane's
  resume record is forgotten the moment the app sees a live shell with no
  `claude` in it (ADR-0046), so nothing offers to bring it back.

He wanted a third: put this Claude to sleep, keep its lane where it is, and
bring back the same conversation later with one click.

## Decisions

**relay-tty owns the mechanism; Max Pane offers it.** A park has to pick the
Claude out of the session's process tree, refuse while it is busy, write a
`parked` record into the session file, SIGTERM it and confirm the shell
survived. A wake has to type into the pty. All of that is pty-host's and the
server's, and `relay park` does the same from a shell, so it lives there.
Max Pane calls `POST /api/sessions/:id/park` (`{force}`), `…/unpark` and
`…/keep` (`{keep}`) on the local server, at the address relay-tty writes to
`~/.config/relay-tty/server.json`, over loopback, which needs no cookie.
This is the first time the app talks to a *local* server at all; sessions
are still files and sockets for everything else. With no server answering,
a park says so on the row.

**Parking keeps the shell, the session and the lane.** That is the whole
difference from ending. The pane stays attached to a live session; only the
`claude` under its shell is gone. Waking types `claude --resume <id>
<flags>` into that shell, so the conversation comes back in the same pane
with its scrollback above it. No new lane, no rebind.

**A refusal is said on the row, not in a dialog.** relay-tty refuses while
the agent is working or blocked, while Claude reports busy, and when input
arrived after the agent went idle (an unsent draft), and it says why. That
sentence goes on the session's sidebar row, in the chip's place, and on the
lane's banner for a moment. When the refusal is one `force` gets past
(relay-tty's `agent-working`, `agent-blocked`, `claude-busy`,
`unsent-draft`), the row's menu offers **Park Anyway**. A session with no
Claude, or one already parked, is never forced. A modal for "not right now"
would be the loudest thing on the screen for the least important news.

**Park Idle Lanes: quiet both ways, list first, ask once.** The command
looks only at local sessions that have a `claude` running (the agent
reading), on a relay-tty that knows parking, not already parked, whose
output *and* input have both been quiet for `park_idle_after` (24h unless
set). A session talking right now is not "skipped"; it is not idle. Of the
idle ones, kept, blocked, working and drafted sessions are listed as skipped
with their reason. The draft rule is relay-tty's own, to the letter, so the
list never promises a park relay-tty will refuse. Then one confirmation, and
the parks run one at a time, because each can wait 5 s for its Claude to go.
What relay-tty still refused is reported at the end.

**`// PARKED` at the bottom, dimmed, never BLOCKED.** A parked session's
state is idle whatever pty-host last classified or the title still says,
because the process those were about is gone. So it never makes a roll-up,
the footer's alarm, a notification or the Dock bounce. Its row is dimmed,
reads `parked 3d`, and sorts into its own group below every project and
server. Folding `// PARKED` goes through the store like any project's fold,
so it puts the parked lanes away (ADR-0024); folding the project a parked
lane came from does not, because its row is not under that header.

**The pane says `PARKED · <name>` with `$ WAKE`.** The banner's existing
action state, the same one `SESSION GONE · $ RESUME` uses (ADR-0046), and ↩
in the pane presses it. While a wake is on its way the button goes, so a
second ↩ does not type the resume line twice.

**A parked lane stays bound to its conversation.** The `pane_agent` record
is not forgotten while relay-tty says the session is parked, even though the
shell is alive with no `claude` in it — the case that otherwise means "the
agent exited". When the app never saw the agent run (parked before launch,
or from the CLI), the record is written from `parked`. So a reboot that
takes a parked session leaves `$ RESUME`, as it would for any other.

**Keep Lane Loaded is relay-tty's `keep` too.** ⇧⌘P already meant "leave
this lane alone". It now also sets `keep` on the lane's local sessions, from
whichever door it was pressed, so relay-tty's opt-in auto-park and Park Idle
Lanes both pass them by.

**Feature-detected, and nothing else moves.** The items appear only for
sessions whose file carries one of the fields the park work added
(`parked`, `keep`, `lastInputAt`, `foregroundPid`). A park answered with
Express's own 404 for a missing route hides every park item for the rest of
the run. The minimum relay-tty version does not change.

**Remote panes are left out,** for ADR-0046's reason: nothing about a
remote agent is acted on from here. A remote session's `parked` is read and
ignored, and its row stays with its server.

## Rejected

- **End the session and resume into it later.** That is ADR-0046's path for
  a reboot, and it costs the scrollback and a respawn; parking was asked for
  precisely to avoid both.
- **Park from Max Pane directly** (signal the `claude` pid, type the resume
  line ourselves). It would duplicate relay-tty's guards and record in a
  second place, and `relay park` from a shell would not know about it.
- **A dialog for a refused park.** See above.
- **The `relay` CLI as a fallback** when the server is down or lacks the
  route. Tried, and it was wrong in the worst way: relay-tty before park
  reads an unknown first word as a program, so `relay park <id>` starts a
  new session running `park`, exits 0 and looks exactly like success.
- **Auto-park from the app.** relay-tty has its own, off by default
  (`park_after`); a second timer here would be two owners for one decision.

## Revisit when

relay-tty's park route changes shape; remote relay-tty reports a session's
foreground process (remote panes can then join, as ADR-0046 says); or
another agent CLI learns to park.
