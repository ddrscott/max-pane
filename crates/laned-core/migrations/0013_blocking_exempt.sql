-- Sites the ad and tracker blocker is switched off for.
--
-- The blocker itself is a compiled WebKit rule list the shell owns: it is a
-- cache of a downloaded file, rebuilt from the network, and nothing about it
-- belongs in a ledger of the user's own decisions. *Turning it off for a site*
-- is such a decision, and it lives here for the reason `site_permission` does
-- (PRD §5.2, the shell owns no durable state): a throwaway instance with its
-- own ledger starts blocking everywhere, whatever the owner has exempted.
--
-- Keyed by the registrable domain rather than the origin, because "let this
-- site's ads through" is said about a site, and `www.example.com`,
-- `example.com` and `m.example.com` are one site to the person saying it. Not
-- by the cookie jar either: the blocker does not know who the user is to the
-- site, and an exemption is not a statement about identity.
--
-- Rows mean *off*. There is no remembered "on", because on is the default and
-- a row that said so would be a row that does nothing.
CREATE TABLE blocking_exempt (
  domain TEXT PRIMARY KEY,      -- registrable domain, lowercased: 'youtube.com'
  decided_at INTEGER NOT NULL   -- epoch ms
);
