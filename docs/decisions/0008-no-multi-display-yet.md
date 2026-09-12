# ADR 0008 — Multi-display is not built

**Status:** Accepted · 2026-09-12
**Concerns:** PRD §13 Phase 3 — "Multi-display (one strip per display)."

## Decision

Export/import and lane spanning are built. **Multi-display is not**, and should
not be until Phase 2's exit criterion has actually been met.

## Why

Phase 3 is gated: *"Nice-to-haves (only if Phase 2 holds)."* Phase 2's exit is
**"150 lanes for one week within targets"** — a fact about how the app behaves
while someone lives in it, which no amount of building can establish. Only Scott
can close that gate, and only by using it.

The other two Phase 3 items were built anyway because they are self-contained and
because they help *during* the trial rather than after it:

- **Export/import** is the safety net for the trial itself. A layout that took
  days to arrange is worth being able to copy before doing something that might
  disturb it, and the PRD's own definition of done involves two weeks of
  accumulated arrangement.
- **Lane spanning** is a narrow, bounded exception (1 or 2, never 3) that costs
  one column in the ledger and answers a question the trial will raise on day one
  — what happens when a site genuinely cannot be read in portrait.

Multi-display is different in kind:

1. **It contradicts a stated v1 boundary.** §3 lists "Multi-window,
   multi-display (single fullscreen window on one display for v1)" as a
   *non-goal*, and §17's definition of done says nothing about a second screen.
2. **It is a schema and window-management change, not a feature flag.** One strip
   per display means lanes belong to displays, which means a migration, a
   window controller per screen, and a decision about what happens when a display
   is unplugged with lanes on it. None of that is hard; all of it is irreversible
   in the sense that it complicates every later change to the strip.
3. **Its design depends on the answer Phase 2 produces.** Whether a second
   display should hold a *second strip*, or a *gathered view* of the first, or
   the memory dashboard and sidebar while the main display stays pure strip, is
   exactly the kind of question two weeks of use answers and speculation does
   not. Building it now means building the wrong one confidently.

§16 lists "scope creep toward a browser" as a risk. This is the same risk wearing
a different hat: the most expensive Phase 3 item, built before the thing that was
supposed to justify it.

## What would change this

Phase 2 holding — 150 lanes for a week within targets — and Scott wanting a
second display, having discovered *for what*. At that point this ADR should be
superseded by one that says which of the three shapes above won, and why.
