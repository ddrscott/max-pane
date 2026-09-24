# ADR 0040 — Capture Pane: which API reads a Metal terminal's pixels, how a snapshot reaches past the fold, and where the path goes

**Status:** Accepted · 2026-09-23
**Decides:** which of three capture APIs reads a Ghostty pane's pixels, and
whether Screen Recording is needed; how a web pane's ⇧ variant reaches below
the fold when `takeSnapshot` will not; where a captured file is written and
what receives its path; the two chords.
**Evidence:** the Omarchy critique [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F6;
the work item [`docs/work/omarchy-f6-capture-pane.md`](../work/omarchy-f6-capture-pane.md);
ADR-0027 (the pasted-picture store and `RelayUpload`), ADR-0028 (the `COPIED`
chip); `PaneCapture.swift`, `Web/WebCapture.swift`,
`Terminal/TerminalPaneController.swift` (`capture`, `typeCapturedPath`),
`Views/StripViewController.swift` (`capturePane`), `Terminal/OpenServer.swift`
(the `capture` op), `crates/maxpane-open/src/lib.rs`; `CapturePaneTests.swift`.

## The problem

"Look at this rendering bug" was: leave the app, ⇧⌘4, drag a rectangle, come
back, ⌘V. Four of those five steps are outside Max Pane, and the one thing an
agent cannot do at all is the dragging. Omarchy has `Print Screen` and a
`capture` verb in its CLI; the gap is not the screenshot, it is that a picture
of a pane and the prompt that wants to read it are in the same window and
still need another application to introduce them.

## The measurement that decided it

A Ghostty pane draws through Metal. The question — the only genuinely risky
part of this item — was whether its pixels can be read from inside the
process at all, because the obvious fallback, `CGWindowListCreateImage` of the
pane's window rect, needs **Screen Recording**: a TCC prompt, an entry in
System Settings the owner has to add by hand, and a permission that lets the
app read every other window on the machine for the rest of its life. That is a
large thing to ask for a screenshot key.

Measured on 2026-09-23, against a live surface with text on it (a standalone
program, `AppTerminalView` in an off-screen window, twelve coloured lines,
each method's output written out and looked at):

| | result |
|---|---|
| `NSView.cacheDisplay(in:to:)` | 700×400, 321 colours, 11.6% of pixels off the background — **the text, its colours and its layout, complete** |
| `CALayer.render(in:)` | identical, 335 colours |
| `CGWindowListCreateImage` | also works, 379 colours — and includes the titlebar, is deprecated since macOS 14, and needs Screen Recording |

**`cacheDisplay` wins, and nothing needs permission.** The reason it works is
worth writing down, because it is not what the Metal-backed layer suggests:
`AppTerminalView.commonInit` installs a `CAMetalLayer`, but libghostty's
render pipeline **swaps `self.layer` to an `IOSurfaceLayer`** once it starts
compositing (the library says so itself in `AppTerminalView+Lifecycle.swift`,
where a stale `metalLayer` reference is a known bug source). An IOSurface's
contents are ordinary layer contents, so `cacheDisplay` reads them. libghostty
already wraps exactly this as `snapshotImage()`, with a comment warning that a
Metal layer's presented frame "may not be included" — which is the case that
survives: **a pane that has not drawn yet is still the bare `CAMetalLayer` and
comes back flat.**

So the blank case is real but narrow, and `PaneCapture.encode` refuses it:
a capture whose sampled pixels are all one colour is reported as "the pane has
not drawn anything yet" rather than written out. A blank PNG that looks like a
broken screenshot is worse than a sentence.

**Consequence:** if libghostty ever stops swapping to an IOSurface, the
terminal capture goes blank rather than wrong, and says so. The web capture is
unaffected. Screen Recording stays unasked for, and `CGWindowListCreateImage`
stays unused.

## Full page, and why the frame was not enough

`takeSnapshot` gives the viewport. `WKSnapshotConfiguration.rect` taller than
the view does **not** reach below the fold: the rect is read in view
coordinates and clipped to the view, so what comes back is one screen and
blank under it. The page has to be laid out at its full height first.

The first attempt set `webView.frame` and called `layoutSubtreeIfNeeded`. That
silently captured the fold and called it the page — measured at 1 148 px
either way for a 4 000 pt document — because the web view is pinned to
`contentHost` on all four edges by Auto Layout, and the layout pass put it
straight back. **The pin is the thing to move, not the frame.** `WebCapture`
deactivates the bottom constraint, activates a height constraint of the
document's own `scrollHeight` — the same number `WebPrint` measures for a PDF,
so "the whole page" means one thing in both — lets WebKit lay out, snapshots,
and restores both in a `defer`.

Measured on the same day, a 4 000 pt document in a 600 pt lane:
**1200×1148 px visible (32 KB), 1200×8000 px full (205 KB)** — 7.0×, the
document at 2×. A page that fits gets the same picture from both, and the
notice never says "full page" for one (`PaneCapture.isFullPage`).

The ceiling is 20 000 pt. A PDF may be 200 000 because it is vector text; a
PNG of 200 000 points at 2× is 700 × 400 000 pixels, about a terabyte, and an
infinite scroll's `scrollHeight` grows for as long as it is asked.

## Where the file goes, and what receives the path

The same road a pasted picture takes, because to the program reading it there
is no difference and a second road would be a second set of bugs: the
profile's cache directory (`PastedImages`, ADR-0027), swept by the same
`paste_image_keep_days`, and **uploaded through `RelayUpload` when the prompt
that will read it is on a relay server** — a path is only any use on the
machine the program runs on. Only the name and the notice's verb differ:
`capture-20260923-143205.png`, "captured", never recorded in paste history,
since this was never on a clipboard and the path is in the scrollback anyway.

The path goes to **the nearest terminal in the same lane, below first at equal
distance** — below, because ⌘D puts the new terminal under the page you were
reading, and because "whichever the ledger lists first" is not a rule anyone
could predict from the screen. A lane with no terminal has nowhere to type, so
the file is written and its quoted path copied, with the lane's `COPIED` chip
(ADR-0028) — the same chip a program's own copy raises, because to the person
watching it is the same event.

An evicted web pane is rehydrated before it is captured. What is on screen
then is the last eviction's snapshot, and handing back a picture of an older
page than the lane claims to be showing would be a quiet lie.

## The chords, and the CLI

**⌃⌘S** Capture Pane and **⇧⌃⌘S** Capture Full Page. ⌃⌘S is the sibling of
⌃⌘P — the other command that turns a pane into a file — and reads as one on
the same modifier; macOS has no ⌃⌘S (its ⌃⌘ chords are Space, F, Q and D), no
browser has one, nothing here had it, and ⇧⌘S stays Export Strip. ⇧ on the
same key is the idiom already in the app (⇧⌘R to ⌘R, ⇧⌘W to ⌘W): the same
action, asking for more of it. Two commands rather than one command sniffing
the modifier, so both keep a menu item, a ⌘/ row and a `[keys]` binding.

⌃⌘S is live on both pane kinds; ⇧⌃⌘S is greyed on a terminal, which has no
fold — its scrollback is text, and ⇧⌘C copy mode is how you take a piece of
it. Both are ignored inside a sign-in popup, for the reason Save as PDF is:
nobody captures somebody's password field.

`maxpane capture [LANE] [--full]` prints the path, so an agent can ask for a
picture of its own terminal or of the page beside it. No lane is the focused
pane, which is what "my pane" means from inside one.

**This is the op that made the socket answer late.** `OpenServer`'s handler
returned a `Reply`; a capture cannot, because it waits on WebKit's snapshot
and then, on a remote lane, on the upload — and the whole point of the op is
that the caller gets the path the program will actually read. The handler now
takes a completion, called exactly once; every other op calls it before
returning. The wait is 35 s in the app and 40 s in the CLI, up from 8 and 10.

## What this is not

No recording and no OCR, both of which Omarchy has. A video is a different
kind of artefact with a different lifetime, and OCR of a pane whose text the
app can already read (`viewportText`, ⇧⌘C) would be reading a picture of
something it is holding.
