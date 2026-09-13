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
| `cost_of_a_keystroke` | 21 s | builds 112,840 pages — the owner's real corpus size — then 8 queries |

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
`SidebarBookmarkRenderTests`) draw views
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
on**, and 1 ms once the query is distinctive. The first two characters cost
about 60 ms, because a trigram index has nothing to say below three characters
and every row is read — that is the price of the answer being the whole table
rather than the newest fortnight of it, and it is two keystrokes.

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
| a keystroke afterwards | **16–18 ms** from the third character; 183 ms for `com`, which is a substring of most of the corpus |

The keystroke numbers are worse than the 7 ms this README quotes for a *synthetic*
corpus of the same size, and the reason is the corpus rather than the size: real
browsing is full of `com`, `www` and `github`, so a short real needle narrows to
tens of thousands of rows where a generated one narrows to hundreds. 183 ms is
the worst case measured and it is a query nobody stops typing at; from the third
distinctive character it is under 20 ms. The one- and two-character cost is the
known trigram floor and has its own queue item.

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

### The session browser, and which pane has the keyboard

Clicking a session in the left-hand browser scrolls to its lane **and gives it
the keyboard** — the same two things ⌘P does, and in the same order. It used to
only scroll, and flash the lane's border in the focus colour on the way, so the
click looked like it had focused the lane and then silently given up; the first
keystroke went to whatever lane you had left behind. A row for a session that is
not on the strip still attaches it instead.

A row names a *session*, and a lane holds a stack of them, so the click focuses
the pane whose session you clicked rather than whichever pane is on top.

Which is also why a split lane now marks its focused pane: a short Signal Orange
tick at the top-left of that pane, inside the lane's own focus border. One pane
and there is no mark — the border has already said it. Three, and "which of
these gets the next keystroke" is a question with a real answer and, until now,
nothing on screen to give it; a terminal at least blinks a cursor, and a page
looks identical either way.

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

### Preferences

`~/.config/maxpane/config.json`. Set only what you want to change; everything
else keeps its default.

```json
{
  "snapToLanes": true,
  "laneDefaultPt": 656,
  "lanePeekPt": 28,
  "stripEdgeRails": true,
  "fontName": "JetBrains Mono",
  "fontSize": 13
}
```

`searchUrl` is where a web pane's address bar sends something that is not an
address — `%s` is the query. A portrait lane has room for one text field, so the
address bar is also the search box; `example.com` navigates, `swift actors`
searches, and the rule for telling them apart is the same one ⌘T uses.

`snapToLanes` settles a horizontal scroll with the nearest lane centred, rather
than leaving two lanes half-readable. It is on by default; set it to `false` to
have the scroll stop exactly where the gesture put it. `snapSeconds` (default
`0.18`) is how long that takes.

`laneDefaultPt` is the width every new lane is born at. Lanes are uniform on
purpose — pages on a desk are the same size — so this is one number, not a
range, and a lane you have dragged or spanned keeps the width you gave it.
`laneMinPt` and `laneMaxPt` bound both.

Uniform widths have one failure, and the next two settings are about it: when a
whole number of lanes happens to fit the window, the strip comes to rest flush
with a lane boundary, nothing shows at either edge, and there is no evidence
left on screen that the strip continues at all — a strip of twenty lanes looks
exactly like a strip of three.

`lanePeekPt` is the smallest sliver of the next lane the strip will settle
with. When centring a lane would leave an edge flush while lanes continue past
it, the settle lands up to this many points off centre instead, so a corner of
the next lane always shows. It never moves further than that, and at the two
ends of the strip it does not move at all — the end of the strip is a fact
worth seeing. `0` turns it off and gives you exactly centred snapping.

`stripEdgeRails` is the other half: an 18 pt column at each end of the strip
with a count of the lanes hidden that way (`◀ 7`, `5 ▶`), and a plain wall when
there are none. A sliver says *there is more, this way*; it cannot say how many,
and at the ends of the strip there is nothing to show a sliver of. `false`
removes both rails and gives their 36 points back to the lanes.

Every field of `Config` is a key here. A value of the wrong type is skipped —
with a line on stderr saying which — rather than taking the rest of the file
down with it.

### Shortcuts

`keys` moves any of them. The command names are the ones the ⌘/ sheet lists, and
whatever you do not mention keeps the key it ships with:

```json
{
  "keys": {
    "newTerminalLane": "cmd+n",
    "openAnything": ["cmd+k", "cmd+t"],
    "moveLaneLeft": "shift+cmd+left",
    "closePane": null
  }
}
```

A value is a chord, a list of chords, or `null`. With a list, the first is the
one the menu shows and the rest are alternates — which is how ⌘O ships with ⌘T.
`null` unbinds the command outright: it stays in the menu, it stops
having a key, and a web pane stops having that chord taken off it.

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

All four print a line on stderr saying what happened. On the last: a key you set
beats a key that was only a default, so taking ⌘R for `newTerminalLane` is one
edit and `reload` yields it — and if two commands you set both want it, the one
declared first in `Command` keeps it and the other is named in the warning.

The keymap is read once, at launch.


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
| config | `~/.config/maxpane/profiles/<name>/config.json` |
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
