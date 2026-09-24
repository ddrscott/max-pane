# ADR 0039 — End Session, Clear Scrollback and Rename Lane: what "end" means, what ⌘K touches, and where a name lives

**Status:** Accepted · 2026-09-23
**Decides:** how a session is ended, locally and remotely, and why not
through the wire's `SIGNAL`; what closes afterwards and when; what ⌘K
clears and what it leaves; where a lane's name is written and why a
terminal's is pinned on the session; the three chords.
**Evidence:** the Omarchy critique [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F10;
the work item [`docs/work/omarchy-f10-end-session.md`](../work/omarchy-f10-end-session.md);
[`docs/reference/relay-integration.md`](../reference/relay-integration.md) §2 (`SIGNAL`,
`SET_TITLE`, `CLEAR_SCROLLBACK`), §8 (`DELETE /api/sessions/:id`), §11 (pinning);
relay-tty `cli/commands/kill.ts`, `cli/commands/rename.ts`, `cli/sessions.ts`
(`stopSession`), `server/api.ts` (`router.delete`), `server/pty-manager.ts`
(`kill`), `crates/pty-host/src/main.rs` (the SIGTERM task, the SIGNAL task);
`Terminal/SessionEnder.swift`, `Terminal/RelayAttachmentAdapter.swift`
(`setTitle`), `Views/StripViewController.swift` (`renameLane`),
`Views/LaneHeaderModel.swift` (the title rule); `EndSessionTests.swift`.

## The problem

Day-one #5 stood through nine rounds: no way to end a session, clear a
terminal or name a lane. ⌘W and ⇧⌘W detach and the sidebar row lives on —
right for an agent you mean to come back to, wrong for the `htop` you are
done with, and the only way out was a terminal somewhere else and `relay`.
Omarchy's `Super+W` closes; a terminal's ⌘K clears; tmux's `,` renames.

## Decisions

**End means `SIGTERM` to pty-host's own pid — relay-tty's *stop session*,
in both of its forms — and never `SIGNAL` (0x25) on the wire.** Locally
the app reads the pid from `~/.relay-tty/sessions/<id>.json` and sends the
signal itself, which is what `relay`'s `stopSession` does when no server
answers; the app never needed a relay server for a local session and does
not start needing one for this. Remotely it is `DELETE /api/sessions/:id`
with the cookie, and the server signals its own pty-host and drops the
row. pty-host's handler `SIGTERM`s the session leader, writes
`status: "exited"`, removes the socket and exits; closing the PTY master
hangs up whatever the shell had left. `SIGNAL` was the tempting one — it is
already an encoder away — and it is wrong: it reaches the *foreground
process group*, so a shell whose `claude` it killed is back at its prompt
with the session alive. That is `relay kill`, a Ctrl-C from afar, and the
sheet would be lying. `DETACH` is the same lie with `SIGHUP`. A pid already
gone (`ESRCH`) is success: the session ended first.

**The pane is closed in the ledger by the app, after the kill went
through, not by waiting for an `EXIT`.** pty-host's SIGTERM path promises
no `EXIT` frame — it `process::exit`s right after writing its file — so the
socket simply closes and the pane would sit at `RECONNECTING` forever. The
close is `closePane`, so a split lane keeps its other pane and a lane whose
last pane this was goes with it, by the strip's one leaving animation. A
refusal (404, a guest's 403, a box that is off, a file with no pid) leaves
the lane where it is and says why: a pane closed over a session still
running would be the sidebar's problem to find again.

**A sheet first, ↩ on Cancel.** It names what it is about to kill and where
— the session's title or command line, the program, `this Mac` or the
server — and says that every client loses it, the phone included. The
same `ConfirmPopup.confirm(returnConfirms: false)` as Clear Paste History.
Reached from ⌃⌘W, File › End Session…, and the ⋯ menu's last item on a
terminal lane, under Close Lane.

**⌘K is Ghostty's `clear_screen` in this pane's emulator and nothing on
the wire.** The scrollback goes and every row above the cursor, so the last
prompt is the first line; Ghostty declines on the alternate screen. relay's
`CLEAR_SCROLLBACK` (0x23) was considered and refused: it empties the ring
for every client, which is the phone's scrollback too, and ADR-0007's rule
is that a lane does not reshape the session for the others. The cost is
that a fresh attach at the next launch replays what ⌘K cleared, and the
search index keeps what it saw, as it does across a `clear`. In a web pane
⌘K yields to the page (`yieldsToPage`), the way ⌥⇧⌘V does: Slack, Linear
and Notion bind it.

**A lane's name is written to the ledger and, for a terminal lane, pinned
on the session with `SET_TITLE`.** `LaneHeaderModel` reads the ledger's
`title` first, so the header changes at once — but a terminal's ledger
title is *fed by* the session: `adoptTitle` writes every `TITLE` frame into
the same field, and a name only the ledger held would last until the
program's next OSC title, which for Claude Code is its next spinner frame.
Rather than a `title_pinned` column and a migration, the name goes where
relay already has pinning: `SET_TITLE` is `relay rename`, pty-host stops
honouring OSC titles, writes the name to its file and broadcasts `TITLE`
to every client, so the phone's list says it too and the next launch's
handshake replays it. Empty unpins and clears the ledger's title. The
accepted cost: a renamed Claude lane no longer carries the spinner, so
`AgentState.derived`'s title rule does not fire and WORKING is relay's own
reading (rule 4). A web lane has no session and its name lasts until the
page next sets a `<title>` — the honest version of "pinned" without a
column, and named in the README.

**The chords.** ⌃⌘W: one modifier further than ⇧⌘W on the same key, as
⌃⌘[ is to ⌘[; macOS's ⌃⌘ chords are Space, F, Q and D. ⌘K: every Mac
terminal's clear, nobody's here. ⌃⌘R: the letter of the name, beside ⌘R and
⇧⌘R which reload and ⌃⇧⌘R which resizes; nothing on macOS or in a browser's
chrome has it. All three rebindable under `[keys]`, in a menu, in ⌘/ and
in ⌘E.

## Consequences

- `SessionEnding` is one protocol with two implementations, chosen by the
  pane's server as the spawner is; a stranger server is an error by name.
- The fake relay server answers `DELETE`; the local ender is proved on a
  `sleep` the test owns, never on a session in `~/.relay-tty`.
- `RelayAttachment` grows `setTitle`, a no-op on every stub wire.
- The header's double-click, unspoken for since the header was written, is
  rename.
- Refused: `SIGNAL` or `DETACH` as an end; `CLEAR_SCROLLBACK` on ⌘K; a
  `title_pinned` column; a rename that waits for the session's `TITLE`
  before showing.
