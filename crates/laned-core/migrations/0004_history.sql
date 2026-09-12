-- Browsing history. The one browser feature with no partial version: either it
-- is recorded from the first visit or the record has a hole in it.
--
-- One row per URL, not one row per navigation. A visit log would be the more
-- literal record, but nothing in this app ever asks "when were the eleven times
-- I opened the PR" — it asks "where was that page", once, and wants one line
-- back. Aggregating on write means the palette never has to de-duplicate on
-- read, and it is what keeps a page you live in from burying a page you saw
-- once.
CREATE TABLE visit (
  url TEXT PRIMARY KEY,          -- normalized; see history::normalize_url
  title TEXT,                    -- the page's <title>, when it ever produced one
  -- Order is `seq`, not `last_visit_at`, for the same reason `recent` orders by
  -- a counter (0003): a wall clock has ties, and two settles inside one
  -- millisecond — a redirect landing, a restored strip rehydrating eight panes
  -- at once — then come back in whatever order SQLite feels like. History is
  -- read newest-first and nothing else, so the ordering key may not be the one
  -- thing in the row that is allowed to be ambiguous.
  seq INTEGER NOT NULL,
  first_visit_at INTEGER NOT NULL, -- epoch ms; never moves
  last_visit_at INTEGER NOT NULL,  -- epoch ms; for display ("2m ago") and pruning
  visit_count INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX visit_mru ON visit(seq DESC);
-- Pruning deletes by age; without this it is a full scan of the table on a
-- cadence that runs while the user is navigating.
CREATE INDEX visit_age ON visit(last_visit_at);

-- Where a redirect started.
--
-- You ask for `example.com` and land on `https://www.example.com/en`. The entry
-- is the address you ended on — that is the page that has a title, and the one
-- that reopens to what you saw. But if that is *all* that is kept, typing back
-- the thing you actually asked for finds nothing, which is precisely the hole
-- this table exists to close. The requested address is not a second history
-- row: it is not a page you saw, it has no title of its own, and listing it
-- would show the user two lines for one visit. It is an alias — searchable,
-- never listed.
--
-- CASCADE because an alias to a pruned entry is a pointer to nothing; the
-- ledger opens with `foreign_keys = ON`, so this is enforced rather than hoped.
CREATE TABLE visit_alias (
  alias_url TEXT PRIMARY KEY,
  url TEXT NOT NULL REFERENCES visit(url) ON DELETE CASCADE
);
CREATE INDEX visit_alias_target ON visit_alias(url);
