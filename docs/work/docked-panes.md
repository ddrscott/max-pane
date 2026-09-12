# Dock a pane to the left or right of the strip

## What the owner asked for

> "another major feature is like is pinning a pane to the left or right. another
> option should allow the pinned pane to hover over the strip, or reduce the
> space of the strip. i often have a page that's for background music."
> "but pinning i mean docking a pane to the left or right side"
> "a lane may contain several vertically stacked panes. lanes always initially
> start with a single pane. when a lane is docked all its panes are inherently
> docked with it. the order of the docked lane is remembered so it returns to
> the same spot when it's undocked."
> "two docks at once, one each side. dock width resizable and persisted."

So: a pane that stays put at one edge while the strip scrolls behind or beside
it, in one of two modes — **overlay** (floats above the strip) or **inset** (the
strip gets a narrower viewport and nothing is ever hidden).

The stated use case is the acceptance test. **A music page must keep playing,
audibly, while the strip is scrolled, while other lanes are focused, and while
memory pressure is high enough to evict things.** A dock that looks right and
goes silent is a failure.

## The name is already taken, and that has to be settled first

`Lane.pinned` exists today and means **"never evict this lane's web panes"** —
`eviction.rs:204` skips pinned lanes — reachable on ⇧⌘P as "Pin Lane". It is a
memory flag with no position in it. Two different meanings of "pinned" in one
app is how a user ends up pinning a lane and wondering why it did not move.

**The owner has settled this**: pinning means docking. The word belongs to the
new feature, so it is the *old* flag that needs a different name — or no
user-facing name at all.

The most promising reading is that **docking subsumes pinning**: a docked pane is on screen permanently, so it must never be evicted,
which makes today's flag an implementation detail of the new feature rather than
a second concept. If that holds, `pinned` should stop being user-facing. If it
does not hold — if there is a real reason to protect a lane you are *not*
docking — then the two need different names in the UI and in the model, and the
ADR should say why both exist.

## The design questions that decide whether this is any good

**Two of these are answered** — the owner settled them and they are no longer
open:

- **The unit is the LANE.** Every pane in it docks with it, and it goes on
  behaving as a lane: ⇧⌘D still splits it, height weights still apply. A lane
  starts with one pane but must never be built assuming one.
- **The ordinal is remembered and undocking restores it** — the same spot, not
  the end and not "next to where you are". That is stronger than it looks: the
  strip uses fractional ordinals with renormalisation, so lanes created, moved
  or renormalised while one sits docked will have taken ordinals around and
  through its remembered position. "The same spot" needs a definition that
  survives its neighbours changing.

- **Two docks at once, one per side.** At most one left and at most one right —
  not a list. Docking to an occupied side needs a defined answer (replace, with
  the incumbent undocking to its remembered ordinal, or refuse), and if it
  replaces, that undock must restore the ordinal exactly as a hand undock would
  or docking something else silently loses someone's place.
- **The dock's width is resizable and persisted.** Per-dock durable state.
  Probably a different number from the lane's own `width_pt`, which the owner
  drags deliberately and which must not be silently overwritten when a lane
  docks. `laneMinPt`/`laneMaxPt` bound a column in a scrolling strip; a dock is
  a fixed share of the window, so whether the same clamp applies — and what a
  window too narrow for two docks plus a lane does — is a real question.

Still open:
- **Everything that reads the viewport width has to agree with inset mode.**
  `LaneSnap.offset`, `LanePeek`, `StripEdgeRail`'s counts, `materializationWindow`
  and `visibleLaneRange` all compute against the clip view today. In inset mode
  the strip's usable width is smaller; in overlay mode it is not, but the lane
  *under* the overlay is occluded, which the edge rails and the "can I tell
  there is more" work exist to prevent. Overlay mode arguably needs the peek to
  treat the covered strip as an edge.
- **Keyboard.** Do ⌘[ / ⌘] skip the docked lane, or does it join the cycle at
  one end? Focus has to be reachable and escapable without the mouse. The one
  question the owner has not answered, and better argued from use than asked
  about.
- **Overlay needs to say it is floating**, or it reads as a lane that will not
  scroll. A shadow, an edge, something.

## Acceptance criteria

- A lane can be docked left or right, in either mode, from the keyboard and from
  the lane's ⋯ menu, and the choice survives a restart.
- **Audio from a docked page keeps playing** while the strip scrolls, while
  another pane has focus, and after the eviction policy has run a pass with the
  memory budget exceeded. Prove it with `maxpane ls` plus something audible, not
  by reading the eviction code.
- In inset mode, no lane is ever hidden behind the dock: the strip's arithmetic
  uses the reduced width everywhere, and the edge rails still tell the truth.
- In overlay mode, it is visually obvious the dock is floating, and there is
  still evidence of strip continuing underneath.
- Undocking returns the lane to the strip at a defined place.
- The `pinned` collision is resolved, with the decision recorded.

## Relevant files

- `crates/laned-core/src/model.rs`, `lib.rs`, `eviction.rs` (the `pinned` skip),
  a new migration.
- `swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift` — layout,
  the clip view, materialisation, snapping.
- `Views/StripEdges.swift` — `LanePeek`, `StripEdgeRail`.
- `Views/LaneView.swift` — the ⋯ menu.
- `Commands.swift` — ⇧⌘P today is "Pin Lane".

## Constraints

- Split in two. The **model half is building now** — the ledger, the naming
  decision, the eviction guarantee, and a written contract for the layout. The
  **view half waits** on the motion round-2 work merging: it owns
  `StripViewController`, `StripMotion`, `StripEdges`, `LaneView` and
  `WebPaneController`, and two builders rewriting the strip's layout at once
  produces a merge nobody can verify.
- A docked web pane must never be unparented by the eviction policy. Read
  ADR-0003 and `eviction.rs` before assuming `pinned` already guarantees that —
  it prevents *eviction*, and unparenting is a separate action.
