# Spike M5 — a lane as a gallery thumbnail

**Question** ([`docs/work/gallery-layout.md`](../work/gallery-layout.md)): whether a
Ghostty/Metal surface and a `WKWebView` stay sharp and cheap when drawn smaller —
**layer transform vs. a smaller backing** — without resizing anything. ADR-0007
makes "without resizing" the hard part: a terminal whose grid changes sends a
`RESIZE`, and the PTY's size is shared with every client, the phone included.

**Verdict: the transform works; the smaller backing cannot.**

- **Transform** (the view keeps its bounds; its frame in the parent shrinks):
  Ghostty's grid stayed **80×58 at every scale from 0.75 to 0.25, at 1× and 2×,
  with zero resize reports** from either the view or the session. Web layout
  unchanged (`innerWidth` 656, `devicePixelRatio` 2). The surface stays full size.
- **Smaller backing** (fewer pixels per point): Ghostty's cells are whole pixels,
  so the grid **changed at 13 of 14 measured points**. It is a re-flow by
  construction, and it did not even save CPU.
- **Sharpness** under the transform depends on device pixels per lane point.
  Above 0.5, bilinear minification is closest to a Lanczos downscale; at or below
  0.5, trilinear is. The app picks the filter by that rule.

---

## Environment

| | |
|---|---|
| Machine | MacBook Pro (Mac15,7), Apple M3 Pro, 36 GB |
| OS | macOS 26.6.2 (25G83) |
| Emulator | libghostty-spm 1.6.20260909 — the version the app resolves |
| Lane | 656 × 1000 pt (`laneDefaultPt`), JetBrains Mono 13 pt, padding 6/4 |
| Connected panels, as AppKit reported them | LG HDR WQHD @1×, Built-in Retina Display @2× |

The spike window landed on the 1× panel. **2× was rendered by overriding the
window's `backingScaleFactor`**, which is the one property Ghostty reads its
content scale from — so it draws exactly what it would on a 2× panel.

**The smaller backing is emulated**: libghostty-spm keeps `scaleFactor` internal.
A frame of lane × s with the font at × s is the same pixel arithmetic Ghostty
does at content scale × s.

**Compositing is emulated too.** WindowServer composites a transformed layer;
the spike composites Ghostty's own IOSurface through `CARenderer` in-process,
with each minification filter. That is Core Animation's renderer, not
WindowServer's, and the numbers should be read as that.

## How to re-run

```sh
cd spikes/m5-gallery-scale
./build.sh
./run.sh out/1x                  # all phases at the panel's scale
BACKING=2 ./run.sh out/2x        # all phases as a 2× panel
BACKING=2 ./run.sh out/2x-grid grid
```

The app never activates (an `LSUIElement` launched with `open -g`, its window
below the desktop picture), so it is safe to run while someone is working.

---

## 1. Grid: does drawing smaller change what the terminal thinks its size is?

A terminal at the lane's size, with a fixture of agent output, then each
approach. "Reports" counts grid callbacks after scaling — the view delegate's
and the session's, which is the one the app turns into `claimSize`. The control
shrinks the frame with nothing compensating, to prove the detector fires.

| Scale | Transform grid (1× / 2×) | Transform reports (view, session, on return) | Smaller backing (1×) | Smaller backing (2×) | Control |
|---|---|---|---|---|---|
| 1.00 | 80×58 / 80×58 | 0, 0, 0 | 80×58 | 80×58 | 80×58 |
| 0.75 | 80×58 / 80×58 | 0, 0, 0 | **80×57** | **80×57** | 60×43 |
| 0.60 | 80×58 / 80×58 | 0, 0, 0 | **76×59** | **84×56** | 47×34 |
| 0.50 | 80×58 / 80×58 | 0, 0, 0 | **79×54** | **79×57** | 39×28 |
| 0.45 | 80×58 / 80×58 | 0, 0, 0 | **70×55** | 80×58 | 35×26 |
| 0.40 | 80×58 / 80×58 | 0, 0, 0 | **83×56** | **83×56** | 31×23 |
| 0.33 | 80×58 / 80×58 | 0, 0, 0 | **68×53** | **81×58** | 25×18 |
| 0.25 | 80×58 / 80×58 | 0, 0, 0 | **76×60** | **76×53** | 19×14 |

The one backing row that matched (2×, 0.45) matched by rounding luck; its
neighbours on both sides did not. A rule that holds at one scale in fourteen is
not a rule.

## 2. Pixels: how sharp is a transformed tile?

Ghostty's surface (656×1000 at 1×, 1312×2000 at 2×) composited at each scale.
**Mean absolute error per channel against a Lanczos downscale of the same
surface** — the best a picture can do when it has to lose pixels. Lower is
better. The surface was full size under the transform at every scale.

### 2× panel

| Scale | Tile px | Bilinear | Trilinear | Nearest |
|---|---|---|---|---|
| 0.75 | 984×1500 | **1.83** | 3.09 | 4.59 |
| 0.60 | 788×1200 | **2.29** | 3.83 | 4.28 |
| 0.50 | 656×1000 | **1.62** | **1.62** | 6.05 |
| 0.45 | 591×900 | **3.82** | 4.95 | 5.92 |
| 0.40 | 525×800 | **4.19** | 5.87 | 6.29 |
| 0.33 | 433×660 | **5.82** | 6.79 | 7.82 |
| 0.25 | 328×500 | 7.84 | **3.68** | 12.28 |

### 1× panel

| Scale | Tile px | Bilinear | Trilinear | Nearest |
|---|---|---|---|---|
| 0.75 | 492×750 | **2.83** | 5.72 | 6.59 |
| 0.60 | 394×600 | **3.89** | 6.68 | 7.57 |
| 0.50 | 328×500 | 3.71 | **3.70** | 13.11 |
| 0.45 | 296×450 | 8.76 | **5.48** | 12.44 |
| 0.40 | 263×400 | 8.96 | **5.77** | 12.74 |
| 0.33 | 217×330 | 10.50 | **5.84** | 13.92 |
| 0.25 | 164×250 | 13.64 | **3.91** | 15.95 |

**What decides it is device pixels per lane point** (scale × backing), not the
scale. Every one of the fourteen rows agrees with: bilinear above 0.5, trilinear
at or below, a dead heat at exactly 0.5 on both panels. Below half a pixel,
bilinear samples skip whole glyph strokes — its edge energy *rises* above the
Lanczos reference (40.8 against 35.4 at 1×, 0.33), which is aliasing, not
sharpness — and trilinear's pre-filtered levels are what hold the text together.

For scale: a 12-lane gallery lands near 0.45 on a 1728-pt laptop panel (2×, so
0.9 px per point, bilinear) and near 0.5 on the 3840-pt ultrawide (1×, 0.5,
trilinear). The 0.40 pictures — Lanczos, each filter, and the smaller backing —
are committed in `spikes/m5-gallery-scale/out/1x` and `out/2x` for anyone who
would rather squint than read a table; `./run.sh` regenerates every scale.

## 3. Cost: twelve terminals

Twelve surfaces in one window, then 5 s idle and 10 s with every tile printing
~30 coloured lines a second (a busy agent, not `yes`). CPU is this process's
user + system time in cores; GPU time is not in it. Scale 0.4, 2×.

| | Idle | Streaming | IOSurfaces | Footprint Δ | Grid |
|---|---|---|---|---|---|
| Full size, unscaled | 0.047 cores | 7.20 cores | 12 × 1312×2000 = 120.2 MB | +685 MB | 80×58 |
| **Transform** | **0.044 cores** | **7.48 cores** | 12 × 1312×2000 = 120.2 MB | +629 MB | **80×58** |
| Smaller backing | 0.033 cores | 7.89 cores | 12 × 524×800 = 19.5 MB | +298 MB | 83×56 |

- **A transformed tile costs what the lane costs.** Same surface, same CPU.
- **Fewer pixels bought no CPU.** A streaming terminal's cost is parsing and
  shaping, not rasterising — the backing variant was not cheaper at all.
- **Idle is free.** Ghostty releases its display link after a run of idle frames.
- **What the gallery adds is how many render at once.** The strip only renders
  what is on screen; the gallery renders everything. Twelve agents printing at
  once is several cores. ADR-0011 records this and what would change it.

## 4. Web

A `WKWebView` at 656×1000, four ways of drawing it smaller.

| Variant | Scale | `innerWidth` | `devicePixelRatio` | `visualViewport.scale` | On screen | Snapshot |
|---|---|---|---|---|---|---|
| plain | 1 | 656 | 2 | 1 | 656×1000 pt | 1312×2000 |
| **transform** | 0.5 | **656** | **2** | 1 | 328×500 pt | 1312×2000 |
| `pageZoom` | 0.5 | 1312 | 1 | 1 | 656×1000 pt | 1312×2000 |
| `magnification` | 0.5 | 1312 | 1 | 0.5 | 656×1000 pt | 1312×2000 |
| **transform** | 0.33 | **656** | **2** | 1 | 216×329 pt | 1312×2000 |
| `pageZoom` | 0.33 | 1987 | 0.66 | 1 | 656×1000 pt | 1312×2000 |
| `magnification` | 0.33 | 1987 | 0.66 | 0.33 | 656×1000 pt | 1312×2000 |

Both of WebKit's own zooms widen the layout viewport — a re-flow, which the
gallery's decisions forbid for a page as much as for a terminal. Only the
transform keeps the page's layout, and it keeps rendering at 2× underneath.

---

## What this decided

- Tiles are drawn with a transform: `GalleryTileView`'s bounds are the lane's
  real size and its frame is the tile.
- Terminal surfaces get a minification filter by device pixels per lane point:
  `GalleryLayout.minificationFilter`.
- Nothing about the web path needed changing to be sharp; its memory is what
  needed a decision — ADR-0011.

## What it did not measure

- WindowServer's own compositing of a transformed layer; see *Environment*.
- A real RelayTTY attach under the gallery. The grid invariance is Ghostty's,
  and the pane's `claimSize` is driven only by that grid.
- WebKit memory with twelve live pages in the gallery. The policy change in
  ADR-0011 is argued from how `eviction::plan` ranks candidates, not measured.
