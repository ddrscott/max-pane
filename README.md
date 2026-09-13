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
the 320 Swift tests are 0.2 s and SwiftPM's own no-op overhead is another 0.4 s.
Nothing in the Swift suite is worth gating — the slowest single test in it is
76 ms. The cost lived on the Rust side, in two timing measurements:

| | before | why it costs |
|---|---|---|
| `rust_side_snapshot_cost` | 0.95 s | builds 300 lanes / 400 panes, then 200 samples |
| `cost_of_a_keystroke` | 0.33 s | fills the ledger to its 5,000-row cap, then 7 queries |

Together that was 1.28 s of a 2.7 s suite — and both print numbers that only
mean anything in a release build, which the default run is not. They are gated
on **`MAXPANE_BENCH`** and `./scripts/test.sh bench` runs them in release, where
the numbers are worth reading.

Render-sheet tests (`LaneHeaderRenderTests`, `OmniPickerRenderTests`) draw views
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
| **⌘O** (also **⌘T**, **⌘D**) | start anything — a command, a URL, a page you have been to, a session that is already running |
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
picker with those scopes already chosen. **⌘⌫** forgets the selected row.

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
