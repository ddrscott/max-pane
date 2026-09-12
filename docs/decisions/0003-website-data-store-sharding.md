# ADR 0003 — Three data stores, hashed by project; and PRD §9's process model is wrong

**Status:** Accepted · 2026-09-12
**Decides:** PRD §14 — "3 vs. N `WKWebsiteDataStore`s, and the assignment rule."
**Evidence:** [Spike M1](../spikes/01-m1-webkit-memory.md).

## Decision

**Keep three `WKWebsiteDataStore`s.** Persistent, created with
`WKWebsiteDataStore(forIdentifier:)` (macOS 14+), assigned to a project by
hashing its root with FNV-1a.

Separately, and more importantly: **PRD §9's model of how WebKit allocates
processes is wrong, and the app must not be built on it.**

## The data-store count

Nothing M1 measured argues for changing it. Data-store count did not influence
process count, process memory, or idle CPU — three stores produced exactly 100
processes for 100 views, which is what one store or a hundred would have
produced. So the number comes from the product requirement §9 already states
(a project's panes share cookies and logins), not from resource accounting.

Three is a good number for that requirement: enough that a logged-in session for
one project does not leak into another, few enough that a project's own panes
reliably land together.

**Assignment is FNV-1a over the project root, mod the store count.** Two
properties matter and only one is obvious:

- *Stable across launches.* Swift's `hashValue` is seeded per process, so using
  it would move projects between stores on every restart — and a project's store
  is where its logins live. FNV-1a gives the same answer forever.
- *Stable as projects are added.* Assigning in first-seen order would work until
  the ledger was rebuilt; hashing does not care what else exists.

The store's own identity has the same requirement one level down: WebKit keys
the on-disk cookie jar by the `UUID` passed to `forIdentifier:`, so that UUID is
derived deterministically from the shard name rather than generated and saved.
There is no extra file to lose.

## The part that matters more: §9's process model

PRD §9 opens with:

> One `WKProcessPool` for the whole app (WebKit does process-per-site under it).

**Both halves are untrue on macOS 26.** M1 measured:

- **100 `WKWebView`s produced exactly 100 `WebContent` processes.** 25 → 25,
  50 → 50, 100 → 100, across two runs. The 100 URLs sat on 20 distinct origins
  sharing one host, so process-per-site would have predicted 1–20. There was no
  coalescing of any kind.
- **The real-network run was worse than 1:1** — 51 processes for 50 views, 101
  for 100 — because WebKit swaps process on cross-origin navigation. The correct
  invariant is **at least one OS process per web pane, never fewer**.
- `WKProcessPool` is **a deprecated no-op**, and the compiler says so:
  *"Creating and using multiple instances of WKProcessPool no longer has any
  effect"* (deprecated in macOS 12). WebKit has had one shared pool for four
  years.

The app therefore does not set `processPool` at all, and the mental model is:
**one web pane is one OS process, costing ~27 MB for a documentation page and
~95 MB for a real site.**

### What this changes downstream

**§10.2 is not a memory strategy.** Unparenting a `WKWebView` reclaims 3.5 MB —
the view's own backing store — and that figure is the same whether the page is a
docs page or Slack. Destroying it reclaims 24.7 MB on light pages and 90.8 MB on
real ones, and ends the process. On a real site, unparenting buys **4%** of what
eviction buys. `RELEASE_DISTANCE = 6` stays, for the CPU and render-tree cost it
actually saves — but it must stop being described as the thing that keeps memory
down. Eviction is the only lever that moves memory.

**Budgets are fractions of RAM, not pane counts,** because per-pane cost varies
3.4× between page types. The policy now carries a soft mark (0.25 × RAM), a hard
mark (0.35 × RAM), and a target to evict down to (0.20 × RAM).

**The policy has hysteresis, because memory lies.** M1 watched the *same 100
panes* measure 5 275 MB and then 2 274 MB three and a half minutes later with
nobody touching anything — a 57% swing. A single threshold would have evicted
half the strip during a transient. The soft mark now requires three consecutive
over-budget samples and a 120-second cooldown; the hard mark bypasses both,
because at that point something is genuinely wrong.

## The tiebreaker we specified but cannot yet measure

M1 recommends breaking ties by largest footprint. Per-process footprint on real
sites runs 4.5 / 27.9 / 156.8 / 402.1 MB (min / median / p95 / max), so evicting
the p95 pane frees **5.6× what evicting the median one does**. Two panes the same
distance away are not the same size, and the spread is an order of magnitude.

`MemoryReport.pane_footprints` exists and the policy uses it. **The shell leaves
it empty**, because attributing a `WebContent` process to the pane that owns it
requires `_webProcessIdentifier`, which is private API. With the list empty the
policy falls back to distance then recency — exactly the ordering the PRD
specifies — so nothing is broken by leaving it unmeasured. It is wired so that
if a public API appears, or we decide the private one is worth it, it is one
call site.

## Rejected

- **One shared data store.** Simplest, and loses the property §9 asks for: a
  logged-in GitHub session for one project would be the same session for every
  project.
- **One store per project.** Unbounded on-disk state with no garbage collector,
  and M1 confirms it would buy nothing in memory or process terms.
- **Assignment in first-seen order.** Stable only until something renumbers, and
  renumbering costs the user their logins.

## What would make us revisit

- **The PRD's own target sits at the hard mark on a 32 GB Mac.** 130 real web
  panes extrapolates to **11.34 GiB — 36% of a 32 GiB machine**, which is above
  `EVICT_HARD` at 0.35. §10.1 asks for 150 lanes (~130 web) "before eviction
  engages"; on real sites and 32 GB, eviction will be engaged more or less
  permanently at that target. It still works — that is what eviction is for —
  but §10.1's phrasing promises something the measurements do not support, and
  the honest version is "150 lanes, with the far ones held as placeholders."
  On this 36 GiB machine there is more room, and on fixtures-weight pages
  (3.24 GiB at 130) there is plenty.
- **The process-count ceiling, which nobody has found.** 130 web panes means
  ≥130 `WebContent` processes plus helpers, for one app — a lot of launchd jobs,
  file descriptors and mach ports. M1 stopped at 100 because that is what it was
  asked for. **If WebKit declines to spawn process 137, every threshold in this
  ADR is irrelevant**, so spike M1b should walk 130 → 200 → 250 and find out.
- **M1 ran with the screen locked**, so macOS occluded the window and suspended
  everything. The memory numbers are a floor, the unparent saving is an
  underestimate, and "does unparenting suspend rendering" is still unproven. The
  spike ships with `run_when_unlocked.sh` to close that at the keyboard.
- A public API for a `WKWebView`'s process id.
