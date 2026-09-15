# ADR 0006 — Placeholder snapshots are JPEG at 1× lane width

**Status:** Accepted · 2026-09-12
**Decides:** PRD §14 — "Snapshot format/resolution for placeholders."
**Evidence:** `spikes/placeholder-snapshots`, removed from the tree in the commit after d66c659 and readable there
(re-runnable; numbers below are from this machine).

## Decision

When a web pane is evicted, snapshot it with `WKSnapshotConfiguration`'s
`snapshotWidth` set to the lane's width in **points** (so 1×, not backing scale),
encode as **JPEG at quality 0.6**, and write it beside the ledger under
`~/Library/Application Support/MaxPane/snapshots/<pane-id>.jpg`.

## The numbers

560 × 1000 pt lane, synthetic page, 10 iterations each:

| Format | Scale | Bytes | Encode | Decode | × 130 lanes |
|---|---|---|---|---|---|
| **JPEG q0.6** | **1×** | **83 677** | **1.19 ms** | **0.03 ms** | **10.4 MB** |
| JPEG q0.8 | 1× | 109 437 | 1.31 ms | 0.03 ms | 13.6 MB |
| PNG | 1× | 210 406 | 7.19 ms | 0.06 ms | 26.1 MB |
| HEIC q0.6 | 1× | 51 438 | **25.91 ms** | 0.16 ms | 6.4 MB |
| JPEG q0.6 | 2× | 222 333 | 4.05 ms | 0.03 ms | 27.6 MB |
| HEIC q0.6 | 2× | 98 308 | **40.32 ms** | 0.27 ms | 12.2 MB |

## Why

**Disk is not the constraint.** Every option fits 130 evicted lanes in under
36 MB. Optimising for file size here is optimising the thing that does not
matter.

**Encode latency is the constraint,** because of *when* it happens. Eviction runs
when WebKit is already over budget — the app is under memory pressure, the user
is scrolling, and several panes may go at once. HEIC costs **22× more encode time
than JPEG** (25.9 ms vs 1.19 ms) to save 32 MB nobody needs. Ten simultaneous
evictions is 12 ms of JPEG or 260 ms of HEIC. Even off the main thread, that is
260 ms of CPU spent compressing images during the exact moment the machine is
short of resources.

**1× is the right resolution, and not only because it is cheaper.** A placeholder
is rendered *dimmed* (PRD §10.3). Its job is to let you recognise a lane while
scrolling past, not to be read. A slightly soft image at 1× on a Retina display
reads as "this is not live", which is information, not a defect. 2× costs 2.7× the
bytes and 3.4× the encode time to make a deliberately inert thing sharper.

**Not PNG.** Lossless is exactly wrong for a photographic-ish rendering of a web
page: 2.5× the size of JPEG q0.6 *and* 6× the encode time, for fidelity that gets
dimmed away.

## Consequences

- **Encode off the main thread.** 1.19 ms is cheap but not free, and eviction is
  a batch operation. `takeSnapshot` returns on the main queue; hop off it before
  encoding and writing.
- **Snapshots are disposable.** `pane.snapshot_path` may point at a file that is
  gone (a cleared cache, a restored backup, a crash between the write and the
  commit). The placeholder view must render a plain dimmed panel with the kind
  glyph and the URL when the image is missing — never an error, never a blank.
- **They are not in the ledger.** SQLite stores the path; the bytes live on disk.
  A 10 MB ledger would make every `state()` slower to no purpose.
- **Delete on close.** A pane's snapshot goes when the pane does, and a sweep at
  launch removes files with no matching pane row.
- **A snapshot keeps the appearance it was taken in.** Added with light/dark
  following: after a switch, the placeholder's frame, dim and caption repaint in
  the new appearance and the picture stays as the page last painted. Re-taking
  it would mean loading the page, the one cost eviction exists to avoid, and
  there is no page left to take it from. The lane's job while evicted is to be
  recognisable, and a dimmed page in the other mode still is. When it
  rehydrates, the page comes back in the current appearance.

## Rejected

- **HEIC.** Best compression, worst timing, against a budget that is not size.
  Revisit only if snapshot storage ever becomes a real complaint.
- **2× / backing scale.** Sharper placeholders, 2.7× the bytes, for an image that
  is dimmed by design.
- **No snapshot at all** (a plain dimmed card with the title and URL). Tempting —
  it is free — but a strip of 130 identical grey cards loses exactly the
  recognise-at-a-glance property that makes the strip navigable. Worth revisiting
  only if spike M1 shows snapshots are not pulling their weight.
