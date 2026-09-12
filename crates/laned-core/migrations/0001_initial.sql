-- Initial ledger. Shipped; never edit. Add a new numbered file instead.

CREATE TABLE lane (
  id TEXT PRIMARY KEY,           -- ulid
  ordinal REAL NOT NULL,         -- fractional; insert = midpoint; renormalize when gap < 1e-6
  width_pt INTEGER NOT NULL,     -- clamped to [LANE_MIN, LANE_MAX]
  title TEXT,
  project_root TEXT,
  project_source TEXT NOT NULL,  -- 'cwd' | 'inherited' | 'manual'
  created_at INTEGER NOT NULL,   -- epoch ms
  last_focus_at INTEGER NOT NULL,-- epoch ms
  pinned INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX lane_ordinal ON lane(ordinal);

CREATE TABLE pane (
  id TEXT PRIMARY KEY,
  lane_id TEXT NOT NULL REFERENCES lane(id) ON DELETE CASCADE,
  position INTEGER NOT NULL,     -- 0 = top
  kind TEXT NOT NULL,            -- 'pty' | 'web' | 'placeholder'
  relay_session_id TEXT,         -- pty
  url TEXT,                      -- web; kept current on navigation
  scroll_y REAL,                 -- web; restored on rehydrate
  data_store_id TEXT,            -- web; which WKWebsiteDataStore ("shard")
  snapshot_path TEXT,            -- placeholder
  state TEXT NOT NULL            -- 'live' | 'evicted'
);
CREATE INDEX pane_lane ON pane(lane_id, position);

CREATE TABLE pairing (           -- explicit terminal<->web link (optional)
  pty_pane_id TEXT NOT NULL REFERENCES pane(id) ON DELETE CASCADE,
  web_pane_id TEXT NOT NULL REFERENCES pane(id) ON DELETE CASCADE,
  PRIMARY KEY (pty_pane_id, web_pane_id)
);

CREATE TABLE app_state (
  key TEXT PRIMARY KEY,          -- 'strip_scroll_x', 'focused_pane_id', ...
  value TEXT NOT NULL
);
