# ADR 0016 — A private lane is a ledger row until the next open, and nothing else is

**Status:** Accepted · 2026-09-16
**Decides:** how a private web lane (⇧⌘N) can exist on a strip whose every lane
is a row in `laned-core`, while promising that nothing about its pages is
recorded.
**Evidence:** the work item
[`docs/work/web-private-pane.md`](../work/web-private-pane.md), whose design is
the owner's and is not re-opened here; `crates/laned-core/tests/private.rs`;
`WebPrivateLaneTests.swift`, which drives a private page through real WebKit.

## The conflict

The work item asks for a lane that is "recorded nowhere" and that "the ledger
never learned". The README's rule for the Swift app is that it is a view:
`StripState` comes from `Core::state()`, the strip materialises exactly the
lanes in it, and a lane that is not in the ledger is a lane the strip cannot
draw. Both cannot be literally true. A parallel, in-memory list of lanes merged
into every snapshot was the way to make the first sentence literal, and it
would have touched every view that reads `state.lanes` to serve one feature.

## Decision

**A private lane is a row in `lane` with `is_private = 1` (migration 0014),
and `Core::open` deletes every such row before the first read.** While the
lane stands, it is on the strip like any other: placed, focused, titled,
docked, gathered, evicted and rehydrated by the same code. When the process
ends — quit with the lane up, or `kill -9` — the next open has never heard of
it. Nothing else about the lane is recorded, and the core enforces the two
that matter rather than trusting the shell:

| written | by | why |
|---|---|---|
| the lane row, its title, its pane's current URL and zoom | the same paths as any lane | the strip draws from the snapshot; eviction rebuilds a pane from `pane.url` (ADR-0006). All of it goes at the next open. |
| `pane.data_store_id = private:<lane id>` | `create_private_web_lane` | names the non-persistent jar, so a split and a ⌘-click sibling can join it without the shell guessing from the lane |
| **not** a visit | `record_visit` refuses a pane in a private lane, before the burst memo | history is the record the lane exists to stay out of |
| **not** the session blob | `set_pane_interaction_state` refuses it | WebKit's `interactionState` is the page's history, scroll and form state |
| **not** a title correction | the shell skips `name_visit` | it is keyed by URL alone, and a public visit to the same address must not learn what a private one saw there |
| **not** a saved password | the shell greys out ⇧⌘L and leaves the item out of the key's menu | the Keychain is the one store outside the ledger a page can reach. Fill still works: reading is not keeping |
| site permissions under `private:*` | `set_site_permission`, as for any jar | a grant is per jar, and the jar is gone at open; the purge deletes these rows with the lane |

`create_lane` did not grow a flag on its exported signature. A second export,
`create_private_web_lane(placement, url, inherit_tag_from_lane, data_store_id)`,
shares its body: web only, because a terminal's session belongs to relay-tty
and outlives any lane, and "private" is a claim about cookie jars and history,
which only a page has.

## The cookie jar

`DataStorePool` holds one `WKWebsiteDataStore.nonPersistent()` per private jar
id, keyed by the `private:` string on the panes. It is not a profile: a profile
is a whole instance — ledger, config, socket, salted persistent jars — chosen at
launch and kept forever, and the work item rules it out by name. A private jar
is one object, created on the first pane that asks for it, and forgotten by
`StripStore.publish` when no lane in the ledger names it any more. The check
reads `all_lanes()`, not the snapshot: a gather view hides a lane without
closing it, and dropping a jar for a hidden lane would hand its next split or
rehydrate an empty store and lose the sign-in the lane was opened for.

A ⌘-click from a private pane opens its sibling with the opener's jar id, so
the link that a sign-in produced opens signed in. Closing the opener does not
end the jar while the sibling stands; closing the last lane in it does.

## Where it departs from the work item

- "The ledger never learned it" is true across launches and not within one.
  The alternative was a shadow strip in Swift; see *The conflict*.
- The private lane opens on `about:blank` with the cursor in the address,
  the way a browser's private window opens empty. The work item did not say
  what page ⇧⌘N should show, and the honest answer is none: the page a private
  lane is for is one history would not know.
- The chip is `PRIVATE` in the resting grey, outlined, on the header, the
  chrome bar and the ⌘P rows. No colour: the greens are spent on focus and
  state (ADR-0015), and private is neither.

## Consequences

- A `kill -9` leaves a private lane's row and URL in the file until the next
  open. That window is the process's own lifetime and no longer; nothing reads
  the file in between but the CLI, which talks to the running app.
- Export Strip never carries a private lane: the importer writes
  `is_private = false` for everything it reads, and a private lane in a file
  would be a private lane that outlived its window.
- A ledger written by this build and opened by an older one has private lanes
  it does not purge. The column defaults to 0 and the older build ignores it;
  the lanes are ordinary lanes there, on the profile's persistent jar. The
  same ledger is not meant to be shared between builds (README, *Profiles*).
