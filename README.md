# Max Pane

A fullscreen macOS app where terminals and web views are peer panes, arranged as
portrait-bounded columns ("lanes") on an infinite horizontal strip. A supervision
surface for agentic CLI work: watch several agents run while reading what they
cite, in columns, not overlapping windows.

The spec is [`docs/PRDSwift.md`](docs/PRDSwift.md). This README is the source of
truth for how to build and work on it.

**Design invariant:** a lane is a portrait-bounded column. Wide content scrolls
inside the lane; the lane never widens past its max.

---

## Layout

```
crates/laned-core/     Rust. The ledger, ordinals, tagging, search, eviction policy.
                       Platform-agnostic — no AppKit concepts leak in here.
swift/MaxPaneCore/     The Rust core as a Swift module (uniffi-generated).
swift/MaxPane/         The app. Rendering, input, WKWebView/SwiftTerm lifetimes.
spikes/                Phase 0 spike programs. Kept: they are how the numbers
                       in docs/spikes/ were obtained.
docs/decisions/        ADRs. One per open decision in PRD §14.
docs/spikes/           Spike reports, with measured numbers.
docs/reference/        External protocol references (RelayTTY).
docs/proposals/        Proposed changes to external dependencies. See "RelayTTY".
```

**Everything durable lives in `laned-core`.** The Swift app is a view. If a piece
of state would be lost when the app quits, it is in the wrong place.

---

## Toolchain

This machine has **Command Line Tools, not Xcode**. `xcodebuild` does not work and
is not needed: the app is a SwiftPM package, and the `.app` bundle is assembled by
hand and ad-hoc signed. Do not introduce an `.xcodeproj`.

Homebrew's `rust` formula (1.86) shadows rustup in `PATH` and is too old for
uniffi 0.32. `rust-toolchain.toml` pins stable, but only rustup's shims honour it:

```sh
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"   # or: source scripts/env.sh
```

Everything in `scripts/` does this for you.

## Build

```sh
./scripts/build-app.sh         # everything: core, bindings, app, bundle, signing
./scripts/build-app.sh release run   # ...and launch it
```

Signing is the last step and it is not optional. WKWebView will not spawn its
content processes for an unsigned, unbundled binary, and adding a file to the
bundle *after* signing breaks the seal — with no symptom until something checks,
so `build-app.sh` checks.

For the core alone:

```sh
./scripts/gen-bindings.sh      # build laned-core, regenerate the Swift bindings
cd swift/MaxPane && swift build
```

Re-run `gen-bindings.sh` after changing any `#[uniffi::export]` signature. The
generated module **must** be called `laned_coreFFI` — the generated Swift does
`#if canImport(laned_coreFFI)`, and a different name compiles cleanly with no FFI
symbols at all, which fails at link time in a thoroughly unhelpful way.

## Test

```sh
./scripts/test.sh                # the edit-loop run: Rust + Swift, ~1.5 s
./scripts/test.sh bench          # the cost tests, in release
./scripts/test.sh shots DIR      # render the header and picker sheets as PNGs
./scripts/test.sh all            # all three
```

Use `scripts/test.sh` rather than a bare `swift test`: swift-testing ships inside
Command Line Tools but SwiftPM does not look for it there, and the fix is a
framework search path plus two rpaths pointing at two different directories. The
failure without them is a `dlopen` error that names neither.

### What the default run leaves out, and why

**Two tests, not two hundred.** Measured: the default run is ~1.5 s, of which
the Swift tests are 0.8 s and SwiftPM's own no-op overhead is another 0.4 s.
Nothing in the Swift suite is worth gating — the slowest single test in it is
76 ms. The cost lived on the Rust side, in two timing measurements:

| | before | why it costs |
|---|---|---|
| `rust_side_snapshot_cost` | 0.95 s | builds 300 lanes / 400 panes, then 200 samples |
| `cost_of_a_keystroke` | 22 s | builds 112,840 pages — the owner's real corpus size — then 8 queries |

A third, `cost_of_importing_a_real_profile`, is behind `MAXPANE_BENCH` **and**
`MAXPANE_IMPORT_SOURCE`, which has to name a browser history file. It is the one
measurement with no synthetic stand-in: 112,846 rows of real URLs with real
titles are what the trigram index has to narrow, and a generated corpus of the
same size is a different question. It reads the source read-only, builds its
ledger in a temp directory, and leaves nothing behind.

```sh
MAXPANE_BENCH=1 \
MAXPANE_IMPORT_SOURCE="$HOME/Library/Application Support/Vivaldi/Default/History" \
  cargo test --release -p laned-core --test import_cost -- --nocapture
```

Together they are far the largest thing in the suite — and both print numbers that only
mean anything in a release build, which the default run is not. They are gated
on **`MAXPANE_BENCH`** and `./scripts/test.sh bench` runs them in release, where
the numbers are worth reading.

Render-sheet tests (`LaneHeaderRenderTests`, `OmniPickerRenderTests`,
`SidebarBookmarkRenderTests`, `WebPopupBarRenderTests`) draw views
into bitmaps and write PNGs. They are gated on **`MAXPANE_SHOTS`**, which names
the directory to write into — one variable for every sheet, so a new render test
joins the same command rather than adding a third switch.

The rule for the gate: **anything that protects correctness stays in the default
run.** A gated test measures a number or produces a picture for a human to look
at. Nothing that can fail because the code is wrong is behind a switch, and
every gated test prints a `SKIPPED` line naming the switch that runs it.

`scripts/test.sh` runs the Swift half as the `tests` profile. Without one the
`WKWebsiteDataStore` identity tests derive exactly the UUIDs the real app uses
for its cookie jars — the default profile's salt is empty — and they only ask
for identity so nothing is written today, but a test process that can name the
live jar should not be one WebKit release away from opening it. See
[Profiles](#profiles).

`WebPopupDialogTests` is the Swift suite that serves real pages. Two loopback
sites on two ports — two origins to WebKit — stand in for a site and its sign-in
provider, and a real `WebPaneController` drives real `window.open`s: the size in
the features string, the provider's `postMessage` and cookie reaching the
opener, `window.close()` handing the focus back, five opens in a row, a chooser
opened from the popup, a `target=_blank` click. It writes a cookie, so it skips
itself without a named profile. LinkedIn's "Sign in with Google" needs a real
account and is not driven from a test; this suite is its local reproduction.

`crates/laned-core/tests/durability.rs` holds the half of PRD §15's acceptance
tests that the core owns — mostly "the strip is identical after a `kill -9`",
which it proves by dropping `Core` with no shutdown path and reopening the file.

---

## RelayTTY

`/Users/spierce/code/relay-tty` is a **stable external dependency and is
read-only**. Do not modify its wire protocol. If the app needs something the
protocol does not offer, write a proposal in `docs/proposals/` and stop.

Its `PROTOCOL.md` is stale and wrong in 17 places. Use
[`docs/reference/relay-integration.md`](docs/reference/relay-integration.md),
which was written from the Rust pty-host source and cites it.

---

## Conventions

- **Commit the mutation before animating it.** Every layout change is a
  synchronous SQLite write that happens before the UI moves. A `kill -9` may cost
  pixels; it may not cost order.
- **The system never reorders.** Lanes move because the user moved them. Tagging,
  search and gather are all read-only over ordinals.
- **Never edit a shipped migration.** Add a new numbered file in
  `crates/laned-core/migrations/`.
- **Spikes keep their code.** A number in `docs/spikes/` is only trustworthy if
  the program that produced it is still runnable.
- When reality contradicts the PRD, surface the conflict in an ADR rather than
  silently reinterpreting the requirement. Six such conflicts are tabulated in
  [`docs/acceptance.md`](docs/acceptance.md), and the PRD itself is annotated
  **[AMENDED]** in place.

## Using it

```sh
./scripts/build-app.sh release run
```

Press **⌘/** for every shortcut. The three that matter:

| | |
|---|---|
| **⌘O** (also **⌘T**) | start anything — a command, a URL, a page you have been to or kept, a session that is already running |
| **⌘[** / **⌘]** | move focus between lanes |
| **⌃⌘[** / **⌃⌘]** | dock this lane to that edge of the window, or undock it |
| **⌘G** | Lanes ⇄ Gallery: every lane on one screen, live; ⌘G again goes back |
| **⌘P** | find a lane by title, URL or something it printed |

⌘O is the only door into the strip, because "something goes to the right of
this" is a single decision — and until recently it was three keys that each saw
a third of the answer. It searches everything you have ever started at once:
commands, pages, and Relay sessions that are running but not on the strip. Most
recent first when you have typed nothing, each with a number: **⌘4** starts the
fourth one. Anything you type is offered both ways — as a command and as a URL,
always the first two rows — so a wrong guess about `localhost:3000` never hides
the other reading and ⌘O ↩ always does what you said.

**⇥** narrows to pages, commands or sessions; **⌘Y** and **⌥⌘O** open the same
picker with those scopes already chosen. **⌘⌫** forgets the selected row — or,
on a page you have kept, stops keeping it.

A bookmark is a page, so it is offered by the key pages are offered by, marked
**★** and carrying the folder it is in. A page that is both kept and visited is
one row and it is the bookmark: the title on it is the one you chose, and
`Work/Rust · notes` is what tells two pages called *Notes* apart.

⌘P stays separate on purpose: it finds what is *already on the strip* and
scrolls to it, where every ⌘O row spends something to create a pane.

With nothing typed it is not empty: every lane, most recently used first, the
gathered-away ones included. The lane you are in is listed and marked focused,
but the one before it is selected — so ⌘P ↩ goes back, the way ⌘⇥ does.

### A web lane

The chrome is one 26 pt row at the foot of the pane: back, forward,
reload/stop, the address, find, and a load hairline. The address field is also
the search box and also the link-target readout, because a portrait column has
room for one field — it shows where you are, swaps to where a hovered link goes,
and says so when a navigation fails.

**⌘-click or middle-click a link** to open it in a lane of its own, right of
this one, instead of navigating the lane you are reading. ⌃⌘ and ⌥⌘ are left to
the system, which already uses them for right-click and download-linked-file.
`target=_blank` has always landed this way; now the gesture does too.

**A page's popup is a dialog, not a lane.** When a page opens a window of its
own — "Sign in with Google", a payment confirmation — it appears centred over
the window, wherever the page that opened it is: scrolled off the strip, docked,
or a gallery tile. Its bar is the one thing the page cannot draw: a padlock and
the host for https, an amber **⚠** and `http://` for plain http, the full
address on hover, and a click copies it. ✕ or Esc closes it, and so do the
page's own `window.close()`, closing the lane that opened it, and that lane
going to another site. A click back into the strip does not, so a half-typed
password survives a look at another lane. Clicking "Sign in" again puts the new
popup in the same dialog instead of stacking a second, and an account chooser
the popup opens stacks over it. When it goes, the lane that opened it has the
keyboard again.

Inside it, **⌥⌘L** fills a saved password into the popup's own form, **⌘W**
closes it and **⌘R** reloads it; the keys that would act on the page behind it —
⌘L, zoom, ⌘D, ⇧⌘L — do nothing. A question the popup's page asks is drawn inside
the dialog, a download lands in the opener's download bar, and a link it opens
in a new tab gets a lane. Nothing about a popup is saved, so a relaunch does not
bring one back. See [ADR-0013](docs/decisions/0013-web-popups-are-dialogs.md).

A load that fails says so where the address was — `⚠ server not found —
example.com`, for five seconds — and takes the hairline down with it. Stopping a
load with ✕ and starting a download are not failures and say nothing. Plain
`http://` loads, with an amber **⚠** before the address; the loopback gets no
warning, because `localhost:3000` twenty times a day is how a warning stops
being read.

A page with no `<title>` gets its host and path on the lane header rather than
keeping the last page's title — `localhost:3000/api/users`, which is what tells
six columns of raw JSON apart.

### History

**Nothing is ever evicted.** No row cap, no age cap — a page you opened two
years ago is one ⌘O away, and the only things that remove a row are ⌘⌫ on one of
them and **Clear** in the history window. One row
per address, and **measured** at 109 000 real pages: **180 MB**, of which the
table is about a quarter and the trigram index below is the rest. Vivaldi spends
642 MB on the same browsing.

That number replaces an estimate of 28 MB that stood here until a real corpus
was imported and weighed. The estimate was arithmetic on the row and forgot what
pays for it: a trigram index is roughly three entries per character of everything
it indexes, and everything it indexes is the whole URL, the title and every
alias.

That is affordable because the search is indexed rather than scanned. Every
page's address, title and redirect sources go into a trigram index (migration
0009), which narrows the table before anything is ranked. Measured over 112 840
pages, release build: **a keystroke costs about 7 ms from the third character
on**, and 1 ms once the query is distinctive.

**The first two characters used to cost about 60 ms** and now cost 10 ms,
because a trigram index has nothing to say below three characters and every row
was read. Migration 0011 gives a short needle three characters to find: at each
place a match can *start* — the front of a field, and every position after a
word boundary — the row carries a **shoulder** entry, a doubled marker character
and the two that follow, so `de` is looked up as a trigram like everything else.
Measured over the owner's real 108 854 imported pages, every letter of the
alphabet as a first keystroke:

| a–z, first keystroke | before 0011 | after |
|---|---|---|
| best | 61.5 ms (`a`) | **1.0 ms** (`z`) |
| median | 66.7 ms | **10.8 ms** |
| worst | 84.9 ms (`z`) | **48.2 ms** (`g`) |

Every one of the 36 letters and digits got faster, and so did every second
keystroke sampled — `gi`, `do`, `ma`, `co`, `gh`, `ne`, `lo`, `ap` went from
65–102 ms to 0.5–22 ms. `g` is the worst because a fifth of his pages have a
field that starts with one. The one keystroke that got *slower* in a first draft
was `w`, and the reason is pinned in
`the_www_a_reader_never_sees_is_not_a_shoulder`: `www.` is stripped before
anything is matched, so it is nobody's prefix and had no business being indexed
as one.

**The shoulder narrows, and it is refused the moment it could be lossy.** It
drops the rows that contain what you typed only mid-word, so it is trusted only
where that cannot cost a row its place: the match tiers are 10 000 apart and a
score inside one spans under 1 000, so every prefix match outranks every
word-prefix match, which outranks every mid-word one — and once the shoulder has
handed back a page's worth at a tier, the rows it left out were all a tier lower.
When it hands back fewer, the whole table is read instead, which is why `z` still
finds a page whose only `z` is in the middle of a word. It is also refused when
its answer would be more than a third of the table, because reading a third of
the rows one at a time costs more than reading all of them in one pass. The
price is 45 MB of ledger (171 MB → 217 MB at 108 854 pages) and a **6.4 s
migration** on the launch that upgrades — 4.7 s of which is rebuilding the 0009
index that an FTS5 table cannot have a column added to.

The index narrows; it never ranks. `history.rs` still decides the order, so what
comes back is what an uncapped scan would have produced — including `mxp`
finding `max-pane`, which a substring index cannot see and which falls through
to a full pass exactly when nothing matched literally.

**A redirect leaves one row, and every address on the way to it stays
searchable.** Type `youtu.be/…`, land on `youtube.com/watch?v=…` through a 303
and a consent page, and there is one entry — the page you actually saw — with
the other two as aliases: searchable, never listed. That now includes
client-side redirects. `location.replace` and `<meta refresh>` finish loading
before they redirect, so each one *is* a page for a moment and used to stay one:
an untitled row that reopens to a bounce. A navigation nobody asked for, inside
two seconds of the last one finishing, is the page redirecting — and the
interstitial stops being an entry.

**Rows say when.** `14:32` today, `Tue 09:15` this week, `22 Feb 07:05` this
year, `22 Feb 2024` before that. The old `22d ago` could not answer "what did I
have open Tuesday afternoon", which is most of what history is for. Sessions
keep their relative age, because a terminal's last output is a question about
now.

### The history window

**⇧⌘Y.** ⌘Y is the door — three characters, ↩, the page opens. ⇧⌘Y is the
record, in a window with room in it, because four of round 2's complaints were
the same complaint and none of them fits in a palette row 26 points tall:

**The list does not stop.** It used to end at row 60 while the footer counted
thousands. It now pages as you reach the bottom, and the footer says which of the
two numbers it is quoting — `240 OF 112,840 PAGES LOADED`, never a total dressed
up as a reach.

**The address is the whole address.** It wraps rather than truncating, up to four
lines. The two CloudWatch rows that made this a bug — same title, same age, both
cut at `…log-group/aws$252Flam…`, differing only in a trailing
`stream-a`/`stream-b` — are now told apart by reading them. ⌘C copies the one
under the selection; hovering shows it whole.

**Days are days.** `// TODAY`, `// YESTERDAY`, `// TUE 9 SEP`, each carrying the
number of pages that day holds **in the record** rather than the number that
happen to be loaded. A search is not grouped: it comes back in score order, from
the same ranking ⌘Y uses, and grouping a ranked list by day would put a header
over rows that are not all from that day.

**Deleting is something you agreed to.** ⌘⌫ asks first and prints the full
address in the asking — in this window and in the palette, where the unconfirmed
delete was actually measured. Cancel is the default button, so a ⌘⌫ typed by
reflex is not confirmed by a ↩ typed by reflex.

**There is a way to clear it.** Last hour, today, last 7 days, everything — each
one counted before the dialog opens, so the sentence you agree to is about the
pages that will actually go. It says *pages*, not visits: one row is one URL
however many times you opened it, so a page first found last year and reopened
ten minutes ago is inside "the last hour" and goes with it. Chrome, which keeps
every visit separately, would delete only the one.

The browse list is ordered by `last_visit_at`; the palette is still ordered by
`seq`. That is not two opinions about recency — a day header is only true if
every row beneath it is from that day, which holds only when the list is sorted
by the field the day is read from. The two agree for everything this app records
and everything an import writes, and part company exactly when the clock moves
backwards, which is the case `seq` exists for.

### Bookmarks

**⌘D** keeps the page in the focused lane, and the **★** in its chrome bar
lights. ⌘D on a page already kept opens the same little panel on it. The panel
is where the name and the folder are — nothing on it is a commit button, because
the page was kept the moment you pressed the key; **Remove** is the undo, and it
is there because *"I meant ⌘W"* is the other thing that happens a second after
⌘D.

⌘D cost ⌘O one of its two alternate keys. ⌘T still opens the door.

**The folders are in the sidebar**, above the sessions, as a section you can
fold away. That is the answer to a gap a critic called the most defensible one
in this app: the chrome bar used to carry the sentence *"the strip is the
bookmarks bar and a pinned lane is the star"*, and it was right about the page
you are looking at and wrong about the eight folders you are not. A docked lane
keeps one page in front of you by spending a column on it; a bar keeps two
hundred and costs nothing until you look.

It is the sidebar rather than a window or a fourth palette because the sidebar
is already open, already vertical — which is the axis a 420 pt column has to
spare — and already groups things and folds what you are not using. Clicking a
folder opens it; clicking a page opens it in a lane, right of the one you are
in, exactly where a ⌘O page lands. The filter box filters bookmarks too, and a
search opens the folders it matched inside. The **sort** and **scope** controls
deliberately do not reach them: the order of a bar *is* the thing, and eight
folders that have been in eight places for years are found by the hand rather
than read.

**And the order is yours to set.** Drag a row between two rows to put it there,
or onto a folder to file it at the end of that folder. **Move Up** and **Move
Down** on the right-click menu do it a step at a time, which is the better
instrument for the case this exists for — eight folders arriving from an import
in Vivaldi's order and wanted in yours — and the only one that does not need a
steady hand. A gap belongs to the row *below* it, so the space under a folder's
last page means "after the folder" rather than "inside it, last"; dropping onto
the folder is how you say the other one. Dragging is off while the filter box
has something in it: the rows are a subset then, and a position counted over
them would land somewhere you had no way of predicting.

`position` stays a plain integer that gets renumbered, rather than the
fractional ordinal the strip's lanes are ordered by. A drag commits one write on
drop rather than one a frame, a folder is tens of rows, and renumbering measures
at 0.28 ms for a folder of 47 and 2.7 ms for one of 1 000 — so the ordinal would
buy nothing here and would cost the zero-padded sort key the tree is read with.
An order you set survives the next import, which appends what is new and leaves
what is already here where it is.

One row per placement, so the same page kept in two folders is two bookmarks —
which is what every browser means by it, and what a table keyed by URL could not
say. A bookmark's title is yours: nothing the page calls itself later overwrites
it, and a second import does not either. Bookmarks are not history and survive
**Clear** — that is the whole reason they are their own table (migration 0010)
rather than a flag on `visit`, since `clear_history` deletes rows and a flag
cannot stop a delete.

There is no index under them, and that is the same rule history follows from the
other end. History pays for a trigram index because its corpus is 112 840 rows
that are never otherwise in memory; a bookmark corpus is the one you curated by
hand — the owner's Vivaldi bar is eight folders and a few hundred pages — so the
whole of it is read and ranked by **the same ranker history uses**. `hop` finds
`hoppers` and not *Launchd notes*, in both lists, because it is one
implementation rather than two that agree today.

### Importing history and bookmarks from another browser

**⌥⌘Y.** ⌘Y opens history; ⌥⌘Y is where it came from. One pass over a profile
brings both halves, because "import from Vivaldi" is one decision — the wizard
already finds the profiles, already explains merge against replace, and already
takes the snapshot a Firefox bookmark import needs anyway, its bookmarks being
inside the `places.sqlite` its history is in.

The wizard offers the
browsers that are on this Mac, found by looking for the files rather than from a
list — Chromium's `History` (Vivaldi, Chrome, Brave, Edge, Chromium, Arc, Opera,
one row per profile), Safari's `History.db`, Firefox's `places.sqlite`.

**Merge** folds the browser's history into yours and deletes nothing. A page both
have becomes one row with the earlier first visit, the later last visit and the
larger visit count — every field a `min` or a `max`, which is exactly what makes
importing the same profile twice a no-op. The alternative was a second store
recording which rows had already been imported, to protect a number that is
displayed and never ranked.

**Replace** keeps only the browser's history, and copies the whole ledger to
`ledger.db.pre-import-<ms>` beside itself first. The last screen names that file,
because it is the only way back from a one-click choice.

Nothing is written until you have read the dry run: how many pages the source
has, how many are not importable, what dates they cover, how many you already
have, and what the ledger's page count goes from and to. The button underneath
then says which of the two it is about to do and to how many pages.

**An import is interleaved, not appended.** `visit` is ordered by `seq`, a
counter rather than a clock (migration 0004), so appending 109 000 pages would
give every page from 2024 a higher `seq` than everything you did this morning
and the list ⌘O opens with would be two years old. Instead every `seq` in the
table is re-derived from `last_visit_at` at the end of the import. That
reproduces the existing rows' order exactly — this app stamps `seq` and
`last_visit_at` in one statement, so sorting by the clock and breaking ties on
the old counter is the identity — while slotting imported rows into their real
places. `seq` stays what 0004 made it: unique, total, never ambiguous.

**The browser does not have to be closed, and closing it does not help.**
Chromium opens `History` with `PRAGMA locking_mode = EXCLUSIVE` and holds the
lock for the life of the process, so SQLite's backup API cannot read a page of
it — `database is locked`, every time, against a running Vivaldi. Max Pane copies
the file and its `-journal`/`-wal`/`-shm` siblings instead, reads the copy, and
deletes it. The source is never written to. The copy lands beside the ledger
rather than in `/tmp`, because it is a byte-for-byte copy of everywhere you have
ever been.

Safari's history is behind Full Disk Access, and without it SQLite reports the
refusal as `unable to open database file` — which reads as a corrupt profile. The
wizard checks first and offers the row with the sentence that says which checkbox
to tick.

Measured against a 613 MB Vivaldi profile — 112 846 URLs and 462 794 visits back
to 2024-02-22 — release build:

| | |
|---|---|
| dry run | **3.1 s** |
| import | **15.4 s**, 108 854 pages (3 992 not importable: `chrome-extension:`, `mailto:`, rows Chromium itself hides, and second spellings of a page already counted) |
| ledger afterwards | **180 MB**, WAL checkpointed back into the file |
| importing it a second time | 0 rows added, nothing moved |
| a keystroke afterwards | **16–18 ms** from the third character; 0.5–48 ms for the first and second, since migration 0011; 183 ms for `com`, which is a substring of most of the corpus |

The keystroke numbers are worse than the 7 ms this README quotes for a *synthetic*
corpus of the same size, and the reason is the corpus rather than the size: real
browsing is full of `com`, `www` and `github`, so a short real needle narrows to
tens of thousands of rows where a generated one narrows to hundreds. 183 ms is
the worst case measured and it is a query nobody stops typing at; from the third
distinctive character it is under 20 ms. The one- and two-character cost was the
trigram floor, and is now the shoulder entries described under **History** above.

The wizard runs both long calls off the main thread — the only place in the app
that does, because everything else takes microseconds.

**The bookmarks come with it.** Chromium's bar lands on your bar and its other
roots become folders on it — burying the part used daily one level down to
preserve a hierarchy nobody looks at would be importing the file rather than the
bookmarks. Firefox's toolbar does the same. A bookmark is "already here" when
some row has that address in that folder, which is what makes a second merge
write nothing without a side table recording what has been imported, and what
keeps a name you changed from being changed back.

The report says *at least* N bookmarks afterwards, and means it: the folders an
import has to create are not knowable without creating them, and a guess by
counting distinct paths is a number that is right until a source has two folders
of the same name in different places.

**Safari's bookmarks are not imported.** They are a binary property list, and
the only reader for one on this Mac is `plutil` — a macOS program, in the half
of this app that is deliberately platform-agnostic. The wizard prints
`bookmarks — not readable from this browser` on that row rather than a `0`,
because a zero would say Safari has none.

### Passwords

**Max Pane has no password store.** Every credential it can reach lives in the
macOS Keychain as a `kSecClassInternetPassword` item — the same class and the
same space Safari uses, with no service attribute of ours fencing them off.
Nothing goes in the ledger, the config file, a plist, a temporary file or a log
line.

Sharing Safari's space was a decision with a real alternative, and it won on
three counts. A password saved in Safari is one you can use here with no import
at all. Deleting one has an obvious home — System Settings → Passwords, which
lists what Max Pane wrote next to everything else, with the same delete button —
so "forget this password" is not a feature this app had to invent. And macOS
keeps the access control: an item Safari wrote is ACL'd to Safari, so the first
time Max Pane reads one, the system asks. That panel is the point.

The cost, stated plainly: **the Keychain identifies an app by its code
signature, so the panel comes back whenever that changes.** On this Mac it
mostly does not — `build-app.sh` finds a Developer ID and signs with it, which
is stable across rebuilds — but a build on a machine with no signing identity
falls back to ad-hoc (`MAXPANE_SIGN_IDENTITY=-` forces it), and an ad-hoc
signature is a different application to the Keychain every time it is made.

#### What this is not

It is not Safari's autofill, and the difference is the whole design rather than
a missing feature.

`WKWebView` has no password autofill and no public API that fills a form the way
Safari does — Password AutoFill with associated domains is for native app
fields, not for a browser rendering arbitrary sites. So the only mechanism is
injecting into the page, and a credential injected into a page's JavaScript
context is a credential handed to every script the page chose to load. That is
true of Safari's autofill too. What can be controlled is *when* it happens, so:

- **Nothing is ever filled automatically.** Not on load, not on navigation, not
  on a timer, not at a page's request. There is no script injected at document
  start and no message handler a page can call. ⌥⌘L fills, or the `•••` in the
  chrome bar does — both of which mean a person is looking at the form.
- **The site is WebKit's answer, not the page's.** The match is against
  `WKWebView.url`, the load WebKit committed, and it is exact in scheme, host
  and port. `https://example.com` and `http://example.com` are different sites;
  so are `example.com` and `login.example.com`. A saved credential is never
  filled into a page that merely says it is your bank.
- **A cross-origin frame gets nothing, and not because we check.** The fill
  walks into a subframe only through `contentDocument`, which the same-origin
  policy makes `null` for a frame from another site — WebKit's refusal, inside
  WebKit, before any of our logic runs. Same-origin frames are filled, because
  they provably *are* the page. When the sign-in box is in a frame we cannot see
  into, the bar says so instead of pretending there was no form.

  Measured against real WebKit rather than assumed, because the first version
  was wrong: a sign-in form served from a second port on localhost — a genuinely
  different origin — answers `opaque-frame` and nothing is written, and so does
  a `sandbox="allow-scripts"` frame. But a `srcdoc` or `about:blank` frame
  *inherits* its parent's origin and is fully scriptable while still reporting
  `location.origin === "null"`, so the strict comparison refused the one kind of
  frame that is unambiguously the page itself. Reachability through
  `contentDocument` is the proof, and those are now accepted; the top document
  is still compared exactly, with no inheritance allowed.
- **The page is re-checked after the Keychain answers.** The macOS panel can sit
  there for a minute and a page can navigate underneath it, so the origin is
  read again on the way back and a page that changed gets nothing.
- **Two password boxes means no fill.** That is a sign-up or a change-password
  form, and guessing which box the old password goes in is how a manager types a
  password into a field the site is about to display.
- **The password is an argument, never source.** `callAsyncJavaScript` binds it
  as a value, so there is no escaping to get wrong and no script string that
  could carry it into a log.

The fill runs in an isolated content world, which is worth one sentence: the DOM
is shared, so filling works, but the JavaScript globals are not — a page that has
replaced `HTMLInputElement.prototype`'s `value` setter has replaced its own copy
and not ours, so a plain assignment from here *is* the native setter. Checked
against a page that does exactly that: the write lands and the page's own
accessor never sees it. On an ordinary form the fill also dispatches bubbling
`input` and `change`, which is what a React-style controlled input needs to keep
the value rather than snap back on its next render.

#### Saving one

⇧⌘L, or `Save a Password for This Site…` in the `•••` menu, opens a sheet in the
pane — and that is the *only* way a password typed into a web page reaches the
Keychain. **Max Pane does not watch what you type into password fields.** A
script that could offer to save what you just typed is a script that reads what
you just typed, on every site, forever; the convenience it buys is not worth
having written it. So there is no save prompt on submit, and saving is a
deliberate act.

The other two doors are the HTTP sign-in sheet, which now carries a *save this
password in the macOS Keychain* checkbox — unticked by default, and with it
unticked nothing reaches the disk and the credential lives in memory until the
app quits, exactly as it did before — and the import below.

The `•••` in the chrome bar appears only when the site in the address bar has a
password saved for it. One saved account fills on ⌥⌘L; several open a menu,
because a key that picked one of your two logins for you would be wrong half the
time and silent about it.

#### Importing from another browser

⌃⌥⌘Y. Chromium only — Vivaldi, Chrome, Brave, Edge, and the rest of the family.

**Safari needs no import**: its passwords are already Keychain items, so reading
the Keychain *is* the import and there is nothing to run. **Firefox is not
read** in this version; its `logins.json` is encrypted through NSS, which is a
different mechanism again.

Chromium keeps each password AES-encrypted in `Login Data` under a single key in
the login keychain called `<Browser> Safe Storage`. So the import is: copy that
file — plus its `-journal`, `-wal` and `-shm`, opened read-write so a hot
journal rolls back, because a running Chromium holds `locking_mode = EXCLUSIVE`
and `sqlite3 .backup` cannot read it at all — read the rows, delete the copy,
then ask macOS for the key and open each row.

Two things about that are deliberate:

- **`laned-core` never sees a password.** It has no Keychain, so it cannot have
  the key; it hands back ciphertext and the app process does the rest. A
  plaintext password exists for the length of one loop iteration and goes
  nowhere but the Keychain.
- **macOS asks the consent question, not us.** The screen before it names the
  panel that is coming and says Deny stops the import with nothing written,
  because an unexplained "Max Pane wants to use your confidential information
  stored in Vivaldi Safe Storage" is a dialog people either deny out of
  suspicion or accept out of habit.

Rows that are not passwords are dropped before they can become Keychain items: a
"Never for this site" refusal (35 of the owner's 480), a federated *Sign in with
Google* entry, an `android://` login synced from a phone. The report is
counters and never a list — a list of what was imported is a list of the sites
you have accounts on.

On the encryption itself: on macOS it is AES-128-**CBC** with PKCS#7 and a
16-space IV, under PBKDF2-HMAC-SHA1(`saltysalt`, 1003 rounds, 16 bytes) — not
the GCM that Chromium uses on Windows. Measured rather than remembered: all 442
encrypted rows in the owner's real profile begin `v10` and are block-aligned to
16 bytes, which GCM's 12-byte nonce and 16-byte tag never are. The distinction
matters because GCM tells you the key was wrong and CBC hands back plausible
rubbish, so the check that a decrypted row is valid UTF-8 is what turns a wrong
key into skipped rows rather than a Keychain full of noise.

### The session browser, and which pane has the keyboard

Clicking a session in the left-hand browser scrolls to its lane **and gives it
the keyboard** — the same two things ⌘P does, and in the same order. It used to
only scroll, and flash the lane's border in the focus colour on the way, so the
click looked like it had focused the lane and then silently given up; the first
keystroke went to whatever lane you had left behind. A row for a session that is
not on the strip still attaches it instead — and only one that is not. A session
that already has a lane, even a lane a gather view is hiding, is revealed and
focused rather than attached again, and the core refuses a second lane for a
session besides. The sidebar used to read "on the strip" off the gathered list,
so a session tagged with another project looked unattached, every click added a
lane, and the gather hid each one; one of the owner's sessions reached six.

A row names a *session*, and a lane holds a stack of them, so the click focuses
the pane whose session you clicked rather than whichever pane is on top.

**The orange outline is around the pane with the keyboard, never the lane.** It
used to go around the whole column, with a short tick marking the pane inside —
which meant a two-pane lane outlined in orange with the keystrokes going to the
pane at the bottom, and the tick the only thing on screen that disagreed. "Which
of these gets the next keystroke" has a real answer in a split lane, a terminal
only blinks a cursor, and a page looks identical either way.

The rule has no exceptions, including a lane of one pane: the outline stops
below the header, because the header is never where a keystroke goes. The
focused lane's header is lifted a shade instead, which is what still says
*which column* from across the strip. The lane's own border stays a neutral
hairline, and flashes orange only for the ⌘P jump, which is a place to look
rather than a place to type.

### Moving a pane

**Drag a pane by the grip at its top-left.** Drop it in the upper or lower half
of a pane in another lane and it joins that lane's stack, there; drop it in the
gap between two lanes — or off either end of the strip — and it comes out into a
column of its own. Which is ⇧⌘D and ⌘D in the other direction, by hand: the
stack and the strip are the two axes this app has, and until now a pane could
only be *made* on one of them and never moved to the other.

A bar between two columns means a new lane opens there. A column outlined, with
a rule across it, means the pane lands in that stack at that rule. A drop that
would put the pane back where it already is shows nothing and does nothing —
including dropping a lane's only pane onto its own lane, which would otherwise
dissolve the lane and put the pane into the column it had just destroyed.

**One level of nesting, still.** Lanes hold panes and panes hold nothing, so
there is no drop that could make a tree; the drag has exactly two outcomes
because the strip has exactly two places to put something.

A lane left with no panes goes with the pane that left it, for the reason ⌘W
already deletes one: an empty column is not a thing you can do anything with.
And a lane that was *only* that pane is **moved** rather than rebuilt, so the
width you dragged it to, its title, its tag and ⇧⌘P come with it — a lane of one
dropped between two lanes is ⌘⇧→ with a mouse, and the only difference is where
the pointer was.

A pane joining another lane takes the mean of that stack's heights, which is the
rule ⇧⌘D already follows: the newcomer gets an equal share of the enlarged lane
and every pane already there gives up height in proportion to what it had.
Reordering *inside* one lane changes no height at all.

The grip costs the pane 14 × 14 pt of its top-left corner — about two characters
of a terminal's first row — and that is the price of a pane having a handle at
all: a lane is dragged by its header, and a pane has no chrome of its own. A
press on the grip that never moves is a click, and focuses the pane.

### Docking a lane to an edge

**⌃⌘[** and **⌃⌘]** hold a lane at the left or right edge of the window instead
of letting it scroll with the strip — a music player, a chat, anything you want
on screen while you work somewhere else. One lane per edge, two at once; press
the same key again to give the edge back. Every pane in the lane goes with it.

**⌃⌘\\** switches that dock between *inset*, where the strip's viewport narrows
so nothing is hidden behind the dock, and *overlay*, where it floats above the
strip. **⌃⌘=** and **⌃⌘-** resize the dock rather than the lane while it is
docked, and the width is remembered separately from the lane's own — undock it
and it goes back to the width you gave it in the strip.

**⌥⌘[** and **⌥⌘]** move focus into a dock and, pressed again, back out to where
you were. ⌘[ / ⌘] deliberately skip the docks: those keys scroll the strip, and
a docked lane does not scroll.

Drag a dock's **inner** edge to resize it — the outer one is against the wall —
and the lane's ⋯ menu carries the same three actions for the lane under the
pointer rather than the focused one. The header marks a docked lane at the right
of its title: **◀ ▶** when the dock takes its own room, **◁ ▷** when it floats
over the strip.

A window too narrow to hold a dock *and* a readable lane floats the dock instead
of squeezing the strip — two inset docks need about 900 pt between them, and
below that they both float until the window grows again. Nothing is written
down when that happens, so a dock is never permanently narrowed by having once
been opened on a small screen.

A docked lane keeps its place in the strip's order the whole time, so undocking
puts it back exactly where it was — even if lanes were created or closed around
it meanwhile. It is also never evicted and never unparented, whatever memory
does, which is what keeps a docked page playing.

A docked lane is still a lane: **⇧⌘D** splits it, the seam between its panes
drags, its header works, and **⇧⌘[** / **⇧⌘]** walk its stack. ⌘[ / ⌘] pressed
inside a dock return you to the strip lane you were last working in.

**⇧⌘P** is the other half of that: "Keep Lane Loaded" protects a lane's pages
from eviction *without* giving it an edge of the screen, for the long-running
thing you do not need to look at. It used to be called "Pin Lane" —
[ADR-0010](docs/decisions/0010-docking-takes-the-word-pinned.md) is why the word
moved.

A terminal whose process exits takes its lane with it, after a beat.

An empty strip says the same thing, so a fresh launch is not a blank rectangle.

### Dialogs

Every dialog is the same popup: square, centred in the window below its title
bar with the same margin on every side, arriving with a short fade and a rise
of a few points and leaving with a quicker one. ⌘P, ⌘O, ⌘/, ⇧⌘Y, the ⌘D
bookmark editor, and every confirmation, prompt and error close on Esc or a
click back into the strip. A click away from a confirmation is Cancel, and ↩ on
anything destructive is still Cancel. ⌘/ pressed again closes it.

Three exceptions, all on purpose. ⇧⌘Y stays open when you ⌘-Tab to another
app, because a scroll position four hundred rows down is not something to lose
to reading something else. The two import wizards look and move like every other
popup but close only on Esc or their own buttons, so a stray click cannot throw
away an import half chosen. And a web page's sign-in popup closes only on Esc,
its ✕, or its page being done with it — see [A web lane](#a-web-lane).

The memory dashboard is the one floating panel left, because watching it while
the strip scrolls is its whole purpose. File choosers and a web page's own
`alert()` stay the system's, and so does the alert for a ledger that cannot be
opened at launch — there is no window yet to centre anything on.

### The toolbar

A row above the strip, level with the session browser's header so the two read
as one band: a **LANES | GALLERY** switch, **find a lane…** (⌘P), and on the right
the number of running sessions. It is there windowed and full screen alike —
a first version lived in the full-screen title bar, which drew it over an
expanded tile's header and hid it everywhere else. Every control is a key you
already have, so nothing up there is the only way to do anything, and `+ NEW`
is not repeated because the browser's half of the row already has it.

It costs the strip 34 pt, which is the reason the counts first went in a footer.
It is the same 34 pt the browser's header already spends beside it, so the lanes
now start level with the sessions list instead of above it.

### The gallery

**⌘G puts every lane on one screen**, each one a live thumbnail of itself, and
pressed again puts the strip back. Supervising twelve agents on a strip that
shows four means scrolling to find the one that stopped to ask for a `y` —
which is the job the strip exists to make unnecessary. The gallery is the other
answer to the same question: you do not scroll to it, you look.

It is a **layout, not a view you visit**. Whichever of the two was showing comes
back after a quit and after a `kill -9`, and the switch is written to the ledger
before anything on screen moves. It is also the only thing the switch writes: the
gallery is a view over the strip's order, so no lane moves, widens or loses its
place by being looked at this way.

The tiles are as big as they can be with every lane on screen, nothing scrolled
and nothing cropped, and they are recomputed whenever a lane comes, goes or the
window changes size. There are no size controls because there is exactly one
right answer. Lanes run in strip order, left to right, wrapping into rows.

**A tile is the lane, drawn smaller — never a smaller terminal.** A split lane
keeps its panes in their order and their proportions, a spanned lane is a tile
twice as wide, and the `73×53` a session reports does not change when the gallery
opens. That last one is the whole design: a terminal given fewer pixels works out
a new grid, and a new grid is a resize on your phone too
([ADR-0007](docs/decisions/0007-terminal-panes-never-resize-the-pty.md)). So the
real lane is laid out at its real size and only the picture of it is shrunk.
[Spike M5](docs/spikes/05-gallery-scale.md) measured the alternative changing the
grid at thirteen of fourteen sizes, and this one changing it at none.

The text is not meant to be comfortable. It is meant to be **as sharp as the
pixels allow**, so on a Retina panel you can squint and read it, and on any panel
you can tell from its shape that a session wants Enter or Esc. Which of Core
Animation's filters shrinks a terminal is decided by how many device pixels each
point of the lane gets, because that is what the measurements followed.

**Click a tile to type into it.** The keyboard goes to the pane under the
pointer, the orange outline goes around it, and every key without ⌘ — Esc and
Return above all — goes to that pane. Answering a prompt from its thumbnail is
the point, which is why Esc does not leave the gallery. ⌘G does.

**Double-click a tile to expand it in place**, the way Relay TTY does: it grows
from its own spot to the lane's real size, over its neighbours, and slides inward
only as far as the window's edges make it. Nothing is resized — the terminal
keeps its grid, the page keeps its layout — because a tile was always the lane
drawn smaller, and expanding only draws it bigger. Double-click its header, or
click the gallery between tiles, to put it back; expanding another tile puts
the first one back too. Inside an expanded tile a double click selects a word
again, since that tile is big enough to read. The session browser follows the
same gestures while the gallery is up — click to focus, double-click to expand —
and keeps its usual behaviour on the strip. ⌘G is still the way out.

Tiles do not edit the strip: no width handle, no pane grips, no seams to drag, no
header to drag into a new position. The ⋯ menu still works.

A few things behave the way the rest of the strip made them:

- **Docked lanes are ordinary tiles**, at their place in the order, and go back to
  their edge when the gallery closes.
- **Gather has no key.** It narrows the strip, and the gallery, to one project,
  and it was too easy to land in without meaning to — one keystroke, or a double
  click on a lane header. It is in the View menu, and `keys` will bind it for
  anyone who wants it back. ⌘G is the gallery's, both ways; ⌥⌘G is Google Drive's.
- **Pages stay live where memory allows.** Every lane is on screen, so the
  memory policy measures distance from the lane you are working in rather than
  from a scroll position: pages near it are loaded, a page that was evicted shows
  its snapshot until you click it, and under pressure the pages furthest from you
  go first. Opening the gallery on twelve web lanes is not twelve page loads.
- **Every terminal on screen renders.** An idle one costs nothing; many agents
  printing at once cost more here than on the strip, which only draws the lanes
  in view. [ADR-0011](docs/decisions/0011-gallery-layout.md) has the numbers and
  what would change it.

### ⌘-clicking a path

**⌘-click a path or a URL in terminal output** and it opens in a lane right of
the terminal that printed it. Which *kind* of lane depends on what the thing is:
a URL and anything a web pane can already draw — `pdf png jpg jpeg gif svg webp
heic bmp tiff ico mp4 mov m4v webm mp3 wav m4a aac flac ogg`, in any case —
get a web lane. **Everything else gets a terminal lane running your editor**,
at the line the output named: `src/foo.ts:42:10` opens on line 42.

That includes `.html`, `.md` and `.json`, deliberately. A ⌘-click on a path in a
stack trace is a request to look at the file, and the one thing a `WKWebView` on
`file:///…/foo.ts` cannot then do is let you fix the line you were looking at —
which was the old behaviour: unstyled, un-editable, and the `:42` thrown away on
the way in. Nothing here is a guess about a bare word, either; a path is only
clickable if it exists.

The default is `${VISUAL:-${EDITOR:-vi}} +%l -- %f`, read by your login shell —
so the variables that count are the ones your `.zshrc` exports. **They have to
name the program, not an alias:** `EDITOR=vim` beside `alias vim=nvim` opens a
stock `/usr/bin/vim` with none of your neovim config, because an alias is never
expanded out of a variable. `git commit` has always done the same; set
`EDITOR=nvim` and both are right. The `editor` [setting](#settings) replaces the
default, which is how you spell the editors that do not take `+N`:

```toml
editor = "code --goto %f:%l:%c"
# or
editor = "hx %f:%l:%c"
```

`%f` is the path, already quoted; `%l` is the line and `%c` the column, each
**1** when the output carried none, so the template never needs a branch for
"there was no line". Nothing else is substituted — `$VAR` and `${...}` are left
for the shell.

**⌘-clicking the same file again goes back to the editor you already have**,
focusing that lane instead of opening a second one over the same buffer. The
line number is lost when that happens, and that is on purpose: the buffer is
yours, it may have unsaved changes, and typing `:42` into whatever mode the
editor is in is how a click corrupts a file. Once that lane is gone, the next
⌘-click starts fresh.

### From a terminal

Both CLI tools live in the bundle at `Contents/Helpers/`:

```sh
export PATH="$PWD/build/MaxPane.app/Contents/Helpers:$PATH"

maxpane run htop          # a terminal lane running htop
maxpane run               # a terminal lane running your shell
maxpane open google.com   # a web lane
maxpane ls                # what is on the strip
```

`run` takes a command and its arguments as **separate words**, the way `relay`
itself is invoked — not a shell line. There is no shell between you and the
program, so `maxpane run "yes | head"` is a request for a program named
`yes | head`, and it is refused rather than started:

```sh
maxpane run "yes | head"        # refused: not a program
maxpane run zsh -c 'yes | head' # a pipeline — ask for a shell and give it one
maxpane run rg 'alpha|beta'     # fine: the pipe is an argument, not syntax
```

It has to be refused up front, because afterwards nobody can tell. `relay-pty-host`
is listening about 20 ms in, which is where readiness used to be declared — but the
shell inside it does not report "command not found" until it has finished sourcing
your login files, measured here at 355 ms to 1.1 s against 270–370 ms of zsh
startup. So the id came back, a lane was written, and the lane was gone a beat
later with the CLI having already said it worked. Waiting instead would mean
outlasting whatever `.zshrc` happens to cost, on every good `maxpane run htop`.

**⌘O reads the same line and runs it.** The two doors differ, deliberately,
because they are handed different things:

| typed | what it is | what happens |
|---|---|---|
| `maxpane run yes '\|' head` | argv: three words, and you quoted the pipe yourself | `yes` with the literal arguments `\|` and `head` — which is what you asked for |
| `maxpane run "yes \| head"` | argv: one word, and no program has that name | refused, with the `zsh -c` spelling in the message |
| ⌘O, `yes \| head` | one line nothing has interpreted yet | your login shell reads it, and the row says `through zsh` first |

`maxpane run` gets argv — words some other shell has already separated, quoted
and expanded — so reading them a second time would be the double-evaluation bug:
a script's `maxpane run "$editor" "$file"` must open a file called `; rm -rf ~`,
not run one. ⌘O gets one uninterpreted string typed at your own keyboard, and the
only correct reader of a command line is a shell — it reaches `$SHELL -li -c` as
a single argument, exactly as typed, with nothing but a newline and `exit $?`
after it.

What ⌘O used to do was a third thing, worse than either: `split(separator: " ")`,
a shell imitation that got pipelines, quoting and globbing all wrong and said
nothing. `yes | head` became `yes` with the arguments `|` and `head` — a lane
spewing `y` forever rather than an error. A bare `zsh` is still argv, and still
gets `--login`, because a wrapped shell is not the session leader and its lane's
directory tag would freeze.

`maxpane ls` prints one tab-separated line per lane, so it pipes:

```
 0	pty:bc780940	max-pane	untitled
*1	web	-	Google
 ◀	web	-	YouTube Music
```

A docked lane is listed with `◀` or `▶` where the others have a strip position,
because it does not have one.

Terminals Max Pane starts already have `BROWSER` set to the bundled shim, so
anything inside them that opens a URL politely gets a web lane beside the
terminal that asked. For a terminal you started yourself:

```sh
export BROWSER="$PWD/build/MaxPane.app/Contents/Helpers/maxpane-open"
```

### Light and dark

Max Pane follows the Mac's System Settings › Appearance, live. Switch it with the
app open and the whole window crossfades on the lane clock, or cuts if Reduce
Motion is on:

- **Chrome:** lanes, headers, the sidebar, the toolbar, docks, gallery tiles and
  any open popup.
- **Terminals:** they swap Afterglow for Alabaster without resizing or losing
  what is on screen.
- **Web pages:** each page sees the new `prefers-color-scheme`, and its
  `matchMedia` listeners fire, with no reload.

Signal Orange is the same in both.

The `theme` [setting](#settings) overrides the system: `system` (the default),
`light` or `dark`. It is the one key that applies the moment it changes, from
Settings or from a save in a text editor. Every other key is still read at
launch.

An evicted web lane's placeholder picture keeps the appearance it was taken in.
Its frame and caption follow the switch, and the page comes back in the current
appearance when the lane is revisited ([ADR-0006](docs/decisions/0006-placeholder-snapshots.md)).

For anyone adding a view: paint layers with `layerBackgroundColor` /
`layerBorderColor`, not `layer.backgroundColor = x.cgColor`. A `CGColor` is a
snapshot of one appearance. A test fails the build on a hand conversion.

### Settings

**⌘,** (or Max Pane › Settings…, or the gear at the foot of the sidebar) opens
every setting and every key in one window. Each change is written to the config
file the moment you make it, and a save to that file from a text editor shows up
in the window, so neither one is a copy of the other. The file is plain TOML:

| profile | file |
|---|---|
| default | `$XDG_CONFIG_HOME/maxpane/config.toml`, or `~/.config/maxpane/config.toml` when that is unset |
| any other | `…/maxpane/profiles/<name>/config.toml` |

`MAXPANE_CONFIG` names a different file outright. An app opened from the Dock
does not see the `XDG_CONFIG_HOME` your shell exports, so there it is `~/.config`
unless launchd has it set too.

Set only what you want to change. A key the file does not mention keeps its
default, and **default** in the window takes the key out of the file rather than
writing today's value into it, so it goes on following the default.

```toml
# comments are yours, and stay where you put them
theme = "system"
snap_to_lanes = true
lane_default_pt = 656
lane_peek_pt = 28
strip_edge_rails = true
font_name = "JetBrains Mono"
font_size = 13
```

The window writes one value at a time, in place: your comments, the order of
your keys and keys it does not know all survive
([ADR-0012](docs/decisions/0012-in-house-toml-line-editor.md)). **reveal in
finder** shows the file, and **open in editor** opens it in a terminal lane with
your `editor` setting, the same way ⌘-clicking a path does.

`theme` applies at once. Every other key, the keyboard included, applies on the
next launch, and the window marks a changed one `$ relaunch to apply` until then.

A value of the wrong type is skipped and its default used. The window shows
which key was skipped and why, on that key's row. A line it cannot read at all,
or a key that is not a setting (the old JSON spelling `laneDefaultPt`, say), is
listed under the file's path and left exactly as it is.

**Coming from `config.json`:** the first launch that finds no `config.toml`
copies the old file's settings into one and leaves the JSON where it was. It is
not read after that, and the window says so. A value the JSON could not use
either comes across as a comment.

`theme` is `system`, `light` or `dark`. See [Light and dark](#light-and-dark).

`search_url` is where a web pane's address bar sends something that is not an
address — `%s` is the query. A portrait lane has room for one text field, so the
address bar is also the search box; `example.com` navigates, `swift actors`
searches, and the rule for telling them apart is the same one ⌘T uses.

`snap_to_lanes` settles a horizontal scroll with the nearest lane centred, rather
than leaving two lanes half-readable. It is on by default; set it to `false` to
have the scroll stop exactly where the gesture put it. `snap_seconds` (default
`0.18`) is how long that takes.

`lane_default_pt` is the width every new lane is born at. Lanes are uniform on
purpose — pages on a desk are the same size — so this is one number, not a
range, and a lane you have dragged or spanned keeps the width you gave it.
`lane_min_pt` and `lane_max_pt` bound both.

Uniform widths have one failure, and the next two settings are about it: when a
whole number of lanes happens to fit the window, the strip comes to rest flush
with a lane boundary, nothing shows at either edge, and there is no evidence
left on screen that the strip continues at all — a strip of twenty lanes looks
exactly like a strip of three.

`lane_peek_pt` is the smallest sliver of the next lane the strip will settle
with. When centring a lane would leave an edge flush while lanes continue past
it, the settle lands up to this many points off centre instead, so a corner of
the next lane always shows. It never moves further than that, and at the two
ends of the strip it does not move at all — the end of the strip is a fact
worth seeing. `0` turns it off and gives you exactly centred snapping.

`strip_edge_rails` is the other half: an 18 pt column at each end of the strip
with a count of the lanes hidden that way (`◀ 7`, `5 ▶`), and a plain wall when
there are none. A sliver says *there is more, this way*; it cannot say how many,
and at the ends of the strip there is nothing to show a sliver of. `false`
removes both rails and gives their 36 points back to the lanes.

Every field of `Config` is a key here, and every key is a row in the window. A
skipped value also prints a line on stderr.

### Shortcuts

The **Keyboard** section of Settings lists every command, the keys that run it
and the key it ships with. **rec** takes the next chord you press (esc cancels),
**none** unbinds, and **default** gives the shipped key back. You can also type
chords into the field, space-separated.

In the file this is the `[keys]` table, by command name. Whatever you do not
mention keeps the key it ships with:

```toml
[keys]
newTerminalLane = "cmd+n"
openAnything = ["cmd+k", "cmd+t"]
moveLaneLeft = "shift+cmd+left"
closePane = []
```

A value is a chord, a list of chords, or `[]`. With a list, the first is the one
the menu shows and the rest are alternates, which is how ⌘O ships with ⌘T. `[]`
(or `"none"`) unbinds the command outright: it stays in the menu, it stops having
a key, and a web pane stops having that chord taken off it.

A chord is written either way the keyboard is described: `cmd+shift+d` or the
`⇧⌘D` the help sheet prints. Modifiers are `cmd`, `ctrl`, `opt` (or `alt`) and
`shift`; keys with no character of their own have names — `esc`, `tab`, `space`,
`left`, `right`, `up`, `down`, `return`, `delete`. Copying a chord off ⌘/ and
pasting it into this file works, because the sheet and the parser are two halves
of one spelling.

One edit moves all three renderings — the key that fires, the menu item, and
what ⌘/ prints — because they are one value read three times. The sheet always
shows your keys, never the shipped ones.

Four things can be wrong with a keymap, and each costs only itself:

| | |
|---|---|
| a chord that does not parse | the command keeps its default |
| a command name that does not exist | the entry is skipped |
| a chord macOS or the Edit menu owns (⌘Q, ⌘H, ⌘M, ⌘Tab, ⌘space, ⌘X ⌘C ⌘V ⌘A) | refused — it could never have fired |
| two commands on one chord | one of them gets it |

All four show on that command's row in Settings, and print a line on stderr. On the last: a key you set
beats a key that was only a default, so taking ⌘R for `newTerminalLane` is one
edit and `reload` yields it — and if two commands you set both want it, the one
declared first in `Command` keeps it and the other is named in the warning.

The keymap is read once, at launch, which is why a changed key says
`$ relaunch to apply`.


### Profiles

A profile is one instance's whole world: its ledger, its config, its cookie
jars, its control socket, its snapshots. Naming one is how you drive the app to
test it without disturbing the instance someone is working in.

```sh
./build/MaxPane.app/Contents/MacOS/MaxPane --profile test    # or: open build/MaxPane.app --args --profile test
maxpane --profile test ls                                    # ...talks to that instance, never the default one
export MAXPANE_PROFILE=test                                  # ...for a whole shell
```

**No `--profile` means the default profile** — the one you are working in. A
named profile's window says so in the footer and in its title, because two
identical windows is how the wrong instance gets driven.

Everything lives under the name, the default profile included:

| | |
|---|---|
| ledger, socket, snapshots | `~/Library/Application Support/MaxPane/profiles/<name>/` |
| config | `…/maxpane/profiles/<name>/config.toml`, except the default profile's `…/maxpane/config.toml` — see [Settings](#settings) |
| cookie jars | `WKWebsiteDataStore` UUIDs salted with the name |

The default profile's cookie salt is **empty**, and has to stay that way: WebKit
keys the on-disk store by that UUID, so salting the default profile would point
it at new empty stores and every login on the machine would be gone.

Names are letters, digits, `.`, `_` and `-`, up to 32 characters. A bad one is
refused rather than scrubbed — a name quietly rewritten to something valid lands
you back on the live strip, which is the thing you were trying to stay off.

The **CLI and the app must be from the same build.** The socket moved into the
profile directory, so a new `maxpane` cannot see an old running app and vice
versa. Rebuild and relaunch together.

The first launch after this change moves the pre-profiles layout into
`profiles/default/`. The ledger is copied with `sqlite3 .backup` rather than
`cp` — a WAL is not part of the file, and the live one held 4 MB the day this
was written — then lane and pane counts are compared, and only then is the
original set aside as `ledger.db.pre-profiles`. If the counts disagree, nothing
moves and the app says so. It also refuses to start the move while another
instance is still listening on the old socket: renaming a file out from under
SQLite does not fail, it just leaves that instance writing somewhere nothing
reads.

### Debugging

`MAXPANE_CONFIG`, `MAXPANE_LEDGER`, `MAXPANE_SOCKET` and `MAXPANE_DATA_SALT`
still point one path somewhere else, and still win over the profile. They are
for the case where you want exactly one thing moved; `--profile` is for the case
you almost always mean, which is all of them at once.
`MAXPANE_APP=build/mine.app ./scripts/build-app.sh` builds somewhere else; the
script refuses to rebuild a bundle that has a live process, because `rm -rf`-ing
a bundle out from under a running app kills it with no message at all.

`MAXPANE_WINDOWED=1` skips fullscreen and `MAXPANE_DEBUG=1` turns on the chatty
logging. Both write to stderr, which you only see by running the executable
inside the bundle directly rather than through `open`:

```sh
MAXPANE_WINDOWED=1 MAXPANE_DEBUG=1 ./build/MaxPane.app/Contents/MacOS/MaxPane
```

### A note on terminal size

Max Pane never resizes a Relay session — the PTY has one size shared by every
client, including your phone, so claiming it would reshape the terminal for all
of them ([ADR-0007](docs/decisions/0007-terminal-panes-never-resize-the-pty.md)).
It sizes the *lane* to the session instead. **⌃⌘⇧R** claims a session at the
lane's width, and asks first, because that one does affect everyone.
