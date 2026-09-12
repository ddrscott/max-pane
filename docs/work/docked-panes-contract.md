# Docked panes: the contract between the model and the layout

The model half is built and merged: migration 0007, `Lane.dock`, the dock API on
`Core` and `StripStore`, the eviction guarantee, and the keymap. This page is
what the layout half is built against — what to call, what comes back, and the
invariants the strip must keep for any of it to be true.

Written to be argued with. Where it says "should", it says why, and the reason
is the thing to disagree with.

---

## The shape, in one paragraph

A **dock** is a lane held at the left or right edge of the window instead of
scrolling with the strip. At most one lane per edge, at most two in all. Every
pane in the lane is docked with it. The docked lane **keeps its ordinal and
stays in `StripState.lanes`**, which is how undocking returns it to the spot it
left. It is simply not laid out by the strip. Two modes: **inset**, where the
dock takes its width out of the strip's viewport and nothing is hidden, and
**overlay**, where the dock floats above the strip at full window width and the
lane underneath is occluded.

All four of these were settled by the owner directly, not inferred:

> "a lane may contain several vertically stacked panes. lanes always initially
> start with a single pane. when a lane is docked all its panes are inherently
> docked with it. the order of the docked lane is remembered so it returns to
> the same spot when it's undocked."

> "two docks at once, one each side. dock width resizable and persisted."

> "docked lane should be skipped in the cmd-[ cmd-] cycle"

---

## The API

### Reading

```swift
store.state.lanes          // every lane in ordinal order, docked ones included
store.stripLanes           // state.lanes.filter { $0.dock == nil } — what you lay out
store.dockedLane(.left)    // Lane?
store.dockedLane(.right)   // Lane?
lane.dock                  // Dock? — .side, .mode, .widthPt
lane.keepLive              // the flag formerly called `pinned`; see ADR-0010
```

`Dock` is three small scalars on the lane record. It crosses the FFI on every
snapshot, which is fine — the thing that must never go in a record that crosses
per snapshot is a blob, and `update_pane_interaction_state` explains why.

### Writing

```swift
try store.dockLane(laneId, side: .left, mode: .inset, widthPt: nil)
try store.undockLane(laneId)
try store.setDockMode(laneId, .overlay)
try store.setDockWidth(laneId, 320)
```

- `widthPt: nil` means **the width the lane already has**, clamped into
  240…900. Docking must not reflow the page: if docking re-laid a running web
  app out at some default, every dock would start with the thing you docked
  jumping.
- Docking to an edge another lane holds **displaces the incumbent** — it returns
  to the strip at the ordinal it never stopped holding. Not an error: the user
  pressed dock-left on this lane and meant it.
- `setDockMode` / `setDockWidth` **throw** on a lane that is not docked. They
  edit a dock, they do not create one, so a keystroke aimed at the wrong lane
  cannot silently take an edge of the screen.
- `undockLane` on a lane that is not docked is a **no-op**, because the one
  caller is a toggle.

Every one of these returns a `StripState` and publishes it, so the strip
re-renders through the same path everything else does.

### The keymap, already in `Commands.swift`

| Key | Command | What it does |
|---|---|---|
| ⌃⌘[ / ⌃⌘] | `dockLaneLeft` / `dockLaneRight` | Toggle: dock the focused lane to that edge, or give the edge back |
| ⌃⌘\ | `toggleDockMode` | Overlay ↔ inset for the focused lane's dock |
| ⌥⌘[ / ⌥⌘] | `focusDockLeft` / `focusDockRight` | Toggle: focus that dock, or leave it |
| ⌃⌘= / ⌃⌘- | `widenLane` / `narrowLane` | Routed to the **dock's** width when the focused lane is docked |
| ⇧⌘P | `toggleKeepLive` | "Keep Lane Loaded" — the old "Pin Lane", renamed (ADR-0010) |

`dockLaneLeft/Right`, `toggleDockMode` and both focus commands are implemented in
`StripWindowController`. The lane's ⋯ menu is the view half's to add, and should
use `Command.dockLaneLeft.title` and friends so the menu teaches the shortcut,
the way the existing items do.

---

## The invariant that will bite you first

> **Every index the strip computes is an index into `stripLanes`, never into
> `state.lanes`.**

`visibleLaneRange`, `materializationWindow`, `distanceFromViewport`,
`LaneSnap`'s slot walk, `StripEdges.slots`, `StripEdges.hidden`, the rails'
counts, and the `Viewport` handed to `planEviction` all currently walk
`state.lanes`. Every one of them must walk `stripLanes` instead. The two lists
were the same list until this feature; they are not any more.

`eviction::plan` removes docked lanes the same way before indexing, so the
`Viewport` you send and the array the core plans against agree **by
construction** — as long as you measured the array you laid out. Send indices
into `state.lanes` and the core will plan against a strip shifted by one per
docked lane, and evict the pane the user is looking at.

There is a test in `crates/laned-core/src/eviction.rs`
(`a_docked_lane_does_not_shift_the_indices_of_the_lanes_behind_it`) that pins the
core's half of this.

**Why the docked lane stays in `state.lanes` at all**, when removing it would
make the layout's job trivial: everything that is *not* the strip's layout wants
it. ⌘P finds it, gather counts it, the sidebar lists it, `maxpane ls` prints it,
export carries it. A lane drawn twice because a view forgot to filter is a bug
you see the instant it happens; a lane missing from search because a list forgot
to union is a hole nobody notices for a month. The strip's layout is the one
consumer that must skip them, and it is the one consumer being told to, loudly.

---

### One consequence of that, already handled in the core

**A docked lane survives the gather filter.** `Core::snapshot` keeps it in
`state.lanes` while ⌘G is active even when its project tag does not match.

Without that, ⌘G on a project your music player is not tagged with removes the
dock from the snapshot, `updateMaterialization` retires its lane view because it
is not in `wanted`, and the `WKWebView` is destroyed. The layout could not have
prevented it — it would be doing precisely what the snapshot told it. Gather
narrows *the strip*, and a docked lane is not in the strip.

So: `stripLanes` is still the right list to lay out while gathered, and it is
still filtered by gather. Only the docks are exempt.

---

## Inset mode: one number, computed once

Every piece of viewport arithmetic in the strip already takes the viewport width
as a parameter — `LaneSnap.offset(forCentre:viewport:lanes:minPeek:)`,
`LanePeek.adjust(offset:viewport:lanes:minimum:)`,
`StripEdges.hidden(lanes:offset:viewport:)` — or reads
`scrollView.contentView.bounds.width` directly. That is the whole of the change:

```swift
/// The width the strip actually has to scroll in.
///
/// Inset docks take their width out of it; overlay docks do not, because an
/// overlay covers a lane rather than removing the room for it.
var stripViewportWidth: CGFloat {
    scrollView.contentView.bounds.width   // already excludes the rails
        - insetDockWidths                 // sum of docks in .inset mode, clamped
}
```

**Recommended: make the clip view genuinely narrower rather than subtracting a
number everywhere.** Constrain the scroll view's leading/trailing edges to the
docks, and `scrollView.contentView.bounds.width` becomes the reduced width on
its own — every existing caller is then correct with no edit at all, including
ones nobody remembers. Subtracting in each caller is the version where the one
call site that was missed produces a snap that lands a lane half under the dock,
intermittently, and only when a dock is open.

The rails are already outside the clip view (`StripEdgeRail.width` is subtracted
before the scroll view is laid out), so docks nest outside the rails or inside
them, and either works — but pick one and say so in the layout, because
`StripEdges.hidden` counts lanes against `offset + viewport` and the answer
changes by a lane if the rails and the docks disagree about who is inside whom.

### Width clamping, and the narrow window

The core clamps `dock.widthPt` to 240…900 and knows nothing about the window.
**The view clamps again at layout time and must never write the result back.** A
dock is not permanently narrowed by having once been opened on a small screen —
the same rule ADR-0007 settled for lanes and session sizes.

The rule, concretely:

```
effectiveInsetWidth = min(dock.widthPt, (viewport - laneMinPt) / insetDockCount)
                      clamped below at DOCK_MIN_PT (240)
```

and if even `DOCK_MIN_PT` cannot be afforded — a viewport under about 900 pt
with both edges inset — **that dock renders as overlay for as long as the window
is that narrow.** Overlay is the honest degradation: it costs occlusion, which
is visible and recoverable, rather than a strip too narrow to read a lane in,
and nothing is written so it un-degrades the moment the window grows. Fullscreen
on this machine is nowhere near that; `MAXPANE_WINDOWED=1` is.

---

## Overlay mode: the thing the edge-peek work exists to prevent

In overlay the strip keeps the whole window's width, so no arithmetic changes —
and the lane under the dock is **occluded**. A lane the user cannot see, that
the rails do not count as hidden, that `visibleLaneRange` swears is visible. That
is precisely the failure the peek and the rails were built to remove:

> "The widths of the vertical panes seem too evenly distributed. i can't tell if
> there are more panes to the right or left."

**What I think is right, and the part most worth arguing with:** an overlay dock
should be treated as an *edge* by `LanePeek` and by the rails — the peek's
invariant becomes "no **visible** edge of the strip is ever flush with a lane
boundary while the strip continues past it", where the visible edge is the inner
edge of the overlay rather than the window's. That is a change of one number in
`LanePeek.adjust` (the `offset`/`limit` it works from) and one in
`StripEdges.hidden` (`offset + viewport` becomes `offset + viewport -
overlayWidth` on that side), and it makes an overlay dock cost exactly what an
inset dock costs *in evidence* while still costing nothing in room.

The cheaper alternative — leave the arithmetic alone and let the overlay cover
whatever it covers — is what makes overlay the mode that quietly re-breaks the
thing round 1 fixed. I would rather overlay be honest and slightly conservative
than free and misleading.

Overlay also has to **look** like it is floating, or it reads as a lane that will
not scroll. A shadow and a hard inner edge; content visibly moving underneath
when the strip scrolls is the strongest signal available and it is free.

---

## Materialisation, and the cold-launch trap

Two rules, both of which the current code gets wrong for a docked lane if left
alone:

1. **A docked lane is always materialised.** It is on screen. It must not be in
   `materializationWindow`'s range arithmetic at all — that window is about
   lanes scrolling in and out, and a docked lane never does either. Materialise
   it when the snapshot says it is docked, retire it when it undocks (and then
   it re-enters the window like anything else).

2. **A docked lane is never deferred on a cold launch.** `materialize(lane)`
   passes `deferLoad: isColdLaunch && distanceFromViewport(laneId:) >
   config.rehydrateDistance`. A music lane docked at the left edge with ordinal
   0, launched with the strip scrolled to lane 40, is "far" by that measure — so
   the page would not load, and the acceptance test ("a music page keeps
   playing") fails on the very first launch after a restart, silently, in the
   one case the feature exists for. `lane.dock != nil` must force
   `deferLoad: false`.

---

## The eviction guarantee, and where it stops being the core's

The core guarantees, tested in `crates/laned-core/tests/docking.rs` and
`src/eviction.rs`:

- A docked lane's panes are **always `Keep`** — never `Evict`, never `Unparent`
  — at any memory pressure, at any scroll position, including past the hard
  mark with `target_bytes` set to 1.
- Every pane of a docked lane, not just the first.
- An evicted pane in a lane that is then docked comes back: it plans
  `Rehydrate`, because a docked snapshot is a dead rectangle at the edge of the
  window.
- Undocking returns the lane to the ordinary policy immediately, with no flag
  left behind — protection is derived from the dock, not written beside it.

`Unparent` is refused as firmly as `Evict`, and that is the whole of the audio
argument. Unparenting takes the `WKWebView` out of the view hierarchy, which
clears WebKit's `IsInWindow` and `IsVisible` for that page. Whether a page with
no window keeps making noise is WebKit's business; it probably does, but the
core is in no position to test that and an acceptance criterion is not a place
for "probably". So the bet is avoided rather than won.

**The half only you can hold up:**

- `Keep` must mean **parented, in a window, and visible.** A dock view that
  lives inside the scroll view's document view will be recycled by
  `updateMaterialization` or moved by a scroll, and the guarantee evaporates
  with no error anywhere. The dock belongs as a **sibling of the scroll view**
  in the window's content, not inside it.
- The dock's view must not be rebuilt on every snapshot. `WebPaneController`
  holds the `WKWebView`; a re-materialised dock is a page reload, which is a
  gap in the music every time the strip changes shape.
- Nothing may set `isHidden` or zero `alphaValue` on a docked pane during an
  animation and forget to put it back. AppKit will keep a hidden view's page
  alive, but a docked lane that is invisible is a bug you cannot see.

If all three hold, the acceptance test is: dock a page playing audio, scroll to
the far end of a long strip, focus another pane, run the memory dashboard until
the policy has taken a pass over budget, and the audio has not stopped. `maxpane
ls` plus your ears, not a reading of `eviction.rs`.

---

## Focus

⌘[ / ⌘] walk `stripLanes` only. The owner asked for that directly, and it is
right for a reason worth keeping: those keys scroll the strip, and a docked lane
does not scroll. Landing on one would be a keypress with no motion and a focus
ring that jumped across the window and back — in an app whose stated thesis is
*"spatial reasoning of the interface"*.

That leaves a docked lane unreachable from the keyboard, and PRD §8 says every
action has a shortcut and the mouse is optional. A music page you cannot focus is
a music page you cannot pause without reaching for the trackpad. So:

- **⌥⌘[ / ⌥⌘]** focus the left/right dock, and pressing the same key while focus
  is already inside that dock leaves it again. Same key both ways: nothing extra
  to learn, and nothing to be stuck in.
- Leaving returns focus to the pane it came from (`paneBeforeDock`, held in
  memory, not in the ledger — it is half of a keystroke, not durable state).
  When that pane is gone, the fallback is the strip lane focused most recently,
  which is the lane you were last working in and therefore almost certainly
  still on screen. Never the first lane of the strip: on a strip of forty that
  is a jump to somewhere the user has not been in an hour.
- **⇧⌘[ / ⇧⌘] work unchanged inside a docked lane**, because a docked lane is
  still a stack of panes.
- **Both of these need the view half:** it must be obvious which of the two
  docks you are in when both are occupied (the focus ring is probably enough,
  but check it against a dock at each edge), and `store.focusPane` on a *strip*
  lane must scroll that lane into view — the existing search-to-scroll path.

---

## Everything else the view half owns

- **The lane's ⋯ menu**: Dock Left / Dock Right / Float Over Strip, from
  `Command`.
- **A dock marker in the lane header.** `LaneHeaderModel.pinned` is the last
  place the word "pinned" survives in the codebase; it is a view-model field
  about the glyph the header draws, and it is yours to rename when you add the
  docked marker beside it. `Lane.pinned` is a compatibility shim in
  `LaneHeaderModel.swift` that exists only to keep `LaneView.swift` untouched
  during this wave — delete it when you rename the field.
- **A drag handle on the dock's inner edge**, writing through
  `store.setDockWidth`. Same gesture as the lane divider, different bounds.
- **The rails' counts under a dock**, per the overlay section above.
- **An entrance and an exit animation.** A lane leaving the strip for an edge
  and coming back is exactly the *"subtle animations must be used to indicate
  when/where items are appearing and disappearing otherwise the user loses
  spatial recognition"* case, and it is the most legible one in the app: the
  lane's column collapses and the dock slides in from the edge, and the reverse.

---

## Things a critic will reasonably go after

Listed here rather than discovered, because they are the weak points:

1. **The one-list decision.** A docked lane in `state.lanes` means every future
   consumer has to know about the filter. The alternative — two lists — makes
   the layout unmistakable and every other consumer a union. I chose the failure
   that is loud over the failure that is silent; that is a judgement, not a
   proof.
2. **Overlay and the peek.** Making an overlay behave as an edge costs some
   complexity in `LanePeek`, and someone will argue that an overlay the user
   placed themselves is not a surprise worth spending it on. Worth having the
   argument with the rails visible on screen.
3. **`DOCK_MIN_PT = 240` is a judgement, not a measurement.** §8's 420 pt has a
   number behind it (80 columns at an 8 pt cell). 240 is "narrow enough for a
   player, wide enough to grab". If a real player needs more, measure one.
4. **The narrow-window degradation is specified and not yet built or seen.**
   Nobody has run two inset docks in an 800 pt window.
5. **The core's audio guarantee is about actions, not about sound.** It proves
   the policy never emits `Evict` or `Unparent` for a docked pane. It cannot
   prove WebKit keeps playing, and if the view half parents the dock somewhere
   that gets hidden, every test in `docking.rs` still passes and the music still
   stops.
