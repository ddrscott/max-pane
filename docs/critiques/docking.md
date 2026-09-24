# Critique — lane docking

**Judged against one sentence, and nothing else:**

> "The purpose of docking is to pin one or more lanes in expanded mode so I can
> keep them readable as I navigate some other lanes temporarily."
> … "docking from lane and gallery mode [should be] consistent"

Read as built on 2026-09-24. Where the code, the README or an ADR disagrees with
that sentence, the sentence wins.

## 1. What docking does on the strip

**Two lanes, one per edge, left and right** (`Core::dock_lane`,
`crates/laned-core/src/lib.rs:823`; `updateDocks`,
`StripViewController.swift:1205`). ⌃⌘[ / ⌃⌘] toggle the edge
(`Commands.swift:297`), ⌃⌘\ switches *inset* (strip narrows) ↔ *overlay* (dock
floats over the strip), ⌃⌘= / ⌃⌘- resize the dock rather than the lane
(`StripWindowController.swift:1243`), ⌥⌘[ / ⌥⌘] move focus in and back out
(`:1425`). The lane keeps its ordinal, so undocking puts it back between the
same neighbours (`lib.rs:805`).

What it guarantees is strong and correct:

- **Always live.** `may_evict` is `lane.dock.is_none() && !lane.keep_live`
  (`eviction.rs:42`); a docked lane never appears with `Evict` *or* `Unparent`
  (`eviction.rs:198`). The view is a sibling of the scroll view precisely so
  `updateMaterialization` cannot recycle it (`StripViewController.swift:190`).
- **Never hidden.** Gather keeps docks (`lib.rs:1881`); a folded sidebar group
  keeps them (`lib.rs:1767`, ADR-0024 §1); ⇧⌘↩ maximizes *clear of* the docks
  (`maximizedViewportRect`, `:2215`).
- **Readable.** Clamped 240–900 pt, sizes apply on the dock's width
  (README *Lane sizes*), so the pinned lane is a real column, not a sliver.

Costs: an inset dock takes its width out of the strip; under ~900 pt between
two docks both flip to overlay and *cover* the lanes underneath (README
*Docking a lane to an edge*); and the two edges are the whole supply.

On the strip, the sentence is satisfied.

## 2. What docking does in the gallery

**Nothing.** A docked lane is an ordinary tile at its ordinal — ADR-0011 *Docked
lanes are ordinary tiles*, and the code agrees: `syncGallery` draws
`state.lanes` (`:1599`), `layoutDocks` returns before touching a wall when
`isGallery` (`:1316`), and `updateMaterialization` hands the gallery
everything (`:910`). The only residue of the dock is geometric: `realSize`
gives the tile the dock's width and the **window's** height rather than the
strip's (`:1704`).

Plainly: in the gallery the pin is discarded and the lane becomes one thumbnail
among twenty. For the owner's purpose that is not a smaller version of docking;
it is the absence of docking.

## 3. The gap as he feels it

He docks the music/chat/reference lane. He presses ⌘G. **The lane he pinned
leaves the wall and becomes a thumbnail the same size as everything else** — the
one lane he asked to stay readable is now the least readable it has ever been,
along with the other nineteen.

He double-clicks a tile to read it. That is the gallery's only readable state,
and it holds exactly one lane (`expandedLaneId`, `:1446`; `expandTile` replaces
whatever was expanded, `:1450`). He then presses ⌘] to look at another
lane: `cycleExpandedTile` collapses what he was reading and expands the next
one (`:3348`). ⌘J (Next Attention) is worse in the other direction — it moves
focus and leaves the expansion behind, so he reads nothing until he double
clicks (`docs/work/gallery-focus-moves-expansion.md`). Either way **the gallery
cannot hold one lane while he navigates another** — the literal thing his
sentence asks for, and the gallery's design forbids it.

## 4. "One or more"

**Two. Ever.** One lane per edge, and ADR-0010 leans on that cap as an argument
(it is why `keep_live` survives as a separate flag). Two is *"one or more"* only
by luck, and the shape is an artefact of the strip: a lane is a portrait column,
a strip has two ends, therefore two pins. Nothing in his sentence mentions
edges. The right shape for the stated purpose is *a held set of lanes rendered
at full size, in whichever layout is up* — the wall is one implementation of it,
and the only one that exists.

The cap also bites hardest in the layout with the most room: the gallery, where
the constraint is a grid rather than two walls, holds **one** readable lane —
fewer than the strip.

## 5. Does "expanded mode" mean the same thing twice?

No. On the strip, *expanded* is "at its lane width, at a wall, indefinitely,
persisted in the ledger, ignored by focus keys". In the gallery, *expanded* is
"one tile, grown to real size, **held in memory only** (ADR-0011,
2026-09-13 amendment), destroyed by the next focus move, and covered outright by
⇧⌘↩ because the maximize viewport is the whole gallery" (ADR-0019:163).

A docked lane is *readable* on the strip and merely *present* in the gallery.
Quit while in the gallery and the dock survives (it is a ledger column); the one
thing you were actually reading does not.

---

## Findings, ranked

### 1. ⌘G unpins everything. The gallery has no dock. (L)

*Expects:* the pinned lane stays readable in both layouts.
*Today:* ADR-0011 rejects *"docks kept at the wall in the gallery"*; the code
implements the rejection (`:1316`, `:1599`).
*Gap:* the pin is a property of one layout, so half of the app's navigation
throws it away.
*Change:* the gallery gets walls. A docked lane is drawn at the gallery's left
or right edge at the dock's width and the gallery's full height, at scale 1
(clamped down only if the window cannot afford it); `GalleryLayout.place` lays
the remaining tiles into the space between, exactly as the strip's viewport is
narrowed today. Inset and overlay both honoured; ⌃⌘\ works there. Entering and
leaving the gallery animates a docked lane wall→wall with no move at all
(ADR-0011's 2026-09-17 amendment already says a docked lane "comes from its
wall" — it should simply stay there). Ledger unchanged: `lane.dock` is already
the truth. Docked lanes are excluded from the tile grid, from the expansion
cycle and from ⌘[ / ⌘], mirroring the strip exactly.
*ADR:* amends **ADR-0011**'s "Docked lanes are ordinary tiles" and its rejection
of walls, and **ADR-0019**'s "the viewport is the whole gallery". Warranted:
0011's reason was that the grid would lose the edges' width — which is the price
of docking, knowingly paid on the strip, and the owner's sentence says he wants
to pay it.

### 2. The gallery holds exactly one readable lane, and every keystroke takes it away. (M)

*Expects:* pin one or more, then navigate others temporarily.
*Today:* one `expandedLaneId` (`:1446`), replaced by `expandTile` (`:1450`) and
by ⌘[ / ⌘] / ⇧⌘[ (`cycleExpandedTile`, `:3348`).
*Gap:* the gallery's only readable state is the one that navigation consumes.
*Change:* with finding 1 in place, the pinned lane is the readable lane that
navigation cannot consume, and the expansion becomes what it is — a temporary
look. Add one refusal: **an expanded tile can never be a docked lane, and the
expansion cycle skips docked lanes** (they are already readable). Without
finding 1, the cheap fallback is a second, *held* expansion slot: ⌃⌘[ / ⌃⌘] in
the gallery expand a tile and keep it expanded, side by side with the roaming
expansion, up to two; `Motion.lane` both ways.
*ADR:* ADR-0011's 2026-09-23 amendment gains the skip rule.

### 3. The queued expansion-follows-focus task will make this worse. (S)

*Expects:* navigating away does not disturb the pinned lane.
*Today:* `docs/work/gallery-focus-moves-expansion.md` puts the rule at
`focus(_:)` / `select(laneId:paneId:)` / `reveal(laneId:flash:)` — and ⌥⌘[ /
⌥⌘] *into a dock* is first on its own list of paths.
*Gap:* as specified, focusing a docked lane will yank the expansion onto it and
then the next ⌘J will yank it off, so the one lane he pinned becomes the one
lane most churned.
*Change:* that task's "Not moved by" list gains a fourth entry: **focus landing
on a docked lane never moves the expansion** (the lane is pinned; it needs no
expanding). One predicate at the same choke point, one test.
*ADR:* none. Do not create the work item — fold this into that task when it is
picked up.

### 4. The dock chords are live in the gallery and silently do nothing. (S)

*Expects:* "docking from lane and gallery mode consistent."
*Today:* `canPerform` enables `.dockLaneLeft` / `.dockLaneRight` on any focused
lane (`StripWindowController.swift:1007-1009`); the press writes `lane.dock` to the
ledger and **nothing on screen changes**, because `layoutDocks` has already
returned (`:1316`). ⌃⌘= / ⌃⌘- resize an invisible dock; ⌥⌘[ focuses a tile and
scrolls nothing (`ensureVisible`, `:3436`).
*Gap:* a key that writes persistent state with no feedback is worse than a key
that refuses.
*Change:* with finding 1, they all become real in the gallery and this
disappears. Until then, `canPerform` refuses the four dock commands while
`isGallery`, with `unavailable()` text *"not in the gallery"* — the wording
already used for `renameLane` (`:1064`).
*ADR:* none.

### 5. A docked tile is laid out with the wrong height and overlaps its neighbours. (S)

*Expects:* nothing visibly broken.
*Today:* `realSize(of:)` returns `view.bounds.height` for a docked lane
(`:1707`) while every other tile gets `galleryStripHeight` — the clip view, i.e.
less the 34 pt toolbar and the status bar. `layoutGallery` sizes the frame
`size.height * scale` into a slot laid out at the shorter height (`:1653`), so
a docked tile hangs below its row.
*Change:* in the gallery a docked lane's tile uses `galleryStripHeight` like
every other lane, and its own strip `width_pt` rather than the dock width, so
docking does not change a lane's shape in a layout that has no wall. Moot if
finding 1 lands (the wall's height is the right height there); fix it either way.
*ADR:* none — this contradicts ADR-0011's own "nothing inside is resized".

### 6. The strip's pin persists; the gallery's reading does not. (S)

*Expects:* the same promise in both layouts.
*Today:* `lane.dock` is a ledger column; `expandedLaneId` is memory only
(ADR-0011, 2026-09-13) and is cleared on every layout switch (`:1541`).
*Change:* persist the expanded lane id in `app_state` beside `strip_layout`,
restored only when the gallery is the restored layout and the lane still exists.
One key, one write on expand/collapse, no new surface.
*ADR:* amends ADR-0011's "held in memory only" — warranted only if finding 1 is
declined; with a gallery wall, the durable thing is the dock and this is
optional.

---

## What is already right

The strip half is the good half. The audio guarantee is real and is defended at
both ends of the FFI (`eviction.rs:42` + the sibling-of-the-scroll-view
discipline at `:190`). Gather, folding, maximize and eviction all exempt a
docked lane without a special case each. ⌘[ / ⌘] skipping the docks is correct
for his sentence — the pin must not be a place navigation lands. Keeping the
ordinal instead of remembering it is the right call. ⌃⌘= reusing the widen keys
is the right amount of key.

## Not worth doing

- **A second display for the pinned lane.** ADR-0008 rules it out, and his
  sentence is about one window.
- **A third and fourth edge (top/bottom).** A lane is a portrait column; a
  200 pt-tall lane is not readable and is not what he pinned.
- **Making the maximize overlay hold two panes** so a dock can sit beside a
  maximized one. ADR-0019 is right that maximize is a temporary overlay; the
  answer is the gallery wall, not a second overlay slot.
- **A floating always-on-top dock window.** It leaves the strip's geometry
  entirely and every guarantee in §1 would have to be rebuilt against AppKit.

## The two to do first

1. **Finding 1 — give the gallery walls.** It is the whole of "consistent", and
   findings 2, 4, 5 and 6 either dissolve or shrink once it exists.
2. **Finding 3 — exempt docked lanes in the queued expansion task.** One
   predicate, and it must land *with* that task or it ships a regression against
   the stated purpose the same day.
