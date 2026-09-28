-- The agent a terminal pane was last seen running, so a reboot is not the end
-- of the conversation (ADR-0046).
--
-- A reboot kills every relay-tty session. The pane comes back from the ledger
-- knowing only its `relay_session_id`, which is now dead, and the thing worth
-- getting back — the `claude` conversation that was running in it — was never
-- the ledger's to know. This is where it is kept: which CLI, which of its
-- sessions, where it ran and with what flags. Written while the agent is alive
-- (Claude Code deletes its own `~/.claude/sessions/<pid>.json` on exit, so it
-- cannot be read afterwards) and read when the pane's session is gone.
--
-- Its own table rather than columns on `pane`: most panes never run an agent,
-- the record is written on a poll and never belongs in the strip's snapshot,
-- and a row that is either there or not is the honest shape of "this pane had
-- an agent". The cascade is the rule that a pane closed on purpose takes its
-- record with it, whichever door closed it.
--
-- `args` is a JSON array of the flags the agent was started with, already
-- cleaned of any `--resume`/`--continue` so a resume does not stack them.
CREATE TABLE pane_agent (
  pane_id    TEXT PRIMARY KEY REFERENCES pane(id) ON DELETE CASCADE,
  cli        TEXT NOT NULL,
  session_id TEXT NOT NULL,
  cwd        TEXT NOT NULL,
  args       TEXT NOT NULL DEFAULT '[]',
  name       TEXT,
  updated_at INTEGER NOT NULL
);
