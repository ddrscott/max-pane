# Spike M3 — `laned-core` over uniffi

**Question (PRD §12):** `laned-core` via uniffi: `StripState` round-trip at 300 lanes / 400 panes.
**Pass criterion:** < 5 ms.
**Verdict: PASS** — 2.45 ms p95, 2× headroom. With a caveat that changes the FFI design (see *What this means*).

---

## Environment

| | |
|---|---|
| Machine | Apple M3 Pro, 36 GB |
| OS | macOS 26.6.2 (25G83) |
| Swift | swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101) |
| Rust | rustc 1.98.1 (48a229cea 2026-09-01) |
| uniffi | 0.32.1 (proc-macro mode, no UDL) |
| rusqlite | 0.37, `bundled` SQLite |
| Build | `swift build -c release`; Rust `--release`, thin LTO, 1 codegen unit |

There is no Xcode on this machine, only Command Line Tools. The bridge is a plain
SwiftPM package linking a Rust `staticlib`, not an XCFramework — `xcodebuild`
was never needed.

## How to re-run

```sh
./scripts/gen-bindings.sh                      # build laned-core + regenerate Swift bindings
cd spikes/m3-uniffi-ffi && swift build -c release && ./.build/release/m3

# the Rust-only half, for the split:
cd crates/laned-core
/opt/homebrew/opt/rustup/bin/cargo test --release --test snapshot_cost -- --nocapture
```

## Fixture

A real on-disk ledger (not `:memory:` — SQLite's page cache behaves differently),
built the way the app builds one: 300 lanes each created `RightOf` the previous,
which is also the worst case for the ordinal code, every insert splitting the same
end gap. 1 in 7 lanes is a pty; the rest are web panes with realistic URLs,
realistic titles, and a project tag. 100 extra panes stacked into lanes to reach
400. Every pty pane carries 200 lines of scrollback in the search index.

Building it took **1235 ms for 300 lanes — 4.1 ms per `create_lane`**, each one a
synchronously committed SQLite write. That is the cost of the PRD's "every layout
mutation is committed before the UI animates it", and it is the correct trade.

## Results

200 iterations each, after 3 warm-up calls. Milliseconds.

| Operation | mean | p50 | p95 | p99 | max |
|---|---|---|---|---|---|
| `state()` full round-trip | 2.423 | 2.419 | **2.445** | 2.480 | 2.627 |
| `state()` + Swift walks every field | 2.424 | 2.420 | 2.461 | 2.480 | 2.505 |
| `nudge_lane` (write + snapshot) | 2.770 | 2.747 | 2.901 | 2.950 | 2.995 |
| `focus_pane` (write + snapshot) | 2.493 | 2.473 | 2.580 | 2.720 | 2.794 |
| `gather` + `ungather` | 2.943 | 2.939 | 2.983 | 3.019 | 3.175 |
| `search` over titles + URLs + 8 600 scrollback lines | 0.559 | 0.561 | 0.577 | 0.597 | 0.614 |
| `plan_eviction` | 0.751 | 0.749 | 0.761 | 0.778 | 0.796 |
| `observe_cwd` (unchanged — the 5 s poller's common case) | 0.009 | 0.009 | 0.010 | 0.010 | 0.012 |

### Where the time goes

| Half | p95 | share |
|---|---|---|
| Rust: SQLite query + build `StripState` | 0.288 ms | 12% |
| uniffi: serialise → `RustBuffer` → allocate Swift structs and `String`s | ~2.16 ms | **88%** |

**The database is not the cost. The FFI boundary is.**

Two corroborating observations:

- Walking every field in Swift afterwards costs **nothing measurable** (2.461 vs
  2.445 ms p95). uniffi decodes eagerly at the boundary; there is no lazy
  path to exploit and no way to pay less by reading less.
- `observe_cwd`, which returns a `bool` instead of a snapshot, is **270× faster**
  than the calls that return one — 0.009 ms. The per-call FFI overhead is
  negligible; it is the 300 lanes × ~9 fields × string allocation that costs.

## Pass/fail

| Criterion | Result |
|---|---|
| `StripState` round-trip at 300 lanes / 400 panes < 5 ms | **PASS** — 2.445 ms p95 |

At the PRD's actual §10.1 target of 150 lanes the cost is roughly half again;
300 lanes was chosen as 2× headroom over the real target, and it still passes
with 2× headroom over the budget.

## What this means

### For §14's "uniffi vs cbindgen"

Keep uniffi. But the 88/12 split means the decision that matters is **not which
binding generator** — it is **how often a full snapshot crosses the boundary at
all**. cbindgen would move the same bytes; hand-writing the marshalling would buy
back at most ~2 ms per mutation in exchange for maintaining a hand-rolled ABI for
every record in §6, which is exactly the kind of cost that has no end.

The cheaper fix is architectural, and it is already affordable:

1. `StripState.revision` is a `u64` that increments on every mutation. The shell
   can hold the last snapshot and skip re-rendering when the revision is
   unchanged — a 2-byte comparison instead of a 2 ms marshal.
2. The hot paths do not need 300 lanes. `focus_pane` changes one lane's
   `last_focus_at` and one `app_state` row; `set_scroll_x` already returns
   nothing. Both should have snapshot-free variants, with the full snapshot
   reserved for structural change (create, close, move).
3. Budget-wise this is already fine: at 120 Hz the frame budget is 8.3 ms, and
   structural mutations are user-initiated — nobody creates lanes at 120 Hz. The
   work above is headroom for 300+ lanes, not a Phase 1 blocker.

**Recorded as [ADR-0002](../decisions/0002-uniffi-over-cbindgen.md).**

### For the ledger

`state()`'s Rust half at 0.288 ms means the two-query design (one for lanes, one
for all panes, joined in memory) is right and there is no reason to revisit it.
Do not add a per-lane pane query; at 300 lanes that would be 301 round-trips.

### For search (§7.5)

0.577 ms p95 across 300 lane titles, 400 URLs and 8 600 scrollback lines, with
scrollback held in memory rather than SQLite. ⌘P can search on every keystroke
with no debounce. The 200-lines-per-pane cap in the PRD is not yet load-bearing —
it is holding 4% of a 120 Hz frame — but it also costs nothing to keep.

## Threats to validity

- **Single-threaded, uncontended.** Every call took an uncontended
  `parking_lot::Mutex`. The real app will call `state()` from the main thread
  while the cwd poller and scrollback pushes run elsewhere. `observe_cwd` at
  0.009 ms makes lock convoy unlikely, but it is not proven here.
- **Warm page cache.** The 300-lane ledger is ~200 KB and stays entirely in
  SQLite's cache. A cold first `state()` after launch will be slower; the PRD's
  < 3 s relaunch budget has room for it, but the number is not measured.
- **Synthetic strings.** Titles and URLs are realistic in length but uniform.
  Marshalling cost is dominated by string count, not content, so this should not
  matter.
- **`create_lane` at 4.1 ms** is measured on this machine's SSD with
  `synchronous = NORMAL` under WAL. On slower storage, or with
  `synchronous = FULL`, it will be worse. It is not part of the M3 criterion,
  but it is the number to watch if creating a lane ever feels sticky.
