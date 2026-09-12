-- Two things the strip forgot across a restart.
--
-- 1. `interaction_state` is `WKWebView.interactionState`: the whole of a web
--    pane's session — back/forward list, scroll offset, form contents — as one
--    opaque blob WebKit hands out and takes back. The `url` column alone brings
--    a pane back to the right address at the top of the page with no history,
--    which is not the pane you left.
--
-- 2. `recent` is the MRU behind the new-pane picker: what you last ran and
--    where, what you last opened. Kept in the ledger rather than a plist
--    because it is layout memory like everything else here, and because the
--    picker is only as fast as the thing it reads.
ALTER TABLE pane ADD COLUMN interaction_state BLOB;

CREATE TABLE recent (
  kind TEXT NOT NULL,            -- 'command' | 'url'
  value TEXT NOT NULL,           -- the command line, or the URL
  cwd TEXT,                      -- 'command' only: where it last ran
  -- Order is `seq`, not `last_used_at`. A wall clock has milliseconds and ties,
  -- and two launches inside one millisecond then come back in whatever order
  -- SQLite feels like — which showed up immediately in test, never mind a
  -- script that opens three panes at once. `seq` is a counter, so it is exact
  -- and it does not care what the clock does.
  seq INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL, -- epoch ms; for display ("2m ago")
  use_count INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (kind, value)
);
CREATE INDEX recent_mru ON recent(seq DESC);
