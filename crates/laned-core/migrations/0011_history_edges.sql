-- The first two characters of every search, which the trigram index could not
-- serve.
--
-- FTS5's trigram tokenizer indexes three-character windows, so a one- or
-- two-character needle falls off the index of 0009 and onto a scan of the whole
-- corpus. Measured on the owner's real 108 854 imported pages, release build:
-- every letter of the alphabet cost between 62 and 87 ms as the first keystroke,
-- against 17 ms from the third character on. The first two characters of every
-- search he types were the slow ones, every time.
--
-- What this adds is a second indexed column holding, for every place a match
-- could *start* — the front of each field, and every position after a word
-- boundary — a doubled shoulder character and the two characters that follow.
-- `deploy` at a word start becomes CHAR(1)||CHAR(1)||'de', whose trigrams are
-- CHAR(1)||CHAR(1)||'d' and CHAR(1)||'de': the first indexable form of a
-- one-character needle and of a two-character one. `history::edges` builds it
-- and is the only definition of what a word start is, shared with the ranker's
-- `is_boundary` so the two cannot drift; it is reachable from SQL here as the
-- `maxpane_edges` function `Ledger::open` registers.
--
-- It narrows and never ranks, exactly like the haystack column beside it, and
-- the search stops using it the moment it could be lossy: a shoulder query
-- returns every row that can reach Prefix or WordPrefix, and `history_search`
-- takes its answer only when enough rows reached that tier to fill the page.
-- Below that it reads the whole table, because the tier below is then in play.
-- Silent truncation is what round 1 cost and it is not being reintroduced here.
--
-- An FTS5 table cannot have a column added to it, so this is the table of 0009
-- dropped and rebuilt rather than altered — which is also the only way to fill
-- the new column for rows that are already there. One transaction, so a ledger
-- is either wholly the old index or wholly the new one and never half of each:
-- a partial index is the same silent hole the row cap was.
--
-- **It costs 6.4 s on a ledger of 108 854 pages**, which is the largest stall in
-- this app and is paid once, on the launch that upgrades. 4.7 s of that is not
-- this migration's: running 0009's own statement against the same ledger costs
-- 4.7 s, so rebuilding the haystack index is the bulk of it and the new column
-- adds 1.7 s. (0009's comment says 543 ms; that number does not reproduce on a
-- real 108 854-page ledger and is left where it is rather than rewritten,
-- because a migration that has shipped is a record of what was believed then.)
-- The alternative — a second FTS5 table, so the haystack index is left
-- alone — buys back those 4.7 s at the price of a second index to keep in step
-- with `visit` from six write paths, and an index out of step with its table is
-- the failure this whole feature exists to have stopped.
--
-- The cost in space is the entries themselves: one per word start, deduplicated
-- within a row. Measured over that corpus, 171.3 MB of ledger becomes 216.9 MB.
-- The owner has already taken this trade once, when he said there were to be no
-- limits on history.
DROP TABLE visit_search;

CREATE VIRTUAL TABLE visit_search USING fts5(
  haystack,
  edges,
  seq UNINDEXED,
  tokenize = 'trigram'
);

INSERT INTO visit_search (rowid, haystack, edges, seq)
SELECT rid, hay, maxpane_edges(hay), sq
  FROM (SELECT v.rowid AS rid,
               lower(substr(v.url, instr(v.url, '://') + 3)) || char(10) ||
               lower(COALESCE(v.title, '')) || char(10) ||
               lower(COALESCE((SELECT group_concat(substr(a.alias_url, instr(a.alias_url, '://') + 3),
                                                   char(10))
                                 FROM visit_alias a WHERE a.url = v.url), '')) AS hay,
               v.seq AS sq
          FROM visit v);
