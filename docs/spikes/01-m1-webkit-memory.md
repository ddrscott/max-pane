# Spike 01 — M1: 100 `WKWebView`s in one process pool

**Status:** run 2026-09-12 · **Owner:** Scott Pierce · **Gates:** PRD §12 M1, feeds §9, §10.1, §10.2, §10.3

> Every number in this document came out of a program that was run on this machine on
> 2026-09-12, across three complete runs. Nothing is estimated except §5.8, which is
> labelled **EXTRAPOLATION** and is arithmetic on the measured 100-pane points. Where a
> measurement is invalid, it says so rather than guessing.

---

## 0. Verdict

| M1 pass criterion (§12) | result | evidence |
|---|---|---|
| **numbers recorded** | ✅ **PASS** | §5, §6, §7 — two full 100-view fixture runs plus one real-network run, every figure from `report-*.json` |
| **re-parent < 100 ms** | ✅ **PASS on the structural path** / ⚠️ **first-visible-frame not measured** | Across 3 runs × 25 trials: median **1.1–1.9 ms** to return from `addSubview`, **1.3–2.0 ms** to CA commit, **5.4–8.3 ms** to the next display refresh (p95 14.5–21.7 ms). All ≥ 12× under budget even at p95. The one timestamp that would prove *visual* readiness could not be taken — §8. |
| **idle CPU < 2 %** | ✅ **PASS** | **0.05–0.07 %** of one core on fixtures, **0.13–0.18 %** on 100 real sites; worst single 5 s window across six 60 s measurements was **0.54 %**. App + all 100+ helpers. ≥ 3.7× under budget at the worst sample. Measured with every pane suspended, so it is a floor — §6. |
| *(the real question)* **does unparenting suspend rendering?** | ❌ **NOT PROVEN** | The screen was locked for the whole session, so macOS occluded the window and WebKit suspended *everything*, control included. §8 has the full diagnosis and the one command that closes it. |

### The four things to take away

1. **WebKit gave one `WebContent` process per `WKWebView` — 100 views, 100 processes —
   with no site coalescing whatsoever**, and `WKProcessPool` is a deprecated no-op.
   §9's model of web-pane resourcing is wrong and should be rewritten (§9.1).
2. **Unparenting reclaims 3.5 MB per pane. Destroying the `WKWebView` reclaims 24.7 MB
   (fixtures) / 90.8 MB (real sites) and kills the process immediately.** The unparent
   saving is page-weight independent — on real sites it is **4 %** of what eviction buys.
   §10.2 is not a memory strategy; §10.3 is the only lever that moves memory (§9.3).
3. **Real pages cost 3.4× what synthetic ones do, and that reframes §10.1.** 100 real
   sites measured **9.48 GB** (≈95 MB/pane) against 2.76 GB for heavy fixtures.
   130 real panes extrapolates to **≈11.7 GiB — about 36 % of a 32 GiB Mac** (§5.8).
   Achievable, but §10.1 should say so out loud or lower the number to ≈86.
4. **Process count is the unprobed risk.** 130 panes means ≥130 OS processes — the real
   run produced 101 processes for 100 views — and nothing here found the ceiling (§9.5).

---

## 1. Machine, OS, toolchain

| | |
|---|---|
| Machine | MacBook Pro, Apple **M3 Pro** (`machdep.cpu.brand_string`) |
| Cores | 12 logical — 6 performance + 6 efficiency (`hw.perflevel0/1.logicalcpu`) |
| RAM | **38 654 705 664 B = 36.0 GiB / 38.7 GB** (`sysctl hw.memsize`) |
| macOS | **26.6.2**, build 25G83; Darwin 25.6.0 `xnu-12377.161.14~5` arm64 |
| Swift | Apple Swift **6.3.3** (swiftlang-6.3.3.1.3, clang-2100.1.1.101), target `arm64-apple-macosx26.0` |
| Toolchain | **Command Line Tools only** — `/Library/Developer/CommandLineTools`. `xcodebuild` is not installed. |
| Clang | Apple clang 21.0.0 |

The 32 GB figure in §10.1 is the design target; this machine has 36 GiB, so it is
a fair proxy — slightly generous.

---

## 2. How it was built (no Xcode)

`xcodebuild` does not exist on this machine. The spike is a **SwiftPM executable target**
that is hand-assembled into a `.app` bundle and ad-hoc signed, because `WKWebView` will
not spawn its XPC content processes from a bare, unbundled binary.

```
spikes/m1-webkit-memory/
  Package.swift               swift-tools-version 6.0, macOS 14 platform
  Sources/CProcInfo/          C shim over <libproc.h>: proc_pid_rusage, proc_listpids, proc_pidpath
  Sources/M1Spike/
    main.swift                the timer-driven state machine + all measurement
    ProcMetrics.swift         per-process phys_footprint / RSS / CPU-time sampling
    URLSets.swift             the two 100-URL sets (local fixtures, real network)
  fixtures/serve.py           threaded HTTP fixture server on 20 loopback ports
  fixtures/assets/            real Bootstrap 5.3.3, highlight.js 11.9, marked 12.0.2, lodash 4.17.21
  build.sh                    swift build -c release -> .app bundle -> codesign -s - --force --deep
  run.sh                      fixture server + build + run + external ps cross-check
  run_when_unlocked.sh        same, but blocks until the screen is unlocked
  sample_external.sh          independent `ps` sampler (cross-check of the in-app numbers)
  summarize.py / analyze_ps.py  turn the JSON / CSV artifacts into the tables below
```

### Re-running it

```sh
cd spikes/m1-webkit-memory
./run.sh fixtures     # deterministic local fixtures  (~5 min)
./run.sh real         # 100 real URLs over the network (~7 min)

# the visibility-dependent half (see §7) needs an unlocked screen:
./run_when_unlocked.sh fixtures 3600
```

`build.sh` alone does the bundle-and-sign dance:

```sh
swift build -c release
# -> build/M1Spike.app/Contents/MacOS/M1Spike
#    build/M1Spike.app/Contents/Info.plist  (CFBundleIdentifier com.leftjoin.maxpane.m1spike,
#                                            CFBundlePackageType APPL, NSPrincipalClass NSApplication)
codesign -s - --force --timestamp=none --deep build/M1Spike.app
```

Artifacts of each run land in `spikes/m1-webkit-memory/out/<mode>-<timestamp>/`:
`report-<mode>.json` (every number), `run.log`, `ps-samples.csv` (external cross-check),
`environment.txt`, `build.log`.

---

## 3. What was actually loaded

Nothing loads `about:blank`. Two 100-URL sets were used; both were run end to end.

### 3a. `fixtures` (deterministic, the primary run)

A threaded Python HTTP server (`fixtures/serve.py`) serves four page shapes, each built
from **real** front-end payloads — Bootstrap 5.3.3 (232 803 B), highlight.js 11.9.0
(121 727 B) which actually runs over every code block on load, marked 12.0.2 (35 479 B)
and lodash 4.17.21 (73 015 B): **464 339 B of real CSS/JS on every page**.

| shape | count of the 100 | HTML bytes | approx. elements | extra |
|---|---:|---:|---:|---|
| `doc` — documentation page: 24 sections, 96 paragraphs, 24 highlighted Swift blocks, 24 tables | 33 | 69 756 | ~2 341 | — |
| `repo` — GitHub-ish: 60-row file table + 10 highlighted blobs | 31 | 22 295 | ~671 | — |
| `feed` — news/card feed | 32 | 8 169 | ~183 | **12 × ~300 KB PNG** (≈3.6 MB, ≈397 KB each once decoded at 420×236) |
| `anim` — instrument page: `requestAnimationFrame` canvas loop + CSS keyframe spinner | 4 (indices 1, 5, 50, 99) | 1 674 | ~39 | startable/stoppable from native |

The 100 URLs are spread over **20 loopback ports (127.0.0.1:8801–8820)** specifically to
probe whether WebKit's process-per-site coalescing keys on port. PNG bodies are
noise-filled so they compress like photographs rather than like a solid colour.

### 3b. `real` (network, the cross-check)

96 real URLs over ~60 registrable domains, picked to look like Scott's working set —
MDN, developer.apple.com, doc.rust-lang.org, GitHub repo pages, docs.rs, Cloudflare
developer docs, kubernetes.io, postgresql.org, Hacker News, lobste.rs, Ars Technica,
The Verge, AP, Reuters, Stack Overflow, PyTorch/pandas/numpy docs, go.dev, git-scm,
man7, grafana, prometheus, opentelemetry, nginx — plus the same 4 local `anim`
instrument pages at indices 1/5/50/99 so the suspension probe stays deterministic.
The full list is in `Sources/M1Spike/URLSets.swift` and is echoed into every
`report-real.json` under `urls`.

---

## 4. What the program does

One `WKProcessPool`. **Three** `WKWebsiteDataStore`s, **persistent**, created with
`WKWebsiteDataStore(forIdentifier:)` and assigned round-robin (`i % 3`).

> Persistent rather than `.nonPersistent()` on purpose. §9 wants a project's panes to
> share cookies and logins, which requires persistence; and a non-persistent store keeps
> its HTTP cache *in RAM*, which would have pushed the memory number in the flattering
> direction for the wrong reason. Persistent stores put the cache on disk, so the RSS
> measured here is the RSS the shipping app will see.

100 `WKWebView`s at **560 × 1000 pt** (a portrait lane inside §8's 420–900 pt band),
laid out left-to-right in a 56 000 pt-wide container inside an `NSScrollView` — so a
couple of lanes are on-screen and the rest are parented-but-clipped, which is the real
app's shape. Then, in order:

1. grow to 25 parented → wait for every load → settle 12 s → snapshot
2. grow to 50 → settle → snapshot
3. grow to 100 → settle → snapshot
4. `removeFromSuperview()` on 95, objects retained → settle 20 s → snapshot
5. idle CPU, 12 × 5 s windows, **animations paused** ("quiescent")
6. idle CPU, 12 × 5 s windows, **animations running**
7. rendering-suspension test (§7)
8. 25 re-parent trials (§6)
9. eviction test: release 95 `WKWebView`s → wait 30 s → snapshot
10. write `report-<mode>.json`

### How each number is obtained

- **Memory** — `proc_pid_rusage(RUSAGE_INFO_CURRENT)` from inside the app, for the app
  process and for **every** WebKit helper found by walking `proc_listpids` +
  `proc_pidpath` and matching `com.apple.WebKit.{WebContent,Networking,GPU}`.
  A baseline set of WebKit pids already alive before launch (there were **12** —
  other apps on the machine use WebKit) is captured at startup and excluded, so the
  totals are only what this app caused.
  Both `ri_phys_footprint` (what Activity Monitor calls "Memory") and `ri_resident_size`
  (classic RSS) are recorded. **Units: every "MB" in this document is a MiB** —
  the code divides bytes by 1 048 576 — and "GB" in the extrapolation table is GiB. **`phys_footprint` is the number to reason with**: summing
  RSS across 100 processes double-counts the shared, clean WebKit framework pages in
  every one of them, which is why the RSS column below is roughly 1.8× the footprint column.
- **Cross-check** — `sample_external.sh` runs concurrently and writes `ps -o rss=` for
  the same processes every 10 s to `ps-samples.csv`, from outside the app. `footprint -p`
  was also run against the app process mid-run.
- **CPU** — cumulative `ri_user_time + ri_system_time` (ns) summed over app + helpers,
  differenced across each 5 s window and divided by the window's wall time. That yields
  **% of one core**, not % of the 12-core machine.
- **Re-parent latency** — four separate timestamps per trial, described in §6.
- **Suspension** — a `WKUserScript` injected at `documentStart` into an **isolated
  `WKContentWorld`** (so page CSP cannot block it and it cannot collide with page
  globals). It is **dormant** until native calls `__m1.start()` — otherwise all 100 views
  would be running a `requestAnimationFrame` loop and the idle-CPU number would be
  meaningless. It counts rAF callbacks and `setInterval(…,100)` ticks.

---

## 5. Results — memory and process count

Three complete runs: two independent `fixtures` runs (100 views each, 100/100 loads OK in
both) and one `real` network run (§5.7). `phys_footprint` is the column to reason with;
RSS is shown because the brief asked for it, and because the gap between them is itself a
finding (see §4 and §5.7).

### 5.1 Run 1 — `out/fixtures-20260912-061407/`

| stage | WebContent procs | app MB | WebContent MB | Networking MB | GPU MB | **total footprint MB** | total RSS MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| 25 views, all parented | **25** | 30 | 639 | 35 | 26 | **729** | 1 558 |
| 50 views, all parented | **50** | 39 | 1 298 | 71 | 29 | **1 437** | 2 881 |
| 100 views, all parented | **100** | 62 | 2 606 | 91 | 40 | **2 799** | 4 993 |
| **100 views, 5 parented / 95 unparented** | **100** | 55 | 2 283 | 88 | 41 | **2 467** | 4 636 |

### 5.2 Run 2 — `out/fixtures-20260912-061920/` (adds the eviction step)

| stage | WebContent procs | app MB | WebContent MB | Networking MB | GPU MB | **total footprint MB** | total RSS MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| 25 views, all parented | **25** | 29 | 607 | 13 | 24 | **672** | 1 724 |
| 50 views, all parented | **50** | 38 | 1 209 | 15 | 25 | **1 288** | 3 257 |
| 100 views, all parented | **100** | 57 | 2 640 | 23 | 42 | **2 762** | 4 806 |
| **100 views, 5 parented / 95 unparented** | **100** | 57 | 2 307 | 21 | 42 | **2 428** | 4 897 |
| after 25 re-parent trials | 100 | 56 | 2 331 | 19 | 155 | 2 561 | 4 408 |
| **after evicting 95 (WKWebView released)** | **5** | 50 | 131 | 10 | 22 | **213** | **409** |

Run-to-run agreement at the headline configuration: 2 799 vs 2 762 MB at 100 parented
(1.3 %), 2 467 vs 2 428 MB at 5/95 (1.6 %).

### 5.3 The headline finding: WebKit spawned one WebContent process per WKWebView

**100 `WKWebView`s → exactly 100 `com.apple.WebKit.WebContent` processes.** 25 → 25,
50 → 50, 100 → 100, in both fixture runs — and **25 → 25, 50 → 51, 100 → 101** on the
real network, where process-swap-on-navigation adds processes rather than sharing them.
There was **no** process-per-site coalescing anywhere, even though:

- all 100 views shared **one** `WKProcessPool`;
- the 100 URLs sat on only **20 distinct origins** (`127.0.0.1:8801–8820`), which share
  a single host — so "process per site" would have predicted ~1–20 processes;
- only **3** `WKWebsiteDataStore`s were in play.

Plus one API fact the compiler told us, which the PRD should absorb:

```
warning: 'WKProcessPool' was deprecated in macOS 12.0:
         Creating and using multiple instances of WKProcessPool no longer has any effect.
warning: 'processPool' was deprecated in macOS 12.0: …
```

**§9's "one `WKProcessPool` for the whole app (WebKit does process-per-site under it)"
is wrong on both halves on macOS 26.** The process pool is a no-op — WebKit has had a
single shared pool since macOS 12 — and the allocation unit is the `WKWebView`, not the
site. There is nothing to configure here; the right mental model is
**one web pane = at least one OS process**.

Per-WebContent-process footprint across the 100 processes at the end of run 1:

| min | p25 | median | p95 | max | mean |
|---:|---:|---:|---:|---:|---:|
| 17.0 MB | 18.8 MB | 23.9 MB | 27.9 MB | 32.2 MB | **23.3 MB** |

### 5.4 Marginal cost per additional web pane

| run | from → to | Δ views | Δ footprint | **MB per added pane** |
|---|---|---:|---:|---:|
| 1 | 25 → 50 | 25 | 708 MB | **28.3** |
| 1 | 50 → 100 | 50 | 1 362 MB | **27.2** |
| 2 | 25 → 50 | 25 | 616 MB | **24.6** |
| 2 | 50 → 100 | 50 | 1 475 MB | **29.5** |

Scaling is linear, not sub-linear: **≈27 MB of `phys_footprint` per parented web pane**
for this page mix, with no shared-process discount to be had. Fixed overhead (app +
Networking + GPU) is only 90–130 MB.

### 5.5 Memory decays after suspension — a lot, and slowly

The external `ps` sampler shows total RSS for the unchanged 100-view set falling for
~3.5 minutes after the load burst (run 1, baseline WebKit pids excluded):

| t+s | WebContent n | WebContent RSS | total RSS |
|---:|---:|---:|---:|
| 31 (100 loaded) | 100 | 4 942 MB | **5 275 MB** |
| 61 (95 just unparented) | 100 | 4 388 MB | 4 636 MB |
| 112 | 100 | 4 231 MB | 4 469 MB |
| 152 | 100 | 2 626 MB | 2 788 MB |
| 213 | 100 | 2 132 MB | **2 274 MB** |
| 253 (re-parent trials running) | 100 | 2 401 MB | 2 568 MB |
| 273 | 100 | 2 663 MB | 2 843 MB |

RSS at rest is **57 % lower** than RSS at peak-load for the identical set of pages, and
it climbs back as panes are re-parented. Any threshold in §10.3 that reads a single
instantaneous memory value will oscillate.

### 5.6 Unparenting vs. evicting

| run | operation | footprint before → after | WebContent procs | **saving per pane** |
|---|---|---|---:|---:|
| fixtures | `removeFromSuperview()` × 95 (object retained) | 2 762 → 2 428 MB | 100 → **100** | **3.5 MB** |
| fixtures | release the `WKWebView` × 95 (§10.3 "evict") | 2 561 → **213 MB** | 100 → **5** | **24.7 MB** |
| real | `removeFromSuperview()` × 95 (object retained) | 9 484 → 9 132 MB | 101 → **101** | **3.7 MB** |
| real | release the `WKWebView` × 95 (§10.3 "evict") | 9 215 → **592 MB** | 101 → **6** | **90.8 MB** |

The unparent saving is **~3.5 MB whatever the page weighs** — it is the view's own
backing store, not the page. The eviction saving tracks page weight exactly.

Unparenting keeps the process. Only releasing the `WKWebView` kills it, and WebKit reaps
the content processes immediately — the external `ps` sampler saw 103 → 8 WebContent
processes and 4 485 → 494 MB RSS inside one 10 s window.

### 5.7 Run 3 — `real`, 100 URLs over the network

Same program, same 560×1000 pt lanes, same 3 persistent data stores; the 100 URLs are
96 real pages across ~60 registrable domains plus the 4 local `anim` instrument pages.
This is the run that calibrates the fixtures against Scott's actual working set.

| stage | WebContent procs | **total footprint MB** | total RSS MB | MB per pane (footprint) |
|---|---:|---:|---:|---:|
| 25 views, all parented | **25** | **1 659** | 3 962 | 66.4 |
| 50 views, all parented | **51** | **5 355** | 3 173 | 105.0 |
| 100 views, all parented | **101** | **9 484** | 6 568 | **94.8** |
| 100 views, 5 parented / 95 unparented | **101** | **9 132** | 6 672 | 91.3 |

Three things here matter more than the fixture numbers:

1. **Real pages cost ~3.4× what the fixtures cost** — ≈95 MB per pane versus ≈27 MB.
   The fixtures were built to be heavy and they are still nowhere near a real
   documentation site with its analytics, fonts, and framework payload. **Size §10.3
   from this column, not from §5.1.**
2. **`phys_footprint` exceeded RSS** (9 484 vs 6 568 MB) — the reverse of the fixture
   runs. `phys_footprint` counts compressed pages and RSS does not, so this is macOS's
   memory compressor working hard: at 100 real panes the machine was already paying to
   keep the set resident. `memory_pressure` reported **34 % free** at the 50-pane mark
   with the rest of Scott's apps also running.
3. **Process count exceeded view count** — 51 processes for 50 views, 101 for 100. Real
   navigations trigger WebKit's process-swap-on-navigation, so the budget must assume
   **≥ 1 process per pane, not exactly 1**.

**Per-process spread is enormous on real sites**, from the external `ps` sampler at the
106-`WebContent`-process peak (101 ours + a handful of baseline processes from other
apps; RSS, not footprint, because this comes from `ps`):

| min | p25 | median | p75 | p95 | max | mean |
|---:|---:|---:|---:|---:|---:|---:|
| 4.5 MB | 22.1 MB | **27.9 MB** | 45.5 MB | **156.8 MB** | **402.1 MB** | 46.2 MB |

The p95 is **5.6×** the median and the worst pane is **14×** the median. The equivalent
fixture distribution (`phys_footprint`, n=100, from run 1's report) is almost flat by
comparison — 17.0 / 23.9 / 32.2 MB for min / median / max. **Real browsing produces a
long tail, and §9.4 exploits it.**

Load reliability over the network: one URL never fired `didFinish` and each staged wait
hit its 180 s settle timeout with 1 outstanding load (a long-polling news page). The
per-URL outcome for every run is recorded in `report-real.json` under `load_state`.

### 5.8 EXTRAPOLATION to 130 web panes

**Every row in this table is arithmetic on the measured 100-pane points, not a
measurement.** The `real` column is the one to plan with.

| configuration | basis | fixtures | **real sites** |
|---|---|---:|---:|
| measured at 100 panes, all parented | measured | 2 762 MiB | **9 484 MiB** |
| measured at 100 panes, 5 parented / 95 unparented | measured | 2 428 MiB | **9 132 MiB** |
| marginal MiB per pane (50 → 100) | measured | 29.5 | **82.6** |
| **130 panes, all parented** | 100-pane value + 30 × marginal | ≈ 3 647 MiB = **3.56 GiB** | ≈ 11 962 MiB = **11.68 GiB** |
| **130 panes, 5 parented / 125 unparented** | ditto from the 5/95 measurement | ≈ 3 313 MiB = **3.24 GiB** | ≈ 11 610 MiB = **11.34 GiB** |
| as a share of this machine's 36 GiB | — | ~9–10 % | **~32 %** |
| as a share of §10.1's 32 GiB target | — | ~10–11 % | **~35–37 %** |

**§10.1's "150 lanes (≈130 web) on a 32 GB Mac before eviction engages" is achievable on
memory, but it costs about a third of the machine** — and that is before Chrome, a
toolchain, and Scott's other apps. Two honest options, and §10.3 has to pick one:

- **Accept it.** Budget ~36 % of RAM for web panes and let eviction be a rare
  backstop. Comfortable on 36–64 GB, tight on exactly 32 GB.
- **Lower the number.** Cap web panes at 25 % of RAM and a 32 GiB Mac supports
  **≈86 real web panes** before eviction engages — `(0.25 × 32 GiB − 0.6 GiB fixed
  overhead) ÷ 82.6 MiB per pane ≈ 92`, or 8 192 ÷ 94.8 ≈ 86 on the cumulative figure —
  not 130. That is the number §10.1 should state if a 32 GiB machine is a first-class
  target.

Corroborating signal that pressure arrives earlier than the arithmetic suggests: at the
50-real-pane mark `memory_pressure` already reported **34 % free**, and from 50 panes on
`phys_footprint` exceeded RSS (9 484 vs 6 568 MB at 100), meaning macOS was compressing
to keep the set resident.

---

## 6. Results — idle CPU

Sampled as cumulative `ri_user_time + ri_system_time` over the app **and all 100+
helpers**, differenced across 12 consecutive 5 s windows (60 s per measurement), then
divided by wall time. Reported as **% of one core**.

| run | condition | mean | max | min |
|---|---|---:|---:|---:|
| 1 | 5 parented / 95 unparented, page animations paused | **0.06 %** | 0.09 % | 0.04 % |
| 1 | same, 4 `anim` pages running rAF canvas + CSS keyframes | **0.05 %** | 0.07 % | 0.04 % |
| 2 | 5 parented / 95 unparented, page animations paused | **0.07 %** | 0.08 % | 0.06 % |
| 2 | same, 4 `anim` pages running | **0.05 %** | 0.07 % | 0.04 % |
| 3 (**real sites**) | 5 parented / 95 unparented, page animations paused | **0.13 %** | 0.26 % | 0.09 % |
| 3 (**real sites**) | same, 4 `anim` pages running | **0.18 %** | **0.54 %** | 0.08 % |

Against the §10.1 bar of **< 2 % of one core**: fixtures idle at **0.05–0.07 %** (~30×
under budget) and 100 real sites at **0.13–0.18 %** (~11× under). The worst single 5 s
window across all six measurements was **0.54 %**, still 3.7× under the bar.

Real pages cost ~2.5× the idle CPU of the fixtures, which is what you would expect from
their background timers and reconnect logic — see §8's finding that JS keeps running,
throttled, while rendering is suspended. The trend is the useful part: heavier, more
script-laden pages raise the floor, but 100 of them together still do not approach 2 %.

**Caveat that matters:** the screen was locked for every run (§8), so all 100 views —
including the 5 parented ones — were in WebKit's suspended state. This number is
therefore a *floor*: it is the true cost of 100 suspended panes, but it does not include
the cost of the handful of panes that are genuinely visible in real use. Those are the
same 1–5 views any browser window would be painting, so the risk of blowing a 2 % budget
is low, but the number above is not the complete answer.

---

## 7. Results — re-parent latency

Four timestamps are taken per trial, and it matters which one you read. The trial
unparents whichever view occupies the hot slot and parents a previously-unparented view
into it, 25 times, cycling through the 95.

| timestamp | what it actually measures |
|---|---|
| `addsubview_return_ms` | `CACurrentMediaTime()` either side of `removeFromSuperview()` + `addSubview()` + frame set. **Main-thread work only.** |
| `catransaction_commit_ms` | `CATransaction.setCompletionBlock` on the transaction wrapping the swap. Fires when that transaction has been **committed to the render server** — it is *not* "photons on glass", and it does not mean the web content has painted. |
| `displaylink_ms` | first `CADisplayLink` callback (via `NSView.displayLink(target:selector:)`) after the swap. The **next display refresh opportunity**. |
| `first_web_frame_ms` | the honest one: the injected script calls `__m1.mark()` (recording `Date.now()` *inside the web process*) before the swap; the first rAF callback afterwards records `Date.now()` again. The delta is measured against the native wall clock at `addSubview`, so **no IPC sits inside the measured interval**. This is "how long until the web content produced a frame". |

### Measured, 25 trials each

| measure | run | min | **median** | **p95** | max |
|---|---|---:|---:|---:|---:|
| `addsubview_return_ms` | 1 | 0.9 | **1.8** | 3.1 | 4.1 |
| `addsubview_return_ms` | 2 | 0.9 | **1.9** | 3.6 | 4.0 |
| `catransaction_commit_ms` | 1 | 1.0 | **2.0** | 3.3 | 7.2 |
| `catransaction_commit_ms` | 2 | 1.0 | **2.0** | 3.9 | 4.4 |
| `displaylink_ms` | 1 | 1.7 | **5.4** | 14.5 | 19.7 |
| `displaylink_ms` | 2 | 1.3 | **6.3** | 21.7 | **399.9** |
| `addsubview_return_ms` | 3 (real) | 0.5 | **1.1** | 1.6 | 1.7 |
| `catransaction_commit_ms` | 3 (real) | 0.6 | **1.3** | 1.8 | 1.8 |
| `displaylink_ms` | 3 (real) | 1.0 | **8.3** | 15.1 | 15.4 |
| `first_web_frame_ms` | 1, 2, 3 | — | **not measured** | — | — |

Worth noting that the real-network run — the one carrying 101 WebContent processes and
9.5 GB — produced the *fastest* structural numbers of the three. Re-parenting is
`NSView` bookkeeping and does not scale with the number of live panes.

`displaylink_ms` median 5.4–6.3 ms is about one 120 Hz–ish frame interval plus jitter,
which is what it should be. The 399.9 ms outlier in run 2 is a single trial and is
reported rather than dropped; every other trial in that run was ≤ 21.7 ms.

`first_web_frame_ms` returned **n=0** in every run, because the screen was locked and
WebKit scheduled no frames at all (§8). That zero is trustworthy: the probe carries a
self-test that drives the rAF body synchronously and asserts the timestamp lands, and it
passed in run 3 —

```
M1 [437.22s]   first-frame probe self-test: {"ok":true,"delta_ms":0}
```

— so `n=0` means **"WebKit painted nothing"**, not "the probe is broken". The end-to-end
path has still not been exercised against a real WebKit frame, which is why §7 cannot
close the "visually under 100 ms" question.

---

## 8. Does unparenting actually suspend rendering? — **NOT PROVEN, and here is exactly why**

This was the load-bearing assumption in §10.2 ("WebKit suspends rendering for unparented
views") and the spike was built to settle it. It did not, for an environmental reason
that invalidates the experiment rather than the design.

### What was measured

| phase | view | role | rAF frames in window | window | rAF fps | `setInterval(…,100)` ticks | `document.visibilityState` |
|---|---:|---|---:|---:|---:|---:|---|
| 95 unparented | 1 | **control — parented, in a visible window** | **0** | 15.8 s | 0.00 | 4 | `hidden` |
| 95 unparented | 5 | subject — unparented | **0** | 15.8 s | 0.00 | 2 | `hidden` |
| 95 unparented | 50 | subject — unparented | **0** | 15.8 s | 0.00 | 2 | `hidden` |
| after swap | 1 | was parented → **now unparented** | **0** | 15.8 s | 0.00 | 5 | `hidden` |
| after swap | 5 | was unparented → **now parented + visible** | **0** | 15.8 s | 0.00 | 5 | `hidden` |

Replicated identically in the real-network run (run 3):

| phase | view | role | rAF frames | window | `setInterval` ticks | `visibilityState` |
|---|---:|---|---:|---:|---:|---|
| 95 unparented | 1 | **control — parented, visible** | **0** | 15.7 s | 5 | `hidden` |
| 95 unparented | 5 | subject — unparented | **0** | 15.7 s | 2 | `hidden` |
| 95 unparented | 50 | subject — unparented | **0** | 15.7 s | 2 | `hidden` |
| after swap | 1 | parented → **unparented** | **0** | 15.8 s | 2 | `hidden` |
| after swap | 5 | unparented → **parented + visible** | **0** | 15.8 s | 4 | `hidden` |

### Why this proves nothing about unparenting

**The control is identical to the subject.** A parented view in an on-screen window
rendered exactly as many frames as an unparented one: zero. When the control and the
treatment give the same answer, the experiment has not isolated the variable.

The cause was found and is unambiguous. Throughout every run:

```
CGDisplayIsAsleep(CGMainDisplayID())  -> (woken to false by `caffeinate -u`)
CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"] -> 1
window.isVisible = true   occlusionState = OCCLUDED   NSApp.isActive = false
```

**Scott's screen was locked for the entire session.** With a locked screen macOS marks
every window `NSWindowOcclusionState` non-visible, and WebKit suspends rendering
*app-wide* — which is why `document.visibilityState` is `hidden` even for the view sitting
at x=0 in a floating, ordered-front window. A minimal probe was written to rule out
alternatives: the window was raised to `.floating` and then to `CGShieldingWindowLevel()`,
given `.canJoinAllSpaces`, `orderFrontRegardless()` and `NSApp.activate(ignoringOtherApps:)`,
and launched both directly and through LaunchServices (`open -n -a`). Occlusion never
cleared. `caffeinate -u` woke the display (`CGDisplayIsAsleep` → false) but the lock
remained, and unlocking requires Scott's password, which is not something to route around.

The zeros are not an instrumentation failure. The injected script self-tests its own
mark→first-frame path by driving the rAF body synchronously, and that passed in run 3
(`{"ok":true,"delta_ms":0}`); the `setInterval` counters advanced in every view, proving
`evaluateJavaScript`, the isolated content world and the counters all worked. WebKit
simply scheduled no animation frames, anywhere, for anyone.

The spike therefore **refuses to pretend**: the app now carries a `--require-unlocked`
gate that exits `EX_TEMPFAIL` (75) rather than emit a number it cannot stand behind
(verified: it aborts with `M1 ABORT: display_asleep=false screen_locked=true`), and
`run_when_unlocked.sh` blocks until the session is usable.

### What the data *does* establish

1. **View-hierarchy membership is not sufficient for rendering.** A `WKWebView` can be
   fully parented in an `isVisible` window and still paint nothing, because something
   else — here, the locked screen marking the window occluded — suspended it first.
   That is weaker than "occlusion is the trigger", which this data cannot support: only
   one suspension cause was present and it was global. But it is enough to raise a
   question §10.2 assumes away — **whether a lane that is parented but scrolled
   out of view is already suspended before `RELEASE_DISTANCE` fires.** The unlocked
   re-run should test that third case explicitly (parented, on-screen window, scrolled
   outside the visible rect), because if the answer is yes, `RELEASE_DISTANCE` is doing
   less than the PRD thinks.
2. **JavaScript keeps running while rendering is suspended, heavily throttled.**
   `setInterval(…, 100)` should fire ~158 times in 15.8 s. Across both the fixture and
   the real-network runs it fired **2–5 times** — roughly **0.13–0.32 Hz, a 300–800×
   throttle** — but it never stopped, in any view, in any run. So a
   suspended pane is not frozen: timers, and therefore `fetch` polling, reconnecting
   WebSockets and SPA housekeeping, continue at a trickle. Do not assume an unparented
   pane is inert.
3. **It costs almost nothing.** 100 suspended panes idle at 0.05–0.07 % of one core on
   fixtures and 0.13–0.18 % on real sites (§6) — the number that matters for §10.1's
   budget whatever the mechanism turns out to be.
4. **Suspension does not release much memory on its own.** The suspended-and-unparented
   95 still held ~91 MB each on real sites (§5.7); only destroying the `WKWebView`
   reclaimed it (§5.6). Whatever "suspends rendering" means here, it is not "frees the
   page".

### To close this out

```sh
cd spikes/m1-webkit-memory && ./run_when_unlocked.sh fixtures 3600
```

Run it while sitting at the unlocked machine. The assertions to look for in the output:
the control (view 1, parented + visible) should show **~60 fps**, the unparented subjects
**~0 fps**, and the swap should flip both. `first_web_frame_ms` should then produce 25
real samples, which is the number that decides whether re-parenting is *visually* under
100 ms rather than merely *structurally* under 100 ms.

---

## 9. What this means for §10.3

Every recommendation below is tied to a measured number above.

### 9.1 Fix §9 first — the model in the PRD is wrong

- Delete "one `WKProcessPool` for the whole app (WebKit does process-per-site under it)".
  `WKProcessPool` has been a **no-op since macOS 12** (compiler-confirmed deprecation),
  and the measured allocation unit is one `WebContent` process **per `WKWebView`**, not
  per site (§5.3). Keep creating a pool if you like the symmetry; it changes nothing.
- Worse than 1:1 in practice: the real-network run produced **51 processes for 50 views
  and 101 for 100** — process-swap-on-navigation means the correct invariant is
  **≥ 1 OS process per web pane**, never fewer.
- The number to design against: **≈27 MB per pane for light pages, ≈95 MB per pane for
  real sites** (`phys_footprint`, app + all helpers, §5.1/§5.7).

### 9.2 `WKWebsiteDataStore` count: keep 3

Nothing measured argues for changing it. Data-store count did **not** influence process
count, process memory, or idle CPU — 3 stores produced 100 processes exactly as 1 or 100
would have. So pick the number on the product requirement §9 already states (a project's
panes share cookies/logins), not on resource grounds.

**Recommendation: keep `default 3`, persistent, `WKWebsiteDataStore(forIdentifier:)`.**
Two caveats worth an ADR: `forIdentifier:` stores are macOS 14+, and they are **on-disk
state that nothing in this spike garbage-collects** — `laned-core` needs to own
store-identifier lifecycle, or the app will accumulate orphaned website-data directories.

### 9.3 Eviction is the lever; unparenting is not

Measured, per pane (§5.6):

| operation | fixtures | real sites | process killed? |
|---|---:|---:|---|
| `removeFromSuperview()` (object retained) | **3.5 MB** | **3.7 MB** | no |
| release the `WKWebView` (§10.3 "evict") | **24.7 MB** | **90.8 MB** | yes — 101 → 6 processes inside one 10 s `ps` sample |

The unparent saving is ~3.5 MB **regardless of how heavy the page is** — it is the view's
own backing store, not the page. On real sites that is **4 %** of what eviction buys.

**§10.2 should stop being described as a memory strategy.** Keep `RELEASE_DISTANCE = 6`
for what it actually does — CPU and render-tree cost — and note §8's finding that a lane
scrolled off-screen may already be suspended by window occlusion before
`RELEASE_DISTANCE` ever fires.

### 9.4 Concrete eviction thresholds

Budget as a fraction of physical RAM, not as a pane count, because per-pane cost varies
**3.4×** between a docs page and a real site (27 vs 95 MiB measured). Let `W` = summed
`phys_footprint` of the app + all WebKit helpers, sampled the way `ProcMetrics.swift`
does it, and `R` = `hw.memsize`.

| knob | recommended value | grounded in |
|---|---|---|
| `EVICT_SOFT` | `W > 0.25 × R` — 9.0 GiB on 36 GiB, **8.0 GiB on 32 GiB** | 100 real panes measured at 9.26 GiB; the soft limit should bite right about there (§5.7) |
| `EVICT_HARD` | `W > 0.35 × R` — 12.6 GiB on 36 GiB, 11.2 GiB on 32 GiB | 130 real panes extrapolates to 11.68 GiB (§5.8); the hard limit must sit above the design target or it fires constantly |
| target after evicting | evict down to `0.20 × R` | gives the 120 s hysteresis window something to hold |
| hysteresis | no re-evaluation for **120 s** after an eviction; require the condition to hold for **3 consecutive 10 s samples** | §5.5 — identical page set measured 5 275 MB then 2 274 MB, a 57 % swing with no user action |
| `RELEASE_DISTANCE` | keep **6** | 3.5 MB/pane, page-weight independent; harmless, and §8 suggests the OS may do it anyway |
| `REHYDRATE_DISTANCE` | keep **2** | re-parenting costs ~1–2 ms of main-thread work (§7); rehydrating an *evicted* pane is a full page load, so keep the band tight and prefetch on intent |
| never evicted | pinned + pty, as written | unchanged |
| eviction order | `distance_from_viewport` desc, then `last_focus_at` asc, then **`phys_footprint` desc** | on real sites the per-process distribution runs 4.5 / 27.9 / 156.8 / 402.1 MB at min / median / p95 / max (§5.7). Evicting the p95 pane instead of the median one frees **5.6× more memory for the same user-visible loss** |

**Largest-footprint as a tiebreaker is the one genuinely new input this spike justifies.**
`laned-core` is already specified to read WebKit process memory, so the input is free;
§5.7's distribution shows the spread is wide enough that ignoring it wastes most of the
policy's power. A corollary: an eviction policy that counts *panes* rather than *bytes*
is measuring the wrong thing, since one pane can be 90× another.

### 9.5 The number that should actually worry Phase 1

Not memory — **process count**. 130 web panes means **≥130 `WebContent` processes** plus
Networking and GPU helpers, for one app. That is a lot of `launchd` jobs, file descriptors
and mach ports, and **nothing here found the ceiling**: the spike stopped at 100 because
that is what M1 asked for.

**Recommended follow-up spike (M1b):** walk 130 → 200 → 250 panes and find where macOS or
WebKit pushes back. §10.3's thresholds are worthless if the failure mode turns out to be
"WebKit declines to spawn process 137" rather than "memory got tight".

---

## 10. Threats to validity

Ordered by how much they should worry you.

1. **The screen was locked for every run, so half of M1 is unanswered.**
   This is the big one and it is stated again here so it is not lost: the
   *does-unparenting-suspend-rendering* question, the *first-web-frame* latency, and the
   *idle CPU of a genuinely visible pane* are **not measured**. What is measured is a
   lower bound. Re-run `./run_when_unlocked.sh fixtures` at the keyboard before Phase 1
   commits to `RELEASE_DISTANCE`.
2. **Memory was measured in the suspended state.** Because everything was occluded, even
   the 5 "parented" views had no visible backing store. The real 5-parented figure will
   be higher than 2 467 MB by whatever 5 visible 560×1000 pt panes cost in tiles — small
   relative to the total, but unquantified here. It also means the *unparent saving*
   (332 MB / 3.5 MB per view) is an **underestimate**: with a live screen the parented
   views would have had backing stores to drop.
3. **Memory is strongly time-dependent and the headline numbers are one point on a
   curve.** The external `ps` trace shows total RSS going 5 275 → 4 474 → 2 788 → 2 274 MB
   over ~3.5 minutes with the page set unchanged. Quote a number only with the settle
   time attached. §10.3's eviction policy must therefore hysteresis its thresholds or it
   will oscillate.
4. **Fixture pages are not real pages, and the gap is 3.4×.** The fixtures carry real
   framework weight and real DOM size but no third-party scripts, ads, analytics
   beacons, service workers, WebGL, video or long-lived WebSockets — and they measured
   27 MB/pane against 95 MB/pane for real sites. The `real` run closes most of that gap,
   but it is **one sample of each site on one afternoon**, over one network, with cold
   persistent caches, and it still contains no Grafana dashboard, no Slack, and no
   logged-in application — plausibly the heaviest things Scott would actually park in a
   lane.
4a. **The real run was not clean.** One URL failed outright and one never fired
   `didFinish`, so every staged wait hit its 180 s settle timeout with 1 load
   outstanding. 98 of 100 pages were fully loaded when the memory snapshots were taken;
   the other two were in an indeterminate state.
5. **n=2 for fixtures, n=1 for real.** The 25/50/100 staging ran twice on fixtures and
   once on the network. Fixture run-to-run agreement was good (2 799 vs 2 762 MB at 100
   views, 1.3 %), but there is **no replication at all of the 9.48 GB real-site number**,
   which is the number §9.4's thresholds are built on. Run `./run.sh real` at least twice
   more before treating it as settled.
6. **The machine was not quiet.** Chrome (~1 GB), VS Code, Vivaldi and other apps were
   running; load average at the start of run 1 was 11.6. CPU is measured as this app's
   own cumulative CPU time so contention does not inflate it, but it could *depress*
   throughput during the load phase and it means the memory headroom conclusions assume
   a machine that also has to run everything else.
7. **`first_web_frame_ms` has never returned a non-zero value on this machine.** The
   probe's mark→first-frame plumbing passes its self-test, but the end-to-end path has
   not been exercised against a real WebKit frame. Treat the first unlocked run as a
   validation of the probe as much as a measurement.
7a. **The 130-pane figures are linear extrapolation from a 100-pane measurement**, and
   the marginal cost was not itself linear on the network run (147.8 MB/pane from 25→50,
   82.6 MB/pane from 50→100). The §5.8 numbers could be off by tens of percent in either
   direction; nothing above 100 panes was measured.
8. **`--deep` codesigning and ad-hoc signature.** The app is ad-hoc signed with no
   entitlements and is not sandboxed. A sandboxed, hardened-runtime, notarised Max Pane
   may see different XPC behaviour and different data-store paths.
9. **No sleep/wake, no long soak.** M1 ran for ~5 minutes per configuration. Whether 100
   suspended WebContent processes survive a lid close, or leak over eight hours, is M5
   and is not touched here.
10. **The 3-data-store split was round-robin, not project-keyed.** §9 assigns stores by
    project root. Round-robin `i % 3` gives the same *number* of stores but a different
    *distribution* of cookies and caches. Since data stores turned out not to drive
    process count at all, this is unlikely to matter, but it is not the shipping policy.

---

## 11. Artifacts

| path | what |
|---|---|
| `spikes/m1-webkit-memory/out/fixtures-20260912-061407/` | run 1 — fixtures, 100 views, 100/100 loads OK |
| `spikes/m1-webkit-memory/out/fixtures-20260912-061920/` | run 2 — fixtures + eviction phase, 100/100 loads OK |
| `spikes/m1-webkit-memory/out/real-20260912-062453/` | run 3 — 100 real URLs, 98 OK / 1 failed / 1 never completed |

Each directory holds `report-<mode>.json` (every number in this document, machine
readable), `run.log`, `ps-samples.csv` (independent `ps` cross-check), `environment.txt`
and `build.log`. `summarize.py <report.json>` regenerates the tables above;
`analyze_ps.py <ps-samples.csv>` regenerates §5.5.

## 12. Open items this spike creates

1. **Re-run `./run_when_unlocked.sh fixtures` at an unlocked machine** and replace §8.
   Phase 1 should not commit to `RELEASE_DISTANCE` machinery until it does. Add a third
   arm to the suspension test while doing so: a view that is **parented but scrolled
   outside the window's visible rect**, which is the state `RELEASE_DISTANCE` actually
   competes with (§8).
2. **Rewrite PRD §9** — `WKProcessPool` is a no-op; the unit is one process per pane
   (§9.1).
3. **Rewrite PRD §10.2** — unparenting is a CPU/render optimisation worth 3.5 MB, not a
   memory strategy (§9.3).
4. **Settle PRD §10.1's pane count** — 130 real web panes costs ~36 % of a 32 GiB Mac.
   Either accept that, or restate the target as ≈86 panes on 32 GiB (§5.8).
5. **Add spike M1b: process-count ceiling**, 130 → 250 panes (§9.5).
6. **ADR for `WKWebsiteDataStore` identifier lifecycle** — nothing currently reaps them
   (§9.2).
