# Resume agent sessions after a reboot

## Problem
Scott runs a dozen or more terminal lanes, each holding its own `claude` conversation. A reboot kills
every relay-tty session. The lanes come back (the ledger keeps them), but each pane only knows its
`relay_session_id`, which is now dead, so there's no way back into those conversations short of
`claude --resume` by hand in the right directory, one at a time, while trying to remember which was
which. He wants to get back to roughly the same state in one move.

A stopgap exists outside the repo (`~/.config/maxpane/resume/snapshot.sh` + `resume.sh`, 2026-09-28):
it proves the data is available and is the behaviour to beat.

## Where the data comes from
- Every running Claude Code writes `~/.claude/sessions/<pid>.json` with `sessionId`, `cwd`, `name`,
  `status`, `kind` (only `interactive` counts). It's deleted when claude exits, so it must be captured
  while the agent is alive.
- Walk the pid's parents to `relay-pty-host <relay-session-id> …` to find which pane it's in.
- The flags it was started with come from its argv (`ps -o args=`); drop any `--resume/-r <id>` and
  `--continue` so the resumed session doesn't stack them.

## What to build
1. **Record while alive.** The core keeps a per-pane "agent" record: cli (`claude` for now; shape it so
   codex etc. can join), session id, cwd, argv flags, name, updated time. MaxPane refreshes it on the
   existing agent-status poll. It's kept after the session dies, and cleared when the pane is closed on
   purpose or the agent exits cleanly while the pane's shell lives on.
2. **Resume one.** A pane whose session is gone and that has an agent record shows its dead banner with a
   `$ RESUME` action (keyboard reachable) and the conversation's name. Resume spawns a fresh relay session
   in the recorded cwd running `claude --resume <id> <flags>` through the normal spawner, and rebinds
   *the same pane* (same lane, position, height, zoom) to it. No new lane.
3. **Resume all.** A command (menu + palette + `maxpane resume [--all|LANE]` in the CLI) resumes every
   resumable pane, left to right, staggered so a dozen `claude` starts don't stampede. After launch
   following a reboot, offer it once in a quiet, dismissable way: "12 agents can be resumed".
4. **Remote panes:** same rule against the remote server when its relay-tty exposes the info; if it
   can't, leave remote panes out and say so in the doc.

## Acceptance Criteria
- Kill a pane's relay session (stand-in for a reboot) with a recorded agent → pane shows RESUME; resume
  lands `claude --resume <id>` in the right cwd, in the same pane, with the original flags.
- Resume all does every resumable pane in strip order and skips ones with no record.
- A pane whose agent had exited normally before the reboot is not offered a resume.
- Record survives app quit/relaunch (it's in the ledger, a migration).
- Tests: core record round trip; the argv cleanup; a spawner test that the resume command line is right.
- README section, CHANGELOG Unreleased, an ADR for "the pane keeps its agent's session id".

## Learned from the stopgap's first real run (2026-09-28)
- All 14 conversations came back. But `resume.sh` was run from inside one of the lanes it listed, so it
  resumed *that* conversation a second time: two `claude` clients on one conversation. Never resume a
  session id that a live `~/.claude/sessions/<pid>.json` already claims.
- A resumed session can take several seconds to write its `sessions/<pid>.json` (salesflow hadn't
  after a minute), so "resumed" means the process is up, not the file. Don't read a missing file as
  failure.
- Panes carry `ANTHROPIC_API_KEY` from Scott's shell. Claude Code has that key in
  `customApiKeyResponses.rejected`, so interactive sessions still use the Max login. The spawner should
  still drop it (and `CLAUDECODE` / `CLAUDE_CODE_*`) from a resume's environment rather than depend on that.

## Relevant Files
- crates/laned-core/src/model.rs (`Pane`), ledger migrations
- swift/MaxPane/Sources/MaxPaneKit/Terminal/SessionSpawner.swift, TerminalPaneController.swift
  (`sessionAvailabilityChanged`, resting banner)
- the existing agent status detection (WORKING/BLOCKED/DONE) — reuse its poll
- the `maxpane` CLI helper

## Constraints
- Never spawn claude with `ANTHROPIC_API_KEY` or Claude's child-session env leaked in (see the
  scrubbed-env rule); resumed agents must bill the Max subscription and save transcripts.
- Don't auto-resume without being asked; the post-reboot offer is one click, not automatic.
- Workers must not launch, quit or replace the installed app.
