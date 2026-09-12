# ADR 0005 — cwd comes from RelayTTY, three ways

**Status:** Accepted · 2026-09-12
**Decides:** PRD §14 — "How cwd is obtained for remote Relay sessions
(observation-only options; otherwise pty panes on remote sessions stay
`inherited`)."
**Evidence:** [RelayTTY integration reference](../reference/relay-integration.md),
written from the pty-host Rust source.

## Decision

Read cwd from RelayTTY. Do not implement PRD §7.3's `proc_pidinfo` polling in
MaxPane, and do not extend the protocol. Three sources, in preference order:

| Source | Freshness | Works for |
|---|---|---|
| **OSC 7 sniffed out of the `DATA` stream** | sub-second | any session whose shell emits OSC 7 |
| **`~/.relay-tty/sessions/<id>.json`**, watched | ≤ 5 s | local sessions |
| **`SESSION_UPDATE` (0x15)** over WebSocket | ≤ 5.2 s | remote sessions |

A pty pane with no usable cwd stays `inherited`, exactly as §14 allows.

## Why

PRD §7.3 specifies polling the foreground process cwd via
`proc_pidinfo(PROC_PIDVNODEPATHINFO)` every 5 seconds, and falling back to
"whatever cwd Relay already reports" for remote sessions. Reality is better than
the spec assumed: **pty-host already does exactly that polling**, on macOS, via
the same syscall, on the same 5-second cadence, and writes the answer to the
session JSON. Duplicating it in MaxPane would mean two pollers computing the same
number, and MaxPane's would be the one that breaks on remote sessions.

So §7.3's requirement is met by *observation*, which is what §14 asked for, and
the answer is the same for local and remote.

Three details decided the ordering:

**OSC 7 is free and fast.** pty-host reads OSC 7 to update cwd but does **not
strip it** from the output stream — its escape extractor removes only OSC 9, 52
and 1337. So `ESC ]7;file://…` is still in the `DATA` MaxPane is already parsing
to feed the terminal. Sniffing it costs one scan of bytes we hold anyway and
beats the 5-second poll by three orders of magnitude. It is the primary source,
with the others as backstops.

**The 5-second file is the reliable floor.** Both pty-host writers only mark the
session metadata dirty; it reaches disk on a ≤ 5 s flush. PRD §15.3 requires the
tag to update within 10 s, so 5 s clears the bar on its own even if OSC 7 never
appears.

**`SESSION_UPDATE` is the remote answer.** pty-host never emits it — the relay
*server* synthesises it from an `fs.watch` on the session files and broadcasts it
over WebSocket. That makes it exactly the remote equivalent of watching the JSON,
with one trap: it is broadcast to **every WS client of every session**, so the
handler must filter on `session.id` or lanes will retag each other.

## The caveat that matters

pty-host polls `child_pid` — the session leader. For a shell session
(`relay` with no command, or `/bin/zsh`) that is the interactive shell, so cwd
tracks `cd` and everything works.

For a non-shell session (`relay run claude`), `buildSpawnArgs` wraps the command
as `$SHELL -li -c "exec claude"`. The `exec` replaces the shell, so `child_pid`
**is the agent process**, and its cwd is effectively static at the launch
directory.

This is fine, and it is worth being explicit about why: an agent session's
project *is* its launch directory. Claude Code does not `cd` its own process out
of the repo it was started in. The static answer is the correct answer. But it
means "the tag never changes" is expected behaviour for agent lanes, not a bug to
chase.

## Rejected

- **`proc_pidinfo` in MaxPane, per PRD §7.3.** Two pollers, same syscall, same
  cadence; ours breaks on remote sessions and theirs does not. Rejected as
  duplication, not as a bad idea — it is a good idea that is already implemented
  one layer down.
- **Extending the protocol with a cwd push.** Forbidden by PRD §0.3, and
  unnecessary: three observation-only sources already cover it.
- **`foregroundProcess` as a tagging signal.** It is the `comm` name from
  `tcgetpgrp` at 1 Hz, and for Claude Code it is literally the version string
  (`"2.1.268"`) — which is why RelayTTY's own agent-state code has an
  `is_semver_name()` check. Useful for a status glyph. Useless for a project tag.

## What would make us revisit

- A shell in regular use that does not emit OSC 7 *and* a case where 5 s is too
  slow.
- RelayTTY starting to strip OSC 7 from the output stream, which would drop the
  sub-second path to the 5-second one with no error anywhere.
