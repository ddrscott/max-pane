-- Search the whole table, which is what makes "no limits on history" possible.
--
-- Round 1 kept the cost flat by only ever looking at the newest 2 000 rows, and
-- that was the bug: a row at depth 2 499 was silently unfindable while the
-- footer read `0 OF 5013 PAGES`. The caps are gone (see history::rank's module
-- docs), so the scan they were hiding is now over the owner's real corpus —
-- 112 840 URLs — and a linear scan there costs ~100 ms a keystroke. An index is
-- therefore not an optimisation; it is the thing that replaces the cap.
--
-- Trigram, not the default tokenizer. `unicode61` indexes words, so `hop` would
-- never find `hoppers` and the substring ranking added in round 2 would have an
-- index that disagrees with it: the tiers Prefix/WordPrefix/Substring are all
-- substring matches, and only a trigram index can produce all three. The cost
-- is size — roughly 3 index entries per character — and 30 MB of index over a
-- 28 MB table is the trade the owner already accepted when he said there is no
-- limit.
--
-- The index narrows; it never ranks. It cuts 112 840 rows down to the ones that
-- contain the typed characters somewhere, and history::Ranking then decides the
-- order — so the answers are the uncapped scan's answers. That holds because
-- what is stored here is exactly what the ranker matches against: lowercase,
-- and with the scheme already stripped the way `search_handle` strips it.
--
-- Keyed by `visit.rowid`. Nothing in this crate VACUUMs, which is the one
-- operation that renumbers the implicit rowid of a table whose primary key is
-- TEXT — if that ever changes, this index has to be rebuilt in the same breath.
-- `seq` rides along UNINDEXED so that ranking a match needs no join back to
-- `visit`: recency is the tie-break between two equally good matches, and
-- fetching it per row was the join this index exists to avoid. It is rewritten
-- with the haystack on every visit, which is the same statement that already
-- runs.
CREATE VIRTUAL TABLE visit_search USING fts5(
  haystack,
  seq UNINDEXED,
  tokenize = 'trigram'
);

-- Existing ledgers arrive here with a table and no index. One pass, inside the
-- migration's transaction, so a ledger is never half-indexed: a partial index
-- is the same silent hole the row cap was. Measured at 543 ms for 112 840 rows,
-- paid once, on the launch that upgrades — and today's ledgers are smaller than
-- that, because until this migration they were capped at 5 000.
--
-- `visit_age` from 0004 is left in place though nothing prunes by age any more.
-- It is the index a history view sorted by date will want, and dropping it now
-- to add it back next round is churn on a table nobody is short of space for.
INSERT INTO visit_search (rowid, haystack, seq)
SELECT v.rowid,
       lower(substr(v.url, instr(v.url, '://') + 3)) || char(10) ||
       lower(COALESCE(v.title, '')) || char(10) ||
       lower(COALESCE((SELECT group_concat(substr(a.alias_url, instr(a.alias_url, '://') + 3),
                                           char(10))
                         FROM visit_alias a WHERE a.url = v.url), '')),
       v.seq
  FROM visit v;
