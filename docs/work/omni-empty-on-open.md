# ⌘O sometimes opens with no rows — reproduce before changing anything

## Problem

> "the open dialog should show the mru items immediately similar to fzf ctrl+r"

and, asked what he actually sees on ⌘O:

> "Completely empty" — no rows at all until typing starts.

## What was already checked, so nobody repeats it

**The feature is built and it works.** Do not start by adding it.

- `OmniRanking.emptyQueryRows` builds a `RECENT` section from the corpus sorted
  by `chosenAt`, capped at 24, with sessions under their own headers below.
- The Rust side handles an empty needle deliberately: `history::tier` returns
  `MatchTier::Prefix` for an empty string and `rank` scores every candidate 0,
  so `store.history("", limit: 80)` is "the most recent 80 pages", not nothing.
- His ledger has data: 7 recents, 3 visits.

**Reproduced against the exact binary he runs, twice, and it worked both times:**

1. A throwaway profile seeded with three `maxpane open` calls → ⌘O listed all
   three under `RECENT`, numbered 1–3, sessions below, footer
   `3 PAGES · 0 COMMANDS · 13 SESSIONS`.
2. A `sqlite3 .backup` copy of **his own ledger** → ⌘O listed nine rows
   immediately: Gmail, the WaveShare page, his inbox, Example Domain,
   youtube.com, three `?snap=` URLs and `htop`, footer
   `4 PAGES · 1 COMMANDS · 8 SESSIONS`.

So it is conditional. Something about *when* he pressed it, not whether the
feature exists.

## The condition to hunt

The untested variable is **what had focus when ⌘O was pressed**. Both
reproductions were done from a freshly launched instance where the strip, not a
pane, had the keyboard.

Prime suspect: a **web pane** holding focus, or its address field being edited.
`WebPaneController` claims ⌘F, ⌘← and ⌘→ pane-locally through
`performKeyEquivalent`, guarded on ledger focus and on its own fields not
editing — and `performKeyEquivalent` runs *before* the menu. If anything in that
path swallows or mis-guards ⌘O, the picker would never open at all, which a user
would reasonably describe as it opening empty. **Check whether the picker opens
at all in that state**, because "opened with no rows" and "never opened" look
identical from the outside and have completely different fixes.

Second suspect: a page that takes ⌘O for itself. Gmail binds a great many
keys; a focused `WKWebView` handing the key to the page would do this.

Third: scope. ⌘Y and ⌥⌘O open the same picker in `PAGES` and `SESSIONS` scope.
If a scope is sticky between invocations, a scope whose corpus is empty would
open empty — check whether scope resets per invocation.

## Acceptance criteria

- The condition is **identified and stated**, not guessed at. If it turns out
  the picker never opened, say so and fix that instead.
- ⌘O lists the most recent items immediately, from any focus state: strip
  focused, terminal pane focused, web pane focused, address field being edited.
- A test covers whichever of those was broken.
- While in here, sanity-check the fzf Ctrl+R comparison he drew: most-recent
  first, arrow keys and typing both work from the moment it opens, and the list
  is long enough to be worth scrolling. `OmniRanking.shown` is 24.

## Relevant files

- `swift/MaxPane/Sources/MaxPaneKit/Views/OmniPicker.swift` — `emptyQueryRows`,
  `reload`, `OmniScope`
- `swift/MaxPane/Sources/MaxPaneKit/Views/SearchPalette.swift` — `PaletteController.present`
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift` —
  `performKeyEquivalent`
- `swift/MaxPane/Sources/MaxPaneKit/Commands.swift` — `openAnything` and its menu item
- `crates/laned-core/src/history.rs` — `tier`, `rank` (the empty-needle path)

## Constraints

- Reproduce before changing. The feature demonstrably works in the common case,
  so a change made without reproducing is a change made blind.
- Test with a throwaway `--profile`, never against his live ledger. A copy of
  his ledger will attach to his **live Relay sessions** as a second client —
  which is how the investigation above was done, briefly and deliberately, but
  it is not something to leave running.
