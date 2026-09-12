# Spike M4 — fullscreen strip scroll with 150 lanes

**Question (PRD §12):** Fullscreen `NSWindow` + horizontal `NSScrollView` with 150 lane
views: scroll at 120 Hz, no layout thrash.
**Pass criterion:** measured; lane views virtualized if needed.

**Verdict: CONDITIONAL PASS.** Both virtualized strategies hold the panel's cadence with
essentially zero dropped frames (0.00 % and 0.10 %) and no layout thrash. **120 Hz was
never delivered by this machine and therefore could not be verified** — see *The 120 Hz
problem*. Virtualization is **required**: the naive 150-view strip drops **12–16 % of
frames**.

**§14 decision: use plain `NSScrollView` with manual view recycling (A-recycled).**
Reasoning in *Recommendation for §14*.

---

## Environment

| | |
|---|---|
| Machine | MacBook Pro (Mac15,7), Apple M3 Pro — 12 cores (6P/6E), 18-core GPU |
| RAM | 36 GB |
| OS | macOS 26.6.2 (25G83), arm64 |
| Swift | swift-driver 1.148.6, Apple Swift 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101) |
| Clang | Apple clang 21.0.0 |
| Xcode | **none** — Command Line Tools only (`/Library/Developer/CommandLineTools`). `xcodebuild` was never invoked. |
| Build | SwiftPM executable target, release; hand-assembled `.app`; ad-hoc `codesign -s -` |

### Displays — read this before reading any frame number

`system_profiler SPDisplaysDataType` plus `NSScreen` from inside the app:

| # | Display | Points | Backing scale | `NSScreen.maximumFramesPerSecond` | Refresh interval range |
|---|---|---|---|---|---|
| 0 | LG HDR WQHD (**main display**) | 3840 × 1600 | 1.0 | **60** | 16.667 ms fixed |
| 1 | Built-in Liquid Retina XDR | 1728 × 1117 | 2.0 | **120** | 8.333 – 41.667 ms (ProMotion, variable) |

**The main display is a 60 Hz panel.** "Scroll at 120 Hz" cannot be verified on it. The
built-in panel advertises 120 Hz, so the matrix was run on both. See *The 120 Hz problem*
for what actually came back.

---

## How to re-run

```sh
cd spikes/m4-strip-scroll
./build.sh                  # swift build -c release, assemble StripBench.app, ad-hoc codesign
./run-matrix.sh results     # the 3-variant x 2-screen matrix below (~11 min)
./analyze.py results        # renders the comparison tables

# one variant on its own:
./run.sh recycled 0 out/one.json --lanes 150 --velocity 6000 --idle-seconds 60

# prove it actually renders (works even with the screen locked):
open -n StripBench.app --args --variant recycled --screen 0 --lanes 150 \
  --snapshot "$PWD/out/snap.png" --snapshot-x 18000 --out "$PWD/out/snap.json"
```

Raw results are committed under `spikes/m4-strip-scroll/results/` (matrix 2, the run
quoted here) and `results-run1/` (an independent earlier repeat, for variance).
Each JSON carries the full per-frame interval array for both sweeps.

---

## What was built

Three strip implementations behind `--variant`, rendering the **same 150 lane views**
in the same borderless full-screen-covering window:

| Variant | Strategy | Impl. size |
|---|---|---|
| **A-naive** | `NSScrollView` + flipped document view, all 150 lane views instantiated and parented, frames set once. No recycling. | 45 lines |
| **A-recycled** | Same, but only lanes intersecting the viewport ±2 are attached; offscreen views return to a pool and are reconfigured on re-attach. Driven by `NSView.boundsDidChangeNotification` on the clip view. | 79 lines |
| **B-collectionview** | `NSCollectionView` + a custom `NSCollectionViewLayout` that lays lanes out at their individual widths, with `NSCollectionViewItem` reuse. | 58 + 31 lines |

All three share a 35-line `LaneModel` (widths → x-offsets, binary search by x) and a
12-line scroll-view setup.

**Lane fixture.** 150 lanes, widths drawn from a seeded LCG **uniformly over the full
[420 pt, 900 pt] range** — deliberately not uniform-width, because lanes are user-resizable
and a fixed-item-size collection layout would be invalid. Actual: **mean 660.3 pt, min 421 pt,
max 894 pt, total strip 100 243 pt.** Each lane view is layer-backed with square corners, a
header label, a Signal-Orange project-tag chip, an orange `$` prompt marker and 12
monospaced text rows — 16 subviews per lane, ~2 400 views for the naive strip.

**Scripted scroll.** A `CADisplayLink` obtained from `NSView.displayLink(target:selector:)`,
with `preferredFrameRateRange` pinned to the screen's advertised maximum. Each callback
advances a constant-velocity **6 000 pt/s** sweep, sets the clip view origin via
`contentView.scroll(to:)` + `reflectScrolledClipView`, then forces a synchronous display
pass. The clean sweep runs the **full strip and back** (2 × 100 243 pt ≈ 32 s, ~1 700–1 970
frames). No hand scrolling anywhere.

**Render correctness.** Because the screen was locked (below), the strip was verified by
`cacheDisplay(in:to:)` into a bitmap at scroll offset 18 000 pt. A-naive and A-recycled
produce **byte-identical PNGs** (md5 `e8e784fd…`), which is direct evidence the recycler
attaches the right lanes at the right offsets; B renders the same strip.

---

## The 120 Hz problem

This is the headline caveat, and it is a property of the machine, not of the code.

1. **The main display is 60 Hz.** `NSScreen.maximumFramesPerSecond` = 60, refresh interval
   fixed at 16.667 ms. On this panel 120 Hz is not a question that can be asked.
2. **The 120 Hz panel did not deliver 120 Hz.** On screen 1, `NSScreen` reports
   `maximumFramesPerSecond` = 120, and the display link was explicitly pinned to
   `CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)`. The **median delivered
   interval was 16.667 ms — exactly 60 Hz** (17.72 ms for A-naive). Not one run reached
   the 8.333 ms budget.

Consequently the raw "dropped frames vs the 8.333 ms budget" column for screen 1 reads
96–99 % for **every** variant including the ones that never miss a beat — it is measuring
the panel, not the strip. The honest comparator on that screen is **drops against the
cadence the display link actually delivered** (median interval × 1.5), which is reported
alongside.

Why the panel stayed at 60 Hz cannot be isolated here: the session was locked for the whole
spike (below), and ProMotion drops to a low idle rate behind the login window. **A
re-measurement on an unlocked, awake 120 Hz panel is required before M4 can be called an
unconditional pass.**

---

## Results — main display (60 Hz, the panel Scott actually works on)

150 lanes, 6 000 pt/s, full-strip sweep and back. Frame budget **16.667 ms**; a dropped
frame is an interval > 1.5 × budget.

| Metric | A-naive | A-recycled | B-collectionview |
|---|---|---|---|
| Frames measured (clean sweep) | 1652 | 1929 | 1927 |
| Sweep duration (s) | 32.1 | 32.1 | 32.1 |
| **Frame interval mean (ms)** | **19.46** | **16.67** | **16.68** |
| Frame interval p50 (ms) | 16.67 | 16.67 | 16.67 |
| Frame interval p95 (ms) | 36.11 | 16.67 | 16.67 |
| Frame interval p99 (ms) | 37.87 | 16.67 | 16.67 |
| Frame interval max (ms) | 55.67 | **16.67** | 33.33 |
| **Dropped frames (count)** | **267** | **0** | **2** |
| **Dropped frames (%)** | **16.16 %** | **0.00 %** | **0.10 %** |
| Severe drops (> 2.5 × budget) | 10 | 0 | 0 |
| Main-thread work / frame, mean (ms) | 2.86 | 3.14 | 3.04 |
| Main-thread work / frame, p95 (ms) | 4.44 | 4.53 | 5.46 |
| Main-thread work / frame, p99 (ms) | 5.44 | 7.09 | 8.15 |
| Main-thread work / frame, max (ms) | 19.28 | 15.94 | 17.52 |
| Frames with work > budget | 1 | 0 | 2 |
| **`layout()` calls / frame (mean)** | **0.00** | **0.15** | **0.15** |
| `layout()` calls / frame (max) | 0 | 1 | 2 |
| `layout()` calls, whole 32 s sweep | 0 | 284 | 290 |
| `updateConstraints()` calls (whole process) | 601 | 447 | 10 |
| **Lane views instantiated (whole run)** | **151** | **13** | **10** |
| `configure()` calls (whole run) | 151 | 393 | 386 |
| **Peak live lane views / 150** | **151 / 150** | **13 / 150** | **10 / 150** |
| RSS at rest, 150 lanes (MB) | **148.5** | **76.9** | **74.1** |
| Phys. footprint at rest (MB) | **89.9** | **18.9** | **17.7** |
| RSS after full sweep (MB) | 138.9 | 75.0 | 79.2 |
| **Idle CPU mean (% of one core, 60 s)** | **0.015 %** | **0.032 %** | **0.014 %** |
| Idle CPU max (% of one core) | 0.140 % | 0.850 % | 0.353 % |
| **Time to interactive strip, from `exec` (ms)** | **876** | **132** | **141** |
| Time to interactive strip, from `main()` (ms) | 688 | 111 | 115 |
| Viewport (pt) | 3840 × 1600 | 3840 × 1600 | 3840 × 1600 |
| System load average during run | 6.75 | 8.62 | 5.51 |

### Reproducibility

The matrix was run twice, independently, ~20 minutes apart:

| Dropped frames, clean sweep, main display | A-naive | A-recycled | B-collectionview |
|---|---|---|---|
| Matrix 1 (`results-run1/`) | 12.08 % | 0.00 % | 0.16 % |
| Matrix 2 (`results/`) | 16.16 % | 0.00 % | 0.10 % |

The ordering and the order of magnitude are stable. A-naive's absolute figure moves with
system load; the virtualized variants do not move at all.

## Results — built-in ProMotion panel (advertised 120 Hz, delivered 60 Hz)

| Metric | A-naive | A-recycled | B-collectionview |
|---|---|---|---|
| Advertised `maximumFramesPerSecond` | 120 | 120 | 120 |
| Budget implied by that (ms) | 8.333 | 8.333 | 8.333 |
| **Median interval actually delivered (ms)** | **17.72** | **16.67** | **16.67** |
| Dropped frames vs the 8.333 ms budget | 96.49 % | 99.90 % | 99.80 % |
| **Dropped frames vs delivered cadence** | **9.78 %** | **0.10 %** | **0.00 %** |
| Frame interval p95 / p99 / max (ms) | 29.20 / 32.24 / 51.35 | 16.67 / 16.67 / 33.50 | 16.67 / 17.11 / **22.79** |
| Severe drops (> 2.5 × 8.333 ms) | 567 | 4 | **3** |
| Main-thread work / frame, mean (ms) | 2.42 | 3.74 | 3.78 |
| Lane views instantiated (whole run) | 151 | 9 | **5** |
| Peak live lane views / 150 | 151 / 150 | 9 / 150 | **5 / 150** |
| RSS at rest (MB) | 147.8 | 75.3 | 75.0 |
| Time to interactive strip, from `exec` (ms) | 402 | 380 | 275 |
| Viewport (pt) | 1728 × 1117 | 1728 × 1117 | 1728 × 1117 |

The 1 728 pt viewport holds only ~2.6 lanes, versus ~5.8 on the ultrawide, which is why the
virtualized variants instantiate even fewer views here (5–9 instead of 10–13). The naive
strip's cost does not change, because it has already paid for all 150.

## Mid-strip insert and mid-scroll resize

During a second scripted sweep, a lane was **inserted three lanes ahead of the viewport at
t = 3 s** and a visible lane **resized by +220 pt at t = 7 s**, both executed inside the
display-link callback so the cost is attributed to a specific frame.

| | A-naive | A-recycled | B-collectionview |
|---|---|---|---|
| Insert: work in that frame (ms) | 3.09 | **3.13** | 7.66 |
| Insert: max interval over next 10 frames (ms) | 16.67 | 16.67 | 16.67 |
| Insert: visible hitch? | **no** | **no** | **no** |
| Resize: work in that frame (ms) | 3.35 | 3.24 | **2.26** |
| Resize: max interval over next 10 frames (ms) | 16.67 | 16.67 | 16.67 |
| Resize: visible hitch? | **no** | **no** | **no** |

**No variant hitched on either operation**, on either display, in either matrix run. All
three stayed exactly on cadence for the following 10 frames.

The perturbation sweeps do contain isolated spikes — the largest being **158.7 ms in
s0-collection** — but they are **not correlated with the events**: that spike lands at frame
95 while the insert happened at frame 172, and in-callback work for that frame was only
5.2 ms. Spikes appear at random frame indices with low in-callback work in every variant,
which is the signature of external system contention (see *Threats to validity*), not of the
strip.

What the operations cost structurally:

- **A-naive** must re-frame all 150 views on every insert *and* every resize (`applyFrames()`
  is O(n)). It got away with 3 ms at n = 150; that is linear in lane count.
- **A-recycled** re-frames only the ~13 attached views, plus an O(n) prefix-sum over the
  width array. The insert also has to shift the attached-index map.
- **B-collectionview** needs the model updated *before* `insertItems(at:)` or
  `NSCollectionView` throws on a data-source/layout count mismatch, and needs
  `invalidateLayout()` around both operations. `insertItems` was wrapped in a zero-duration
  `NSAnimationContext` to suppress the default animation; it did not throw and did not hitch,
  but it is the most fragile of the three code paths.

## Scroll position restoration (§8)

For each of three targets: set the content offset, tear the strip down completely, rebuild
all 150 lanes, restore the saved offset, compare.

| Requested | After set | After teardown → rebuild → restore | Exact? |
|---|---|---|---|
| 12 345.0 | 12 345.0 | 12 345.0 | **yes** |
| 21 734.25 | 21 734.25 | 21 734.25 | **yes** |
| 97 095.0 (max) | 97 095.0 | 97 095.0 | **yes** |

**3 / 3 exact, in all three variants, on both displays** — including the sub-point 0.25
fraction on the 1× panel and the 2× panel. `NSClipView` did not snap or clamp the offset.
Restoring the strip position across a relaunch is a matter of persisting one `Double`;
nothing in AppKit rounds it away.

---

## Pass/fail against "scroll at 120 Hz, no layout thrash"

| Clause | Verdict |
|---|---|
| **Scroll at 120 Hz** | **Not verifiable on this machine.** The main display is 60 Hz. The built-in ProMotion panel reported 120 Hz but delivered a 16.667 ms median interval (60 Hz) despite an explicit 120 Hz `CAFrameRateRange`. Re-measure on an unlocked, awake 120 Hz panel before closing this. |
| **Scroll at the panel's actual rate** | **PASS** for both virtualized variants: 0.00 % (A-recycled) and 0.10 % (B) dropped frames over a 32 s full-strip sweep at 60 Hz, p99 exactly at cadence. **FAIL** for A-naive: 16.16 % dropped, p95 36.11 ms, max 55.67 ms. |
| **No layout thrash** | **PASS** for all three. `layout()` runs **0.15 times per frame** in the virtualized variants — i.e. a lane view lays out roughly once every 7 frames, only when it is attached or resized, never repeatedly within a frame. 284–290 `layout()` calls across a 32 s sweep that crossed 300 lane boundaries. `updateConstraints()` runs ~once per lane view ever created and **zero times per frame** (the lane views use manual frame layout, not Auto Layout). |
| **Lane views virtualized if needed** | **Needed, and confirmed working.** Peak live views 13/150 (A-recycled) and 10/150 (B) versus 151/150 naive. |
| §10.1 idle CPU < 2 % of one core | **PASS** with three orders of magnitude of headroom: 0.014–0.032 % mean over 60 s, worst single sample 0.850 %. |
| §10.1 relaunch to interactive < 3 s (layout share) | **PASS**: 132 ms (A-recycled) / 141 ms (B) from `exec` to a laid-out, scrollable 150-lane strip — ~4.5 % of the 3 s budget. A-naive needs 876 ms, ~29 % of the budget, for nothing. |
| §8 opening a lane never resizes neighbours | Holds by construction in all three — lane widths are independent model values; insert only shifts offsets. |
| §8 strip scroll position persists | **PASS**: exact restoration, 3/3 targets, all variants. |

---

## Recommendation for §14

> *Virtualized strip (`NSCollectionView`) vs. plain `NSScrollView` with manual view recycling.*

### Use plain `NSScrollView` with manual view recycling.

**One-line justification:** it matches `NSCollectionView` on every measured number that
matters (0.00 % vs 0.10 % dropped frames, 76.9 MB vs 74.1 MB RSS, 132 ms vs 141 ms to
interactive) while keeping the strip's geometry, insertion and lane-width model as plain
data the app owns outright — and Max Pane needs to own that model anyway, because
`laned-core` is the source of truth for lane order and width.

**The numbers that justify it:**

| | A-recycled | B-collectionview |
|---|---|---|
| Dropped frames, 32 s sweep | **0 / 1929 (0.00 %)** | 2 / 1927 (0.10 %) |
| Frame interval max | **16.67 ms** (never missed a beat) | 33.33 ms |
| Peak live lane views | 13 / 150 | **10 / 150** |
| RSS at rest | 76.9 MB | **74.1 MB** |
| Time to interactive | **132 ms** | 141 ms |
| Mid-strip insert cost | **3.13 ms** | 7.66 ms |
| Mid-scroll resize cost | 3.24 ms | **2.26 ms** |
| Implementation size | 79 lines | 58 + 31 = **89 lines** |

There is no performance argument between them. B is marginally leaner on live views; A is
marginally better on worst-case frame interval and insert cost. Both differences are inside
run-to-run noise on a loaded machine. **The decision therefore turns on control and
failure modes, and there A wins:**

1. **Varied lane widths are a first-class problem for B and a non-problem for A.**
   Lanes are user-resizable across [420, 900] pt, so `NSCollectionViewFlowLayout`'s
   fixed `itemSize` is invalid, and B *requires* a custom `NSCollectionViewLayout`
   (31 lines) that recomputes every item's attributes in `prepare()` — which is precisely
   the prefix-sum-over-widths that A-recycled already needs for its own scrolling. B does not
   save that work; it wraps it in a framework contract and then asks for it again.
2. **Mid-strip insert is the fragile path in B.** `insertItems(at:)` throws an
   `NSInternalInconsistencyException` unless the data source's count and the layout are
   updated in exactly the right order first, needs `invalidateLayout()` around it, and needs
   a zero-duration `NSAnimationContext` to suppress an animation nobody asked for. In A,
   inserting a lane is `widths.insert(w, at: i)`, recompute offsets, reconcile. Max Pane
   inserts lanes constantly (§6: every spawned pane can create one) — this path must be
   boring.
3. **A's reconcile loop is the natural home for §10.2 eviction.** The PRD already requires
   distance-from-viewport policy: web panes beyond `RELEASE_DISTANCE` (6) unparented but
   kept alive, rehydrate within `REHYDRATE_DISTANCE` (2), pinned panes never evicted, pty
   panes always parented. That is *per-lane, kind-dependent, policy-driven* attach/detach with
   different radii for different pane kinds. A-recycled's reconcile already computes exactly
   that range and is 79 readable lines. `NSCollectionView` insists on owning attach/detach
   itself and only offers one radius; implementing §10.2 on top of it means fighting the
   reuse queue.
4. **Correctness is already demonstrated.** A-recycled's rendered output is
   **byte-identical** to the all-views-parented naive strip at the same offset. The recycler
   is not approximating anything.
5. **Complexity cost is a wash, and A's complexity is legible.** 79 lines versus 89. A's is
   one reconcile function reading a width array; B's is spread across a layout subclass, a
   data source, an item class and batch-update ordering rules enforced by exceptions at
   runtime.

**What the ADR should also record:**

- Virtualization is **not optional**. A-naive drops 12–16 % of frames, uses **2 × the RSS**
  (148.5 MB vs 76.9 MB) and **5 × the physical footprint** (89.9 MB vs 18.9 MB), and burns
  876 ms of the 3 s relaunch budget — with *cheap stand-in* lane views. With `WKWebView`s it
  is not a candidate at all.
- The recycling buffer used here is **±2 lanes**, giving 13 live views for a 3 840 pt
  viewport. §10.2's `RELEASE_DISTANCE = 6` is a *different, larger* radius for keeping web
  panes alive-but-unparented; the two radii are independent knobs and both belong in the
  reconcile step.
- Lane views must keep using **manual frame layout inside `layout()`, not Auto Layout**.
  The measured `updateConstraints()` count is zero per frame precisely because there are no
  constraints; a constraint-based lane would put the solver on the scroll path.

---

## Threats to validity

Ordered by how much they should worry you.

1. **The Mac's screen was locked for the entire spike.**
   `CGSessionCopyCurrentDictionary()` reported `CGSSessionScreenIsLocked = 1` throughout;
   every run recorded it (`screenLockedAtStart: true`). The login window covered the session,
   so `window.occlusionState` never contained `.visible` and **the window server never
   composited the strip**. Unlocking requires Scott's password, so this could not be removed.
   Consequences:
   - The per-frame **main-thread** work is real and was genuinely incurred — the benchmark
     forces a synchronous `displayIfNeeded()` every frame, and the `cacheDisplay` snapshots
     prove the lane content really rasterizes. Layout counts, view instantiation counts,
     memory, idle CPU, TTI and scroll restoration are **unaffected** by the lock.
   - **GPU compositing of the layer tree was not exercised.** The frame-interval numbers
     therefore capture main-thread stalls and CA commit cost, not render-server cost. They
     are a **lower bound** on frame time.
   - The measurement still discriminates strongly — A-naive drops 16 % of frames under
     exactly these conditions — so the *ranking* is trustworthy even if the absolute
     smoothness of the winners is optimistic.
   - **This is the reason M4 is a conditional pass. Re-run on an unlocked, awake display.**
2. **Spike M1 was running concurrently, hammering the machine.** Another agent's WebKit
   spike held **113 `com.apple.WebKit.*` processes** live during the matrix; the 1-minute
   load average recorded inside each run was **5.51 to 12.52** on a 12-core machine. This
   inflates frame intervals and idle-CPU samples for every variant, and it is the most likely
   source of the isolated 26–159 ms spikes that appear at uncorrelated frame indices with
   low in-callback work. It penalises all three variants roughly equally, so the comparison
   holds; the absolute numbers are pessimistic. A quiet-machine re-run would tighten them.
3. **120 Hz was never delivered.** Covered above. Everything labelled "120 Hz" in this
   document is an advertised capability, not an observed one.
4. **Lane views here are cheap stand-ins, not WebKit.** 16 subviews of layer-backed
   `NSTextField`s per lane. A real lane holds `WKWebView`s and SwiftTerm views. This spike
   proves the *strip layout and scroll machinery* is not the bottleneck; it proves nothing
   about what 150 real panes cost. That is M1's job, and M1's answer will dominate the
   memory picture — note that A-naive's 148 MB here is already 2× A-recycled with views that
   are almost free.
5. **The frame clock is the display link's own timestamp, not a GPU present timestamp.**
   Drops are inferred from skipped or late callbacks (`CADisplayLink.timestamp` deltas),
   cross-checked against wall-clock `CACurrentMediaTime()` deltas at callback entry — both
   are reported and they agree on the ranking. Neither proves a frame reached the panel.
   Instruments' Core Animation instrument would, and needs Xcode, which this machine
   does not have.
6. **Constant-velocity scroll, not real input.** 6 000 pt/s in a straight line is
   reproducible but is not a trackpad fling: no momentum curve, no rubber-banding, no
   direction reversals mid-gesture, and elasticity was disabled. Real scrolling also runs
   through `NSScrollView`'s own event path rather than programmatic `scroll(to:)`.
7. **The sidebar (§2.8, ⌘B) is not in the window.** An `NSOutlineView` at the left edge
   changes the viewport width and adds a second view tree to the same window. The strip's
   layout assumptions survive it (the clip view width is read live every reconcile), but it
   was not measured.
8. **Single process, single window, no `laned-core`.** No FFI calls on the scroll path, no
   SQLite writes, no snapshotting. M3 measured the FFI separately at 2.4 ms per `state()`
   round-trip — which is 15 % of a 60 Hz frame budget and must not land on the scroll path.
9. **Idle CPU was sampled with nothing focused and no panes doing work.** Real idle has
   WebKit timers, blinking cursors and pty output. The 0.014–0.032 % here is the floor
   contributed by the strip itself, not the app's idle cost.
