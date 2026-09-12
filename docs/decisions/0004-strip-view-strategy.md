# ADR 0004 — Plain `NSScrollView` with manual view recycling

**Status:** Accepted · 2026-09-12
**Decides:** PRD §14 — "Virtualized strip (`NSCollectionView`) vs. plain
`NSScrollView` with manual view recycling."
**Evidence:** [Spike M4](../spikes/04-m4-strip-scroll.md).

## Decision

**`NSScrollView` with a plain document view and manual lane recycling.**

Virtualization is **required, not optional** — the naive version fails — but it
does not have to be `NSCollectionView`'s.

## The numbers

150 lanes of varied width (420–900 pt, mean 660, a 100 243 pt strip), scripted
full-strip sweep and back at 6 000 pt/s, ~1 700–1 930 frames, 60 Hz panel:

| | A-naive | **A-recycled** | B-`NSCollectionView` |
|---|---|---|---|
| Frame interval mean / p95 / max (ms) | 19.46 / 36.11 / 55.67 | **16.67 / 16.67 / 16.67** | 16.68 / 16.67 / 33.33 |
| **Dropped frames** | **267 (16.16%)** | **0 (0.00%)** | 2 (0.10%) |
| `layout()` per frame | 0.00 | 0.15 | 0.15 |
| Peak live lane views | 151 | **13** | 10 |
| RSS at rest | 148.5 MB | 76.9 MB | 74.1 MB |
| Idle CPU (60 s mean) | 0.015% | 0.032% | 0.014% |
| Time to interactive strip | 876 ms | **132 ms** | 141 ms |

Run twice, twenty minutes apart: naive 12.08% → 16.16%, recycled 0.00% → 0.00%,
collection 0.16% → 0.10%.

Inserting a lane mid-strip and resizing one mid-scroll caused **no hitch in any
variant**. Scroll restoration after teardown and rebuild was exact 3 times out of
3 in all three, including a 0.25 pt fraction.

## Why A over B

They are a tie on every number that matters — 0.00% vs 0.10% drops, 76.9 vs
74.1 MB, 132 vs 141 ms — and the implementations are the same size (79 vs 89
lines). So the decision comes down to which one fights the rest of the app.

**Varied lane widths force a custom layout on B anyway.** Lanes are individually
resizable, so there is no fixed item size; B needs a hand-written
`NSCollectionViewLayout` that sums widths. That is the same arithmetic A does
directly, wrapped in a class that also wants to own it. B saves no work; it
relocates it somewhere less direct.

**`laned-core` is already the source of truth.** The ledger owns lane order and
width. A collection view wants to own its own model and be told about diffs in a
particular order — `insertItems(at:)` throws unless the model and layout are
updated in exactly the right sequence, and needs animation suppression to not
fight a `StripState` that already changed. A's version is `widths.insert()` and
reconcile.

**The reconcile loop is where eviction lives.** PRD §10.2/§10.3 want
kind-dependent behaviour at a distance — unparent a web pane past
`RELEASE_DISTANCE`, keep pty panes parented always, rehydrate within
`REHYDRATE_DISTANCE`. A's reconcile is the natural home for that; in B it would
be pulling against the collection view's own idea of what is visible and when.

That is the whole argument: same numbers, fewer things pulling in opposite
directions.

## Consequences

- `StripViewController` keeps one method, `materializationWindow`, that decides
  which lanes have views. Everything else — focus, reveal-and-flash, scroll
  persistence, eviction relay — is independent of it.
- The window is the viewport plus `RELEASE_DISTANCE` of slack on each side, which
  is where M4's peak of **13 live views for 150 lanes** comes from.
- The document view is sized by summing *all* lane widths, including the ones
  with no view, so the scroller spans the whole strip rather than the built part.
- A lane view leaving the window is recycled; **its pane controllers survive**,
  because a `WKWebView` is expensive to build and cheap to unparent. Only a lane
  that leaves the *ledger* destroys its panes.

## PASS/FAIL against §12

**Conditional pass.**

- *"No layout thrash"* — **PASS.** 0.15 `layout()` and 0 `updateConstraints()`
  per frame.
- *"Scroll at panel rate"* — **PASS** for both virtualized variants, **FAIL** for
  naive.
- *"120 Hz"* — **not verifiable on this machine.** The main display is an LG HDR
  WQHD at **60 Hz**. The built-in Liquid Retina XDR reports
  `NSScreen.maximumFramesPerSecond = 120`, but delivered a 16.667 ms median
  interval — exactly 60 Hz — even with the display link pinned to
  `CAFrameRateRange(120, 120, 120)`. 120 Hz was never observed and the claim
  stands unverified.

## Threats to validity worth carrying forward

- **The screen was locked for every run**, so the window server never composited.
  Frame intervals capture main-thread and Core Animation commit cost, not GPU
  compositing, and are a **lower bound**. Layout counts, memory, idle CPU,
  time-to-interactive and scroll restoration are unaffected. The recycler's
  correctness was verified independently: `cacheDisplay` snapshots from A-naive
  and A-recycled are **byte-identical**.
- **Spike M1 ran concurrently**, with 113 live WebKit processes and a load
  average of 5.5–12.5. That penalises all three variants equally, so the ranking
  holds, but the absolute numbers are pessimistic.
- **Lane views here are cheap stand-ins.** A real lane holds a `WKWebView` or a
  SwiftTerm view. This spike measures the strip, not its contents; M1 measures
  the contents.

## What would make us revisit

- A verified 120 Hz measurement on an unlocked, awake panel. If 120 Hz halves the
  budget to 8.3 ms, recycled's 0.00% has room but is no longer untested.
- A lane count far past 150, where B's more aggressive virtualization (10 live
  views vs 13) might start to matter. At 150 it does not.
