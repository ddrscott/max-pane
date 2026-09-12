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
| 5 | 150 lanes → idle CPU < 2%, RSS within target, scrolling smooth | spikes M1 + M4 | **pending** |
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
