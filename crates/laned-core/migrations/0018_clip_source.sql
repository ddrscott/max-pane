-- Where a paste-history row came from (ADR-0041): a terminal pane, or a web
-- pane's own ⌘C. Everything else about the row is unchanged — a row is still
-- only here because a pane of this app sent or copied those bytes, and the
-- clipboard at large is still never read.
--
-- `pty` for every row that already exists: until this migration the only
-- writer was a terminal.
ALTER TABLE clip ADD COLUMN source TEXT NOT NULL DEFAULT 'pty'
    CHECK (source IN ('pty', 'web'));
