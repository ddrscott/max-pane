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

---

## What it was

**The picker never opened.** Suspect one, and the detail above was right to say
that "opened with no rows" and "never opened" look identical from the outside.

`NSWindow` walks the view tree with `performKeyEquivalent` *before* the main
menu. `WebPaneContainer` calls `super` first so that subviews get first refusal —
written for the find field's ⌘A and the address field's ⌘C — but the `WKWebView`
is also a subview, and a focused web view answers YES to **every** ⌘-chord so it
can hand the key to the page. So ⌘O died in the web view and the menu item never
ran.

Measured, with a real `WKWebView` as first responder in a window
(`WebPaneKeyRoutingTests`):

| first responder | ⌘O reaches the menu |
|---|---|
| nothing (the strip) | yes |
| the address field | yes |
| the `WKWebView` | **no** |

Which is exactly why the two earlier reproductions passed: both were run from a
freshly launched instance with the strip focused, the one column of that table
where the bug cannot happen.

⌘O was not alone. Under the same condition ⌘T, ⌘Y, ⌘R, ⌘W, ⌘B, ⌘P, ⌘[, ⌘], ⌘=
and ⌥⌘O were all swallowed before the menu.

**This had already been found once.** `TerminalPaneController` clears Ghostty's
keybinds with a comment naming this same mechanism — "claims them in
`performKeyEquivalent`, which runs before the menu … here they silently ate Max
Pane's own, so Close Lane worked from the File menu and did nothing from the
keyboard". The terminal pane's hole was closed and the web pane's was not.

### The fix

`Command.claims(_:)` answers whether the app has declared a ⌘-chord for itself,
and `WebPaneContainer.performKeyEquivalent` returns false for those before it
descends into the page. No browser lets a page bind its chrome keys.

Only ⌘-chords, so Esc (`.ungather`) still belongs to the page — leaving a
fullscreen video, closing a modal. ⌘A, ⌘C, ⌘V and ⌘Z are declared nowhere, so
the fields keep them and the "first refusal" the comment was written for is
intact; ⌘F stays a pane key for the same reason.

### Not the cause, and ruled out with evidence

- **Sticky scope.** `showOmniPicker` builds a fresh `OmniPicker` with an explicit
  scope every time. Scope only moves on ⇥ within one picker's life.
- **A ranking that returns nothing.** `emptyQueryRows` always appends a `.note`
  row when it has nothing else, so `build` cannot return an empty array for an
  empty query — `rowsRender` already asserts this across every scope.
- **The table drawing blank rows.** The failure `layOutRows` exists to prevent.
  Presenting a palette over a parent window materialises its cell views; the
  manual layout pass is doing its job.
- **A stale binary.** The installed app is commit `92547ca`, and `OmniPicker.swift`
  and `SearchPalette.swift` are byte-identical between it and HEAD.
- **A ledger damaged by the `--profile` migration** landing under the running
  app. It never ran for that instance: `profiles/` is empty and the ledger is
  still live at the old path.
