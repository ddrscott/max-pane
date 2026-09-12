# Acceptance tests (PRD §15)

Where each of the eight acceptance tests is verified, and by what. A test that is
only ever checked by hand is written down here so it is at least checked
deliberately.

| # | Test | Verified by | Status |
|---|---|---|---|
| 1 | 20 lanes, reorder randomly, `kill -9` → order identical on relaunch | `crates/laned-core/tests/durability.rs::strip_order_survives_an_unclean_exit` — drops `Core` with no shutdown path and reopens the file | **automated** |
| 2 | `open https://example.com` in a pty pane in `~/src/foo` → web pane immediately right, tagged `foo` | ledger half: `durability.rs::a_url_from_a_terminal_lands_right_of_it_and_inherits_the_tag`; shim half: `crates/maxpane-open` tests + manual | **partial** |
| 3 | `cd ~/src/bar` → tag updates within 10 s; lane does not move | `durability.rs::retagging_never_moves_a_lane`; the ≤5 s bound comes from pty-host's flush cadence ([ADR-0005](decisions/0005-cwd-for-relay-sessions.md)) | **automated** |
| 4 | Sleep, wake → no web pane reloads; terminals reattached; scroll unchanged | spike M5 | **pending M5** |
| 5 | 150 lanes → idle CPU < 2%, RSS within target, scrolling smooth | spikes [M1](spikes/01-m1-webkit-memory.md) + [M4](spikes/04-m4-strip-scroll.md) | **measured** — idle CPU 0.015–0.18% of one core; 0.00% dropped frames at 150 lanes; RSS ~27 MB/pane on light pages and ~95 MB on real ones, which puts 130 real panes above the hard eviction mark on a 32 GB Mac (see [ADR-0003](decisions/0003-website-data-store-sharding.md)) |
| 6 | Evict a lane, ⌘P its URL → rehydrates, strip scrolls to it, border flashes | ledger half: `durability.rs::eviction_round_trips_through_the_ledger` + `search_covers_titles_urls_and_scrollback`; the scroll and flash are manual | **partial** |
| 7 | ⌘G shows only that project's lanes contiguous; Esc restores exactly | `durability.rs::gather_filters_without_writing_an_ordinal` — asserts the restored ordinals are byte-identical | **automated** |
| 8 | Quit with Relay host down → relaunch shows all lanes, pty panes "reconnecting", ordinals intact | ordinals: covered by test 1, which never involves Relay at all; the reconnecting state is manual | **partial** |

## Why some of these can only be partial

Tests 2, 6 and 8 each have a half that is a claim about *pixels* — "immediately
right", "border flashes", "shows reconnecting". The ledger half is where the
actual risk lives (wrong ordinal, lost URL, dropped scroll position) and that half
is automated. The visual half is checked by using the app, which is what Phase 1's
two-week exit criterion is for.

Test 5 is a measurement, not an assertion; it belongs to the spikes.

## Running the automated half

```sh
source scripts/env.sh
cargo test
```

## Where the PRD and reality disagree

Recorded here as well as in the ADRs, because §0.6 asks for conflicts to be
surfaced rather than quietly reinterpreted.

| PRD says | Measured | Where |
|---|---|---|
| §9: "one `WKProcessPool` for the whole app (WebKit does process-per-site under it)" | `WKProcessPool` is a deprecated no-op since macOS 12; 100 views across 20 origins gave 100 processes, and 101 for 100 on real sites | [ADR-0003](decisions/0003-website-data-store-sharding.md) |
| §10.2: unparenting is how memory stays down | Unparenting reclaims 3.5 MB; eviction reclaims 24.7–90.8 MB. Unparenting is a CPU strategy | [ADR-0003](decisions/0003-website-data-store-sharding.md) |
| §10.1: 150 lanes (~130 web) "before eviction engages" on a 32 GB Mac | 130 real web panes ≈ 11.34 GiB ≈ 36% of 32 GB — above the hard mark. Eviction will be engaged at that target | [ADR-0003](decisions/0003-website-data-store-sharding.md) |
| §7.3: poll foreground cwd with `proc_pidinfo` every 5 s | RelayTTY's pty-host already does exactly this, and does not strip OSC 7 from the stream. Observe instead of duplicating | [ADR-0005](decisions/0005-cwd-for-relay-sessions.md) |
| §11: "resize → propagate to Relay" | Measured: every size flip forces a full TUI redraw on every other attached client — 6 671 bytes for `htop` — and the last writer owns the PTY for everyone | [ADR-0007](decisions/0007-terminal-panes-never-resize-the-pty.md) |
| §12 M4: "scroll at 120 Hz" | Not verifiable on this machine — the panel is 60 Hz, and the built-in display reported 120 but delivered exactly 16.667 ms | [ADR-0004](decisions/0004-strip-view-strategy.md) |

None of these were reinterpreted silently. Each has an ADR saying what was built
instead and why.
