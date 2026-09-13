-- What a site is allowed to reach for, once the user has said so out loud.
--
-- Only camera and microphone today. The shape is general because the next one
-- (geolocation, notifications) arrives with a different `feature` string and no
-- migration.
--
-- ## Why the cookie jar is part of the key
--
-- Everything else in this file is keyed by something about the *strip*. A
-- permission is not: it is a statement about the identity the site can see, and
-- in this app that identity is the data store — the cookie jar a pane's project
-- was sharded into (ADR-0003). Two projects sharded apart are, to
-- `meet.google.com`, two different people; granting the camera to one of them
-- has never been a claim about the other. Keying this by origin alone would
-- have let a grant made in one project's jar arm the camera in another's, which
-- is the one direction a permission store must not leak.
--
-- The ledger still owns the row — PRD §5.2, the shell owns no durable state —
-- so a throwaway instance with its own `MAXPANE_LEDGER` starts with no grants
-- at all, whatever jar it points at.
--
-- `allowed` is stored rather than "rows mean yes", because a remembered *no* is
-- the more valuable half: a page that asks on every load is the reason people
-- click Allow to make it stop.
CREATE TABLE site_permission (
  data_store_id TEXT NOT NULL,  -- the cookie jar, e.g. 'shard-3'
  origin TEXT NOT NULL,         -- scheme://host[:port], exactly as WebKit reports it
  feature TEXT NOT NULL,        -- 'camera' | 'microphone'
  allowed INTEGER NOT NULL,     -- 0 or 1
  decided_at INTEGER NOT NULL,  -- epoch ms
  PRIMARY KEY (data_store_id, origin, feature)
);
