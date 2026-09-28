# ADR 0046 — The pane keeps its agent's session id

**Status:** Accepted · 2026-09-28
**Decides:** where the conversation a terminal pane was running is kept, when
it is written and forgotten, what a resume runs and where it lands, how
Resume All behaves, and why remote panes are left out.
**Evidence:** the work item [`docs/work/resume-agents-after-reboot.md`](../work/resume-agents-after-reboot.md),
including what the stopgap's first real run taught; the stopgap scripts
(`~/.config/maxpane/resume/snapshot.sh`, `resume.sh`); Claude Code's
`~/.claude/sessions/<pid>.json` as found on the owner's machine;
`crates/laned-core/migrations/0019_pane_agent.sql`,
`Terminal/AgentSessions.swift`, `StripWindowController.swift` (the resume
extension); `crates/laned-core/tests/agents.rs`, `AgentResumeTests.swift`.

## The problem

The owner runs a dozen or more lanes, each holding its own `claude`
conversation. A reboot kills every relay-tty session. The lanes come back
from the ledger, but each pane knows only its `relay_session_id`, which is
dead, so the way back was `claude --resume` by hand in the right directory,
one at a time, remembering which was which. A stopgap outside the repo
proved the data is there and all fourteen conversations came back — and it
also resumed one of them twice, because it was run from inside a lane it
listed.

## Decisions

**A `pane_agent` table, one row per terminal pane, not columns on `pane`.**
`cli`, `session_id`, `cwd`, `args` (JSON), `name`, `updated_at`. Most panes
never run an agent; the row is written on a poll and read when a session
dies, and nothing that draws the strip reads it, so it stays out of
`StripState` and costs the snapshot nothing. `cli` is a string, so another
agent CLI can join without a migration; only `claude` is resumable today.

**Written while alive, from Claude's own file.** Claude Code writes
`~/.claude/sessions/<pid>.json` (`sessionId`, `cwd`, `name`, `kind`) and
deletes it on exit, so it cannot be read after the reboot — it has to be
copied before. On each session poll a reading is taken off the main thread:
the files, one `sysctl(KERN_PROC_ALL)` for the process table, and
`KERN_PROCARGS2` for each live agent's argv. Each pid is walked up to the
`relay-pty-host` whose pid a relay session file names; that is the pane.
Only `kind == interactive` counts. The argv loses `--resume`/`-r` (with a
value only when the next word is not a flag — a bare `--resume` is a
picker), `--resume=`, `--continue`/`-c`, `--session-id` and
`--fork-session`, so a resume names the conversation once. The ledger is
written only when what is seen differs from what is kept.

**Forgotten in three ways, and a dead session is not one of them.** Closing
the pane on purpose removes the row by `ON DELETE CASCADE`, whichever door
closed it. A *live* session with no `claude` process under it forgets it:
the agent exited and the shell lived on. A lane started as `claude` itself
closes on exit like any exited session, and the row goes with it. A
session that is simply gone — the reboot, or a `kill -9` of pty-host —
changes nothing: that is what the record is for. "No `claude` process" is
asked of the process table, not of the files, because a resumed agent can
take several seconds to write its file (a minute, once, in the stopgap's
run) and a missing file is not an exit. A pane just resumed is also held
for thirty seconds against being forgotten.

**`$ RESUME` on the pane, in place.** A local terminal pane whose session is
not running and which has a record shows `SESSION GONE · <name>` with
`$ RESUME` — the banner's existing action state (ADR-0038), in place of a
`RECONNECTING` that would be untrue. ↩ in the pane presses it; Resume Agent
is in the File menu and ⌘E with no default chord, since once after a reboot
is not a chord's worth of use. A resume spawns through the ordinary local
spawner, in the recorded directory, at the pane's own measured grid, and the
ledger's new `rebind_pane_session` moves **the same pane** to the new
session — lane, position, height and zoom untouched — refusing a session
another pane holds, as every other door does. The controller drops the dead
attachment, clears the screen the dead session left, and attaches.

**The resume's line unsets the API key after the login files.** The spawner
already scrubs `CLAUDECODE` and `CLAUDE_CODE_*` from every pane's
environment. `ANTHROPIC_API_KEY` comes from the owner's rc files, which the
login shell reads *after* the environment is handed over, so dropping it
from the environment alone would not hold. The line is `unset
ANTHROPIC_API_KEY CLAUDECODE …; 'claude' '--resume' '<id>' <flags>`, run by
the same `$SHELL -li -c '…\nexit $?'` wrapper, so a resumed agent still has
a shell above it and can be BLOCKED. Claude Code happening to have the key
on its reject list is not something to depend on.

**Resume All: left to right, staggered, each conversation once, never one
already open.** Strip order is the ledger's — lanes by ordinal, panes top to
bottom, docked and folded lanes included, since the reboot killed their
sessions too. One start every 0.8 s. A conversation a live process claims
right now (the files, with a signal-0 check) is skipped and said so; two
panes remembering the same conversation resume it once. It is offered once
after a launch that finds something to resume, as `$ RESUME N AGENTS ×` in
the status bar, and **never runs by itself**. `maxpane resume [--all|LANE]`
is the same from a shell, and prints a line per pane: resuming or skipped,
and why.

**Remote panes are left out.** A remote relay-tty lists sessions and their
metadata, and nothing about the processes inside one; there is no way from
this Mac to learn which conversation a remote `claude` has open. Remote
panes are neither recorded nor offered a resume, and the README says so.

## Rejected

- **Automatic resume at launch.** Twelve agents starting unasked is a lot of
  work, a lot of tokens and possibly the wrong twelve. One click.
- **Reading the relay session file's `command`/`args`.** Right for a lane
  started as `claude …`, wrong for the common case of a shell where `claude`
  was typed, and it never knows the conversation id.
- **Resuming into a new lane,** as the stopgap did. The pane already has a
  place, a height and a zoom the owner chose; a new lane loses all three
  and leaves a dead pane behind.
- **Columns on `pane`.** Every snapshot would carry them across the FFI for a
  value that is read once after a reboot.

## Revisit when

relay-tty exposes a session's foreground process and its argv (remote panes
can then join); another agent CLI earns a resume line; or the conversation
file format moves out of `~/.claude/sessions`.
