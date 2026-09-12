# ADR 0010 — Docking takes the word "pinned"; the eviction flag becomes `keep_live`

**Status:** Accepted · 2026-09-12
**Decides:** the name collision raised by [docked panes](../work/docked-panes.md).
**Evidence:** the owner's own vocabulary, quoted below; `eviction.rs`'s policy
and spike M1's measurements, which are what make the two concepts different
sizes; the arithmetic in "Rejected", which caps the folded version at two.

## The collision

`Lane.pinned` shipped meaning exactly one thing: **never evict this lane's web
panes.** `eviction.rs` skipped pinned lanes when choosing what to destroy under
memory pressure, and the UI called it "Pin Lane" on ⇧⌘P. It is a memory flag
with no position in it.

Then the owner asked for docking, and named it:

> "another major feature is like is pinning a pane to the left or right."

> "but pinning i mean docking a pane to the left or right side"

Two meanings of one word in one app is how a user pins a lane and then wonders
why it did not move. This had to be settled before either feature was built,
because the answer decides whether there is one concept in the model or two.

## Decision

**The word goes to docking. The memory flag keeps its meaning, keeps its key,
and takes an honest name: `keep_live`, surfaced as "Keep Lane Loaded".**

Concretely:

1. `Lane.pinned` is renamed to `Lane.keep_live` (migration 0007, `ALTER TABLE
   lane RENAME COLUMN`). Its behaviour is bit-for-bit unchanged: it prevents
   `Evict` and not `Unparent`, exactly as before.
2. Docking is a new, separate piece of state — `Lane.dock`, an
   `Option<{side, mode, width_pt}>`.
3. **Protection is derived from the dock, never written alongside it.** The
   eviction policy's predicate is `lane.dock.is_none() && !lane.keep_live`. A
   docked lane is therefore protected without `keep_live` being set, which is
   what makes undocking safe: it cannot clear a flag it never set.
4. **⇧⌘P keeps its binding**, retitled. The key is not the word, and moving a
   binding people have in their fingers in order to rename a concept costs more
   than it buys. Docking gets keys of its own on the same axis as ⌘[ / ⌘]:
   ⌃⌘[ / ⌃⌘] dock to an edge, ⌥⌘[ / ⌥⌘] move focus into that dock and back out.

## Why two concepts and not one

The brief's most promising reading was that docking *subsumes* pinning: a docked
pane is on screen permanently, so it must never be evicted, which would make the
old flag an implementation detail rather than a second concept. Half of that is
true and is now how the code works — point 3 above. The other half does not
survive contact with the arithmetic.

**Docking costs screen; protection costs memory. Folding them together prices
them together, and they are not the same price.**

- **There are exactly two edges.** The owner settled the shape himself: *"two
  docks at once, one each side."* If protection is a side effect of docking, a
  strip can protect **at most two lanes, ever**. Every other lane on a
  hundred-lane strip is evictable no matter what it is doing. A memory guarantee
  with a hard cap of two is not a memory guarantee; it is a coincidence.
- **Eviction is not always recoverable.** Migration 0003 added
  `interaction_state`, so a rehydrated pane comes back with its back/forward
  list, its scroll and its form contents. That covers a lot — and covers nothing
  with live client-side state: an open WebSocket, a running notebook, an upload
  in flight, a video call. Those are worth protecting and are frequently worth
  *not* looking at.
- **The two answers point opposite ways for the same page.** The owner's music
  page wants both, which is why the collision happened at all. A long-running
  dashboard wants protection and no screen. A reference page you are reading
  wants an edge and does not care if it reloads. One flag cannot say both.

So: `keep_live` is still the way to protect a lane you are **not** giving an
edge of the screen to, and it is the only way to protect more than two.

## Consequences

- **`pinned` is gone from the model, the UI and the CLI surface.** One name, one
  meaning. `LaneHeaderModel.pinned` is the last place the old word survives, and
  it is a view-model field describing the glyph the header draws — renamed by
  the docking view work, which owns that file and is adding a docked marker to
  it anyway.
- **The export format writes both keys for one release.** `keep_live` and
  `pinned`, same value. `FORMAT_VERSION` is documented as "bumped only when an
  old file would be read *wrongly* rather than merely incompletely", and a build
  already on disk reading a new file would read it incompletely — every
  protected lane silently unprotected, with nothing in the file to say so.
  Cheaper to write nine extra bytes. On import, `keep_live` falls back to
  `pinned`, permanently: every file anyone has was written with the old name.
- **The eviction policy has one predicate, not two conditions in three places.**
  `may_evict(lane)` is where a third reason to protect a lane would go.
- **A docked lane is never `Unparent`ed either, which `keep_live` alone does not
  guarantee** — and deliberately still does not. See below.

## What the core can and cannot promise about the audio

The acceptance criterion is audible: a docked music page keeps playing while the
strip scrolls, while another pane has focus, and after the policy has run a pass
over budget. `pinned` prevented *eviction*; **unparenting is a separate action**,
and M1 measured it as a real one — it takes the `WKWebView` out of the view
hierarchy, which clears WebKit's `IsInWindow` and `IsVisible` for that page.

Whether a page with no window keeps making noise is WebKit's business. It
probably does — that is how a background tab works — but "probably" is not an
acceptance criterion, and the core is not in a position to test it.

So the core does not place that bet. **A docked lane's panes are always `Keep`**:
never evicted, never unparented, whatever the memory pressure and wherever the
strip has scrolled. The bet is avoided rather than won.

`keep_live` is left exactly as it was — protected from `Evict`, still
`Unparent`ed past `RELEASE_DISTANCE` — on purpose. Changing two things at once is
how you cannot tell which one fixed the music. If a `keep_live` lane six lanes
off screen turns out to go silent, that is a second, separate change with its own
measurement behind it.

## Rejected

- **Fold protection into docking and delete the flag.** The most tempting
  answer, and the brief's preferred reading. Rejected on the cap of two above:
  it makes "protect this page" cost a permanent fifth of the screen, and it
  makes protecting a third page impossible.
- **Keep `pinned` and give docking a different word.** Rejected because the
  owner has already assigned the word. Docking would have to be called something
  he does not call it, in an app he is the only user of.
- **Rename the flag to `never_evict`.** Rejected as a statement about the policy
  rather than about the lane. `eviction.rs` has been rewritten once already by a
  spike; a field named after this month's policy is a field that will disagree
  with next month's. `keep_live` says what the user wants — the page stays
  loaded — and stays true whatever the policy does to achieve it.
- **Two flags, both user-facing, both called pin-something.** Which is where a
  half-measure lands: "Pin Lane" and "Pin to Edge" in one menu.

## What would make us revisit

- The owner never reaching for "Keep Lane Loaded" over a month of real use. Then
  the two concepts really are one in practice, folding is free, and ⇧⌘P should
  become a dock key. That is a deletion, and it is easy in this direction and
  hard in the other, which is the order to find out in.
- A third dock position (a bottom edge, a second display) raising the cap of
  two. The argument above is quantitative; a different number is a different
  argument.
- WebKit being shown, by measurement rather than by reasoning, to keep a page's
  audio alive while it is unparented. That would make `keep_live` alone enough
  for a *background* music page — one that plays without taking an edge — which
  is a feature the owner has not asked for but might once he has this one.
