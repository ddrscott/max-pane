# History, round 2: the corpus, the redirects, and the clock

A fresh critic judged the first round against Scott's real Vivaldi profile and
the bar won. This is the list, ranked as the critic ranked it. Do not start
until the ⌘O work (piece 9 of the browser gauntlet) has merged — it owns
`Views/HistoryPalette.swift` and may have touched `history.rs`.

## The measurement that decides everything here

From `~/Library/Application Support/Vivaldi/Default/History` — his actual
browsing, not a guess:

| | Vivaldi (what he uses) | Max Pane (round 1) |
|---|---|---|
| URLs on record | **112,840** | 5,000 max (`HISTORY_MAX_ROWS`) |
| Visits on record | **462,785**, back to 2024-02-22 | ~30 days at his rate |
| Searchable | all of it | newest **2,000** (`HISTORY_SCAN_ROWS`) ≈ 14 days |
| Browsable without typing | every day, by calendar | newest **60** ≈ 15 hours |

His rate is 1,010 distinct URLs a week, 5,136 a month. The 90-day age cap never
fires — the row cap evicts him at ~29 days first.

## 1. No row cap at all, and search the whole table

**The owner has decided there is no limit**: "i don't think we need any limits
on history." That is the right call and the arithmetic supports it — a `visit`
row is one per normalised URL, roughly 250 bytes with a title, so his entire
112,840-URL history is about **28 MB** and ten years at his measured rate lands
near **155 MB**. SQLite does not care; Vivaldi spends 642 MB on the same data.

So `HISTORY_MAX_ROWS` goes, and the 90-day age cap with it unless there is a
reason to keep it that is about *him* rather than about the database.

**The cap was hiding a linear scan, and removing it makes the index
mandatory.** The 2 ms measured over 2,000 rows is a scan in Rust; at 112,000
rows the same code costs on the order of 100 ms per keystroke, which is worse
than the truncation ever was. An index or FTS over url and title is therefore
not an optimisation to consider afterwards — it is the thing that makes "no
limits" possible. Measure the keystroke cost at his real corpus size and put
the number in a comment.

## 1a. What the cap was hiding

**The single biggest gap.** A row at depth 2,499 is silently unfindable while
the palette's footer reads `0 OF 5013 PAGES` — proved with planted needles at
depths 500, 1,899, 2,499 and 4,499; the first two were found, the last two were
not, with the row sitting in the table the whole time.

The caps were bought with speed nobody was short of. Per section 1 they are
going entirely rather than being lowered — this section is here for the evidence
that the truncation was real and silent, not to propose a smaller number.

**The footer must describe the search's actual reach**, not the table's size. A label that is wrong about the thing it labels
is worse than no label.

## 2. Substring beats subsequence on a corpus this size

`history::rank` uses `fuzzy_score` (subsequence) plus a flat `TITLE_BIAS = 200`,
so any title subsequence outranks any URL match. `hop` returned 60 rows headed
by "Checker notes 4805" and "Launchd notes 4520" — scattered h, o, p — while the
row whose URL contains `hop` was not visible at all. `http://git` returned
GitHub *and* SQLite — Wikipedia.

Vivaldi's history search is substring. Subsequence is right for ten sessions and
wrong for thousands of rows. (Piece 9 may already have changed this for the
mixed corpus — check what it did before redoing it.)

## 3. Client-side redirects leave junk rows and lose the destination

Server redirects work: 301 and 302 both record an alias correctly and survive a
restart. The hole is everything else:

| typed | kind | recorded |
|---|---|---|
| `http://…/js` | `location.replace` | own row titled "bouncing", no alias |
| `http://…/meta` | `<meta refresh>` | own row, **no title at all**, no alias |
| `https://youtu.be/dQw4w9WgXcQ` | 303 + `replaceState` | **three** rows, none of them `youtu.be` |

`WebPaneController.didFinish` reads the alias from
`backForwardList.currentItem?.initialURL`, which a client-side redirect or a
`replaceState` has already overwritten. A two-hop server chain also loses its
middle URL. Vivaldi records the chain as CLIENT_REDIRECT and hides the
intermediates; here the interstitial *is* the entry.

## 4. Time is only ever relative

Every row says "22d ago". No dates, no clock time, no day grouping. Vivaldi's
History gives a Date column with clock time, day headers with per-day counts, a
Views count, sortable columns and List/Day/Week/Month views. "What did I have
open Tuesday afternoon" is answerable there and unanswerable here.

## 5. You can browse exactly 60 rows

Empty query, 75 presses of ↓, and the list ends at row 60 while the footer says
5,014. No paging, no "show more". Below 60 you must guess a search term — and
the search reaches 2,000.

## 6. Truncation eats the identity, and delete is unconfirmed

Two CloudWatch URLs differing only in a trailing `stream-a`/`stream-b`, same
title, same age, both truncated at `…log-group/aws$252Flam…`. No tooltip, no
copy-address, no full-URL reveal. ⌘⌫ then deleted one instantly with no
confirmation, no undo, and no way to tell which. This owner lives in AWS
console, GitHub diff and Grafana URLs, where the tail is the identity.

## 7. There is no way to clear history

`Core::clear_history` and `StripStore.clearHistory()` exist and are exercised
only by a test — no `Command` case, no key, no menu. One row at a time with ⌘⌫
is the entire delete story. Vivaldi has multi-select delete, delete-by-domain,
and Clear Browsing Data with time ranges.

## 8. Smaller, still real

- **Restoring the strip re-records every open lane as a visit.** After four
  relaunches an untouched Wikipedia lane read `×4` and led "recently visited";
  `visit_count` is partly a count of app restarts. Chrome does not count tab
  restores.
- **⏎ always opens a new lane.** No ⌘⏎ variant, no "open in the focused pane",
  no copy-address. On a 15-lane strip every recall widens the strip.
- **No favicons.** Every row gets the same orange dot; Vivaldi's history is
  scannable partly because eight "Google Account" rows look different from the
  YouTube ones.
- **The palette dies on deactivate.** ⌘-Tab away and back and the query is gone.

## What is already good — the fix is targeted, not a rewrite

Server-redirect aliases work and survive a restart, and `visit_alias` is the
right shape. Title-and-URL search with match highlighting on both lines is
better than Vivaldi, which highlights nothing. `normalize_url` is correctly
shallow — query strings and fragments survive.
