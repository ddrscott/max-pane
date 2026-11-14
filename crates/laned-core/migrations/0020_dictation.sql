-- Dictation history: what was said into the Dictate popup (F5) and kept
-- there, whether or not it was sent (ADR-0049).
--
-- A row is the text as it stood when it left the popup: sent, or closed with
-- something in the box. Recalling an entry and changing it makes a new row;
-- the one it came from stays. The same text again moves to the top rather
-- than repeating, as paste history does.
--
-- Separate from `clip` on purpose. Paste history is what a pane sent or
-- copied, capped at 64 KB and netted for secrets; this is something you said
-- and may want to say again, edited, into a different pane. What a send
-- actually typed goes to `clip` as well, through the pane's own paste.
--
-- No pane or lane column, for `clip`'s reason. Capped by count from the
-- setting `dictation_history_keep`; never part of a strip export.
CREATE TABLE dictation (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    content TEXT    NOT NULL,
    at      INTEGER NOT NULL
);
CREATE INDEX dictation_at ON dictation (at);
