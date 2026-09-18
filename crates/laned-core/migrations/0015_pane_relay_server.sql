-- Which relay-tty server a pty pane's session lives on.
--
-- NULL is this Mac: the session's socket is under ~/.relay-tty and the pane
-- attaches over it exactly as before this column existed. A name is one of
-- the `[[servers]]` in config.toml, and the pane attaches to that server's
-- `/ws/sessions/:id` over a WebSocket instead. Session ids are eight hex
-- characters minted per machine, so two servers will one day mint the same
-- one; every lookup that used to key on the bare id keys on the pair now,
-- and "already on the strip" is asked of (server, id). See ADR-0020.
ALTER TABLE pane ADD COLUMN relay_server TEXT;
