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
./scripts/test.sh                             # Rust + Swift, everything

source scripts/env.sh
cargo test                                    # unit + durability acceptance tests
cargo test --release --test snapshot_cost -- --nocapture   # the M3 timing split
```

Use `scripts/test.sh` rather than a bare `swift test`: swift-testing ships inside
Command Line Tools but SwiftPM does not look for it there, and the fix is a
framework search path plus two rpaths pointing at two different directories. The
failure without them is a `dlopen` error that names neither.

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
| **⌘T** / **⌘D** | a new lane to the right — pick a command or a URL |
| **⌘[** / **⌘]** | move focus between lanes |
| **⌘P** | find a lane by title, URL or something it printed |

⌘T opens one picker for both halves of the app, because "something goes to the
right of this" is a single decision. It lists what you launched before, most
recent first, each with a number: **⌘4** runs the fourth one. Anything you type
is offered both ways — as a command and as a URL — so a wrong guess about
`localhost:3000` never hides the other reading.

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
```

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

Every field of `Config` is a key here. A value of the wrong type is skipped —
with a line on stderr saying which — rather than taking the rest of the file
down with it.

### Debugging

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
