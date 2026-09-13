# Import history from another browser

## Problem

> "we should be able to import setting from other browsers with a simple wizard.
> merge or replace current settings (bookmarks, history, passwords, etc...)"

Scoped by the owner to **history only for now**, because it is the one store that
exists. Bookmarks and passwords are queued as features in their own right; their
import follows once there is somewhere to put them.

## Hard dependency

**This is blocked on history round 2.** Today the ledger keeps 5,000 rows and
prunes every 64th visit. His Vivaldi profile holds **112,840 URLs and 462,785
visits going back to 2024-02-22** — an import would be deleted almost entirely
before the wizard finished. Raising the cap is round 2's first item; do that
first or this is theatre.

## Where the data is

Each is SQLite, each is **locked while the browser is running**, and copying one
carelessly loses whatever sits in its WAL — the lesson from this repo's own
ledger, where 4.1 MB was uncheckpointed at the moment it mattered. Copy with
`sqlite3 .backup`, or copy `-wal` and `-shm` alongside, then open read-only.

| Browser | File | Tables | Epoch |
|---|---|---|---|
| Vivaldi / Chrome / Brave / Edge | `~/Library/Application Support/<Browser>/Default/History` | `urls`, `visits` | µs since **1601-01-01** |
| Safari | `~/Library/Safari/History.db` | `history_items`, `history_visits` | s since **2001-01-01** |
| Firefox | `~/Library/Application Support/Firefox/Profiles/*/places.sqlite` | `moz_places`, `moz_historyvisits` | µs since **1970-01-01** |

Three different epochs, and getting one wrong yields history dated 1601 or 2040
rather than an error. Test each against a known URL with a known visit time.

**Safari's `History.db` is behind TCC.** Reading it needs Full Disk Access, and
without it the open fails with a permission error that looks like a corrupt file.
Detect that case and say what it is, rather than reporting a broken database.

## The design problem worth getting right

`visit` is ordered by **`seq`, a monotonic counter, not by a clock** — migration
0003 explains why, and history round 2 inherits it. An import must not simply
append: 112,840 rows taking the highest `seq` values would make every imported
page outrank everything he actually did today, and the MRU list that ⌘O opens
with becomes a list of pages from 2024.

So the import has to interleave by the source's real timestamps, or `seq` has to
stop being the only ordering key. Decide which, and say why in a comment. This
is the single decision that makes the feature useful or useless.

## Acceptance criteria

- A wizard offers the browsers actually installed on this machine, not a fixed
  list — detect by looking for the files.
- **Merge** and **replace** both work, and the difference is explained in the
  wizard rather than assumed:
  - *merge* dedupes on the same normalised URL our own `normalize_url` produces,
    keeps the **earliest** first-visit and the **latest** last-visit, and sums or
    takes the max of visit counts — pick one and say which.
  - *replace* takes a `sqlite3 .backup` of the existing ledger first and names
    the file it wrote, so a wrong choice is recoverable.
- Imported pages appear in ⌘O and ⌘Y search, ranked sensibly against pages
  visited in Max Pane itself — not all above them, not all below.
- The MRU that ⌘O opens with still shows what he did recently, not 2024.
- A dry run reports what it would do — counts, date range, duplicates — before
  anything is written.
- Importing twice does not double anything.
- A real import of his Vivaldi profile is measured: how long it takes, how large
  the ledger becomes, and whether ⌘O and ⌘Y stay responsive afterwards. The
  keystroke cost is already measured at ~0.95 ms over 5,000 rows; report it at
  112,000.
- Nothing reads the source profile while that browser is running without copying
  first.

## Relevant files

- `crates/laned-core/src/history.rs` — `normalize_url`, `record_visit`, the caps
- `crates/laned-core/migrations/` — a new migration if `seq` has to change
- `swift/MaxPane/Sources/MaxPaneKit/Views/OmniPicker.swift` — where the result shows up
- `swift/MaxPane/Sources/MaxPaneKit/StripStore.swift` — the Swift seam

## Constraints

- **Read the source profiles read-only, and never write to them.** These are his
  real browsers.
- His Vivaldi profile is 642 MB. Do not copy it into the repo, into `/tmp`
  without cleaning up, or anywhere it will be forgotten — a copy of his entire
  browsing history is exactly the artifact not to leave lying around. An earlier
  agent left 2 GB of exactly this in `/tmp` and it had to be swept.
- Import is a bulk write: do it in one transaction, and leave the ledger valid
  if it is interrupted.
