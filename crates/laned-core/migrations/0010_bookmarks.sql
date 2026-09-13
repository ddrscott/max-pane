-- Bookmarks: the pages you keep, as against the pages you have been to.
--
-- `WebChromeBar` used to carry the sentence "the strip is the bookmarks bar and
-- a pinned lane is the star", and that was a real cut rather than an oversight:
-- a lane you have docked *is* a page you have decided to keep in front of you.
-- What it does not do is survive not being on screen. The owner keeps eight
-- folders on Vivaldi's bar and opens them daily, and a docked lane is one page
-- at a time, held by occupying a column that the strip is otherwise for.
--
-- # Why this is not a column on `visit`
--
-- The two records answer different questions and have different lifetimes. A
-- visit is a fact about the past, aggregated on URL, whose title is whatever
-- the page last called itself and which `Clear` is allowed to delete. A
-- bookmark is a decision, its title is one the user may have rewritten, it
-- lives at a place in a tree, and it must outlive clearing history — which a
-- flag on `visit` could not, because `clear_history` deletes rows and a flag
-- cannot stop a delete without turning every history statement into a
-- conditional.
--
-- The same page may also be kept twice, in two folders, which a table keyed by
-- URL cannot express. Hence a row per placement, and `bookmark_url` below is a
-- plain index rather than a unique one.
--
-- # One table for folders and pages
--
-- A folder is a bookmark with no URL. The alternative — `bookmark_folder` and
-- `bookmark`, joined — buys a NOT NULL on `url` and pays for it with two
-- parents to keep in step, two deletes to cascade, and a tree walk that has to
-- union two tables to produce one ordered list. Chromium, Firefox and Safari
-- all store it as one tree for the same reason, which also makes the import a
-- straight copy rather than a split.
CREATE TABLE bookmark (
  id TEXT PRIMARY KEY,
  -- NULL means the bar itself: the top level, which has no row of its own.
  -- A root row would be one more thing every query has to remember to skip,
  -- and one more thing a delete could orphan the tree by removing.
  --
  -- CASCADE because deleting a folder deletes what is in it, which is what the
  -- word means. The ledger opens with `foreign_keys = ON`, so this is enforced
  -- rather than hoped — the same reason `visit_alias` states it.
  parent_id TEXT REFERENCES bookmark(id) ON DELETE CASCADE,
  is_folder INTEGER NOT NULL,
  -- NULL exactly when `is_folder`. Normalized by `history::normalize_url` so
  -- that "is this page bookmarked" asks the same question the address bar can
  -- answer, and so a bookmark and its history row agree about what the address
  -- is.
  url TEXT,
  -- Never NULL, and never empty: a row you cannot name is a row you cannot find
  -- again. An untitled page is saved under its address by the caller.
  title TEXT NOT NULL,
  -- Order among siblings. An integer, not the fractional ordinal `ordinal.rs`
  -- gives lanes, because the two orders are maintained differently: a lane is
  -- dragged between two others constantly and a fractional key is what keeps
  -- that from renumbering the strip, whereas a bookmark is appended and
  -- occasionally removed. Renumbering one folder is a single UPDATE over
  -- tens of rows; the strip's problem is hundreds and every drag.
  position INTEGER NOT NULL,
  added_at INTEGER NOT NULL
);

-- The two reads there are: a folder's contents in order, and "is this page
-- kept" for the star in the chrome bar.
CREATE INDEX bookmark_sibling ON bookmark(parent_id, position);
CREATE INDEX bookmark_url ON bookmark(url);

-- # Why there is no trigram index here
--
-- `history.rs` states the rule this follows: an index earns its place when the
-- corpus is one that is never otherwise in memory, and the ledger's is 112 840
-- pages. A bookmark corpus is the one the user curated by hand — the owner's
-- Vivaldi bar is eight folders and a few hundred pages, and every browser's is
-- that order — so the whole of it is read, ranked in Rust by the same
-- `history::Ranking` the palette uses, and handed back. Measured cost of
-- ranking a thousand rows is under a millisecond, which is less than the index
-- would cost to keep in step on every add.
--
-- If that stops being true the index goes in here, keyed the way 0009 is; the
-- ranking will not have to change, because `Ranking` already takes rows one at
-- a time from wherever they come from.
