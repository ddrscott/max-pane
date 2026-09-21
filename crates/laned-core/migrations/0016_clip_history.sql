-- Paste history: what was pasted into a terminal and what was copied out of
-- one (ADR-0031). Never the system clipboard at large: a row exists only
-- because a terminal pane of this app sent those bytes or copied that text.
--
-- `content` is what went to the prompt or to the clipboard, except when
-- `redacted` = 1: then it is the first four characters and `•••`, written by
-- `clips::redact` before the row is, because the text looked like a secret.
-- The original is never in this file. `line_count` and `byte_count` describe
-- the original either way, so a redacted row still says how much was there.
--
-- No pane or lane column on purpose. A row is for getting text back, not for
-- knowing where it was used, and a row that named its lane would outlive it.
-- Capped by count and by age from the settings (`paste_history_keep`,
-- `paste_history_days`); never part of a strip export, which is lanes only.
CREATE TABLE clip (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    kind       TEXT    NOT NULL CHECK (kind IN ('paste', 'copy')),
    content    TEXT    NOT NULL,
    redacted   INTEGER NOT NULL DEFAULT 0,
    line_count INTEGER NOT NULL,
    byte_count INTEGER NOT NULL,
    at         INTEGER NOT NULL
);
CREATE INDEX clip_at ON clip (at);
