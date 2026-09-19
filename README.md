# Max Pane

Terminals and web pages as columns on one infinite strip. A fullscreen macOS
app for watching several coding agents run while you read what they cite.

![Max Pane: agent sessions and the pages they cite, side by side in portrait lanes](docs/launch/hero.png)

- **Lanes, not windows.** A terminal and a web page are peers. Each is a
  portrait column; wide content scrolls inside the lane, and the lane never
  widens past its max. Lanes never overlap.
- **One lane per agent session.** A sidebar lists every running session and
  says which one is BLOCKED on a prompt. That one is the brightest green, and it
  pulses. Click it and you are there.
- **⌘O starts anything.** A command, a URL, a page you have kept, a session
  that is already running somewhere else. One key, because "something goes to
  the right of this" is a single decision.
- **⌘G is the gallery.** Every lane on one screen, live. ⌘G again goes back.
- **It keeps your things.** History with no limit, pages you star, passwords in
  the Keychain and nowhere else, every setting in a TOML file that keeps your
  comments where you put them.

## Install

Max Pane needs an Apple silicon Mac on macOS 14 or newer, and [relay-tty](https://github.com/ddrscott/relay-tty)
1.22.0 or newer, the daemon that owns the terminal sessions.

With Homebrew, both at once (relay-tty comes in as a dependency):

```sh
brew install --cask ddrscott/tap/max-pane
```

Or by hand:

1. Install relay-tty:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/ddrscott/relay-tty/main/install.sh | bash
   ```

   Or, if you already have Node 18 or newer, `npm i -g relay-tty`.

2. Download the DMG from the [v0.6.0 release](https://github.com/ddrscott/max-pane/releases/tag/v0.6.0),
   drag Max Pane to Applications, and open it.

3. Press **⌘O**, type `claude`, press **↩**. Press **⌘/** for every other
   shortcut.

## Status

**0.6.0.** What it does today is in [CHANGELOG.md](CHANGELOG.md), and nothing
here claims more than that. Built and used daily by one person; bugs go in
[Issues](https://github.com/ddrscott/max-pane/issues).

**Contents:** [Install](#install) · [Using it](#using-it) ·
[Building from source](#building-from-source) · [Layout](#layout) ·
[Toolchain](#toolchain) · [Requirements](#requirements) · [Build](#build) ·
[Test](#test) · [RelayTTY](#relaytty) · [Conventions](#conventions) ·
[License](LICENSE)

---

## Building from source

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

## Requirements

Nothing from RelayTTY is compiled into MaxPane. The app is a third-party client
of a daemon that has to be installed separately, and that is the one thing a
fresh machine needs before the app will start a session:

```sh
curl -fsSL https://raw.githubusercontent.com/ddrscott/relay-tty/main/install.sh | bash
```

Or, with Node 18 or newer already installed, `npm i -g relay-tty`.

**relay-tty 1.22.0 or newer**, which is the release that added agent state.
An older `relay-pty-host` starts sessions fine and never reports BLOCKED, with
nothing anywhere saying why.

At launch the app finds `relay-pty-host` by walking up from wherever `relay`
resolves on your login shell's `PATH` (an npm global, or a source checkout),
then `/usr/local/bin`, then `PATH` itself. When more than one turns up it takes
the newest that has the agent-state classifier. `relayPtyHostPath` in the
config file names one outright and skips the search. Sessions, sockets and
titles all live in `~/.relay-tty`, which the daemon owns and the app only
reads, so a session started from `relay` in a terminal and one started from
⌘O are the same kind of thing.

Building needs the toolchain below. Running the built app needs only an Apple
silicon Mac on macOS 14 or newer, and relay-tty.

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

`gen-bindings.sh` also stages `liblaned_core.a` into `swift/MaxPaneCore/lib/`,
and that directory — never `target/` — is the Swift linker's only search path
for the core. cargo leaves a `.dylib` beside the `.a` in `target/`, ld prefers
the `.dylib`, and an app linked that way loads the core from this checkout by
absolute path at runtime. The next `cargo build` that changes the FFI then
kills every launch of the installed app with a uniffi checksum trap in
`Core.open`. `build-app.sh` refuses to assemble a bundle that links the dylib.

### The app icon

`swift/MaxPane/Resources/AppIcon.icns` is generated, not hand-made. The master
is `AppIcon-source.png` next to it: a full-bleed 1024px square. Run
`./scripts/gen-app-icon.py` after changing the PNG and commit both files. The
script masks the artwork to Apple's squircle on a transparent canvas, because
macOS 26 clips a square icon to its own squircle and paints the glass rim over
the cut, which shows as a pale ring and light corners.

### Passkeys and the provisioning profile

Passkeys (WebAuthn) do not work in a web pane yet, and the reason is not in
this repository. WebKit only answers `navigator.credentials` for a process that
holds `com.apple.developer.web-browser.public-key-credential`, and that key is
a *managed capability*: Apple grants it to a team after reviewing the app as a
web browser, and the grant reaches the bundle as a provisioning profile. A
bundle signed with the key and no profile is killed at launch — exit 137,
before a byte of output, nothing in the unified log — which was measured on
2026-09-16 (`docs/acceptance.md`, "Passkeys and picture-in-picture"). So the
key is **not** in `MaxPane.entitlements`, and never will be; it enters through
the build only when a profile is present.

The plumbing is done and tested. What is **not done**, because it needs the
Account Holder's Apple Developer account and cannot be done from a build box:

1. **File the request.** Signed in as the Account Holder at
   developer.apple.com, open the request form for the *Web Browser Public Key
   Credential* capability (Account → Contact Us → "Request a capability"; the
   form is the one for `com.apple.developer.web-browser.public-key-credential`).
   Apple's published criteria, which Max Pane meets, are worth stating in the
   form: it registers for `http` and `https` (`CFBundleURLTypes` in
   `Info.plist`), it has a URL field on launch (the address in every web lane's
   chrome bar), and it navigates to the typed destination directly. State the
   bundle id (`app.ljs.maxpane`), the team (`DH6NDWAQQ2`) and that
   distribution is Developer ID, not the App Store. Then write
   `docs/decisions/0017-passkeys-capability.md` with the request date, and the
   outcome when it comes — including "denied", if that is what comes back.
2. **Once granted, make the profile.** In Certificates, Identifiers & Profiles:
   the `app.ljs.maxpane` identifier gains the capability under Additional
   Capabilities; then create a *Developer ID Application* provisioning profile
   for that identifier with the Developer ID Application certificate on this
   Mac, download it, and put it at **`packaging/MaxPane.provisionprofile`**
   (git-ignored; it lives on the release Mac only). `MAXPANE_PROVISIONING_PROFILE`
   points somewhere else; set it empty to build without a profile that is there.
3. **Build, and check the two words.** `./scripts/build-app.sh release` prints
   `passkeys: on — profile … (team …, app …, expires …)` and embeds the profile
   as `Contents/embedded.provisionprofile`; `codesign -d --entitlements :-
   build/MaxPane.app` shows the key. `make-dmg.sh` refuses a bundle where the
   key and the embedded profile disagree.
4. **Prove it**, in a throwaway instance (`MAXPANE_APP=build/verify.app`), and
   write the result into `docs/acceptance.md`:
   `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()` is
   `true`, and Register on webauthn.io shows the system passkey sheet. A
   throwaway username, never a real account. If the app is killed at launch
   with the profile in place, the profile does not match the bundle: check the
   team, the identifier and the expiry, which `scripts/entitlements.sh` checks
   too and would have refused had they been readable from the file.

What the scripts do, so the behaviour without a profile is recognisable as
today's: `scripts/entitlements.sh` is asked for the entitlements to sign with,
and answers `off` — the shipped file, byte for byte — when there is no profile,
when the signature is ad-hoc (a managed capability needs a team, so an ad-hoc
build ignores any profile), or when the profile covers a different bundle id
(a throwaway `build/verify.app` is not the app Apple approved). It answers
`on` — the shipped file plus the key and the profile's own
`com.apple.application-identifier` and `com.apple.developer.team-identifier`,
which the kernel matches against the profile — only for a profile that grants
the key, has not expired and names the signing identity's team. A profile that
is present but fails any of those stops the build with the reason, rather than
shipping a build that quietly lacks what was asked for. If Apple declines the
request, nothing changes in the build: the ADR records it, and the paragraph
in [A web lane](#a-web-lane) stays as it is.

## Test

```sh
./scripts/test.sh                # the edit-loop run: Rust + Swift, ~1.5 s
./scripts/test.sh --skip SUITE   # the same, minus one suite (swift test's --skip, passed through)
./scripts/test.sh bench          # the cost tests, in release
./scripts/test.sh shots DIR      # render the header and picker sheets as PNGs
./scripts/test.sh all            # all three
```

Use `scripts/test.sh` rather than a bare `swift test`: swift-testing ships inside
Command Line Tools but SwiftPM does not look for it there, and the fix is a
framework search path plus two rpaths pointing at two different directories. The
failure without them is a `dlopen` error that names neither.

The default run opens with `scripts/tests/entitlements.sh`, a shell test of the
signing decision in `scripts/entitlements.sh` (see [Passkeys and the
provisioning profile](#passkeys-and-the-provisioning-profile)): every branch,
against decoded fixture profiles, in milliseconds. It runs on its own too.

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

The profile is **forced**, not defaulted: the script exports
`MAXPANE_PROFILE=tests` over whatever the shell had, and unsets the four path
overrides (`MAXPANE_SOCKET`, `MAXPANE_LEDGER`, `MAXPANE_CONFIG`,
`MAXPANE_DATA_SALT`) that would otherwise beat it. A shell inside a live Max
Pane pane inherits `MAXPANE_PROFILE=default` and the app's own socket from the
pane that spawned it, and when the script merely defaulted the profile, a run
from there saw the empty default salt, every real-WebKit suite printed
`SKIPPED`, and the run went green having proved less than it said.

The real-WebKit suites — the nine that guard on the profile's salt and serve
real pages to a real `WebPaneController` — are accounted for at the end of every
default run:

```
real-WebKit suites: 9 in the tree, 8 ran, 1 opted out, 0 skipped by the profile guard
      opted out (--skip): WebPrintTests
```

The count of guarded suites comes from the tree, so a new suite joins the line
by carrying the same guard. The one sanctioned way to leave a suite out is
`./scripts/test.sh --skip SUITE`, which passes `swift test`'s own `--skip`
through (a regex over test IDs; `--skip=A --skip B` both work) and lists what it
left out. A suite that skips for any other reason fails the run, because after
the export above the only way the guard can trip is the profile not reaching the
test process, and that is a harness bug, not a result.

`WebPopupDialogTests` is the Swift suite that serves real pages. Two loopback
sites on two ports — two origins to WebKit — stand in for a site and its sign-in
provider, and a real `WebPaneController` drives real `window.open`s: the size in
the features string, the provider's `postMessage` and cookie reaching the
opener, `window.close()` handing the focus back, five opens in a row, a chooser
opened from the popup, a `target=_blank` click. It writes a cookie, so it skips
itself without a named profile. LinkedIn's "Sign in with Google" needs a real
account and is not driven from a test; this suite is its local reproduction.

`WebContentBlockingTests` is the same two-origin setup for the ad blocker,
over a blocker of its own with a one-rule list in a temporary store: a page on
one site asks the other for two images, and the second site's request log —
which is what `LocalSite` keeps for it — has the one no rule matched and not
the other; a `window.open` popup does the same on the opener's list, and the
per-site switch, flipped through the same method the menu calls, lets the
blocked image through on a reload and stops it again on the next. The real
EasyList is a 9 MB download and is not fetched by any test.

`WebNotificationTests` serves one loopback page that uses the Notification API
the way a chat app does, against a `WebNotificationCenter` whose poster is a
recorder — `UNUserNotificationCenter.current()` traps in a process that is not
an app bundle, which the runner is not. It checks the shape a site's feature
detection reads, `permission` going `default` → `denied` after a remembered
BLOCK and `granted` after a remembered ALLOW, each surviving a reload; that Esc
settles `default` and remembers nothing; that macOS is asked exactly once, at
the first grant; that `new Notification()` reaches the recorder with the site's
title and body and the page hears `show`; that a click focuses the pane and
fires the page's `click`; that a repeated `tag` replaces; and that a click on a
banner from a pane that has since closed does nothing. The real banners are
checked by hand: Slack in a lane, the app in the background.

`WebGeolocationTests` serves one loopback page that uses `navigator.geolocation`
the way a map does, against a `WebGeolocationCenter` whose location source is a
stub — a `CLLocationManager` in a process that is not an app bundle has no TCC
identity and a prompt no test can answer. It checks the shape a page reads
(`instanceof Geolocation`), that Esc is `PERMISSION_DENIED` and remembers
nothing, that a remembered BLOCK survives a reload and never reaches the stub,
that two calls during one sheet are one sheet, that ALLOW asks macOS once and
starts the manager only after its yes, that the stub's coordinates reach both
callbacks as `GeolocationPosition`s, that a `maximumAge` the last fix satisfies
is answered without a start, that a watch hears every fix and stops the manager
when cleared, that the page's `timeout` fires code 3, that no fix is code 2,
that a refusal in System Settings or at macOS's prompt is code 1 at once, and
that a pane closing with a watch up leaves nothing waiting. The measurement the
shim rests on — bare WebKit never calling back — was taken by hand with a
throwaway web view and is recorded in `WebGeolocation`'s comment rather than
re-run, because a test that waits seven seconds for nothing proves it slowly.

`WebFullscreenTests` uses the same two-origin setup for full screen: a host page
with a box inside a transformed card and two iframes from the other origin, one
allowed full screen and one not, in a split lane. It checks the box's size
against the web view's, the events and `fullscreenElement` a player reads, the
bars fading and coming back, Esc as a real key event, the embed filling the
pane and the bare one refused, and a popup's page. WebKit's own full screen is
never entered: a recorder script sits in front of the functions the shim keeps
as native, so ⇧ and a second request are checked by the calls that would have
reached WebKit, and `fullscreenState` stays `.notInFullscreen`. YouTube needs the
network and plays ads, so ⤢ on a real video is checked by hand after installing.

`WebPictureInPictureTests` serves one loopback page with a 64×64 h264 `<video>`
and checks what a player's PiP button reads: the preference is set on the pane's
`WKPreferences` and inherited by a popup's, and a loaded video answers
`webkitSupportsPresentationMode('picture-in-picture')` with true, which it did
not before the switch. A bare `WKPreferences` is checked to still default to
off, and the guard to decline rather than raise on a WebKit without the SPI. The
one test that actually enters PiP is behind **`MAXPANE_PIP`**, because it puts
a window on the display: it enters through `evaluateJavaScript` (which WebKit
runs as a user gesture), asks for full screen while PiP is up, checks that
`evict()` declines while the video is in PiP and reclaims the pane once it is
inline again, then closes the lane under a second PiP video and checks the
window went with it and nothing else did.

`RelayTransportTests` stands a Network.framework WebSocket server on a
loopback port in place of relay-tty's `/ws/sessions/:id` bridge and checks
what `WebSocketTransport` puts on the wire and makes of what comes back: a
payload with no length prefix either way, text frames dropped, the PING
cadence and the zombie, and close codes 4001/1008 as final. The transport
itself was measured against a real server through relaytty.com in spike M7
(`docs/spikes/07-m7-remote-relay.md`); the app reaches it through a
`[[servers]]` table (see "Remote servers"). `RemoteRelayTests` stands a raw
TCP fake of relay-tty's HTTP and `/ws/events` on one loopback port for the
session source, and its last suite runs the whole path against a real server
when `MAXPANE_REMOTE_VERIFY` names one (with `MAXPANE_REMOTE_TOKEN`, read at
run time), printing `SKIPPED` otherwise.

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
| **⇧⌘↩** | Maximize Pane: the focused pane over the whole visible strip; ⇧⌘↩ again puts it back |
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
⌘L, zoom, ⇧⌘L — do nothing. A question the popup's page asks is drawn inside
the dialog, a download lands in the opener's download bar, and a link it opens
in a new tab gets a lane. Nothing about a popup is saved, so a relaunch does not
bring one back. See [ADR-0013](docs/decisions/0013-web-popups-are-dialogs.md).

**Full screen fills the pane; ⇧ for the display.** A video's ⤢, or anything
else a page asks to show full screen, fills this pane's whole web area. The
chrome bar, and the find and download bars if they are open, fade out of its
way, while the lane header, the strip and the lanes beside it stay exactly
where they are. A player embedded from another site fills the pane too, when
the page around it allows that player full screen. Esc or the player's own
control puts it back. So do ⌘L, ⌘F and the ★, which need the bar it is covering,
and so does following a link or reloading. Ask again while it fills the pane,
or hold ⇧ on the click, and the page gets macOS's own full screen across the
display; Esc from there returns it to normal. In a sign-in popup it fills the
dialog's page and the origin bar stays, and the first Esc leaves full screen
before a second one closes the dialog. See
[ADR-0014](docs/decisions/0014-web-full-screen-fills-the-pane.md).

**Picture-in-picture** is on: the glyph in a video's native controls, and
YouTube's and Vimeo's own buttons, which sit on the same
`webkitSupportsPresentationMode('picture-in-picture')`. WebKit has it off on
macOS unless the embedder says otherwise, and the switch is private — the
public `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback` is
iOS-only — so `WebPaneController.enablePictureInPicture` sets it the way
WebKit's own MiniBrowser does, through KVC on `WKPreferences` with the key
**`allowsPictureInPictureMediaPlayback`** (`WebPaneController.pictureInPictureKey`;
KVC finds the `_setAllowsPictureInPictureMediaPlayback:` setter). The setter is
looked for before the call, so a macOS that renames it costs the glyph and a
debug log line, not the app; `WebPictureInPictureTests` fails the day that
happens. Not a problem for the App Store because this is not on it: Developer
ID and a DMG. The PiP window is the page's — destroying the web view closes it
— so a pane whose video is in PiP is not evicted (ADR-0003) until the video is
back inline; the page says which through `WebPictureInPicture`. Closing the lane
still closes the window, as the page goes with the lane.

**Passkeys are not available in a pane.** A site's "sign in with a passkey"
gets `NotAllowedError` at once, no sheet, no QR code, and
`isUserVerifyingPlatformAuthenticatorAvailable()` says `false`, so a well-built
site offers a password instead. WebKit reserves WebAuthn for apps holding
Apple's web-browser public-key-credential capability, which Apple grants to a
team on request and delivers as a provisioning profile; without the profile the
entitlement kills the app at launch. The build carries the profile the day one
exists — [Passkeys and the provisioning
profile](#passkeys-and-the-provisioning-profile) says what to ask Apple for —
and until then a passkey site wants a password or another device's browser.

**Mobile Layout**, in the lane's `⋯` menu and the View menu, asks the site for
its phone page. A portrait lane is a phone's shape, and a site that draws one
layout per device — Discord, in a 656 pt column, with its sidebars folded over
the channel — is cramped in it while its phone layout was drawn for exactly
that width. On, the pane tells sites it is an iPhone (the same Safari version,
`MaxPane/` still last) and reloads; every page in the lane goes together, the
item is ticked while they are on it, and it is greyed out on a terminal lane.
Off puts the desktop string back, exactly, and reloads again. It is per pane
and kept in the ledger, so the lane comes back the way you left it. WebKit's
own mobile content mode is asked for on every navigation too, but measured on
a Mac it changes nothing a page can see — a page with no viewport still lays
out at the lane's width, not a phone's 980 — so what you get is what a site
serves to that user agent, which is what the ones that matter decide on. No
key by default; `keys` binds `toggleMobileLayout`.

**Pinch to zoom.** A trackpad pinch over a page is the same zoom as ⌘= and
⌘-, not a second one: the page reflows under your fingers as it does in
Safari, and when they lift it settles, on the pane's usual 0.16 s, onto the
nearest rung of the ladder the keys climb (50% to 300%) and is written to the
ledger like a keypress — so a pinched zoom survives a relaunch, ⌘0 puts it
back, and ⌘= afterwards steps from a rung rather than from 137%. The readout
in the chrome bar follows the fingers. A two-finger double tap goes to 150%
from actual size and back to 100% from anywhere else. WebKit's own pinch
would have scaled the drawing without laying the page out again, which in a
420 pt column is the opposite of what zooming is for; a popup, which has no
zoom to keep, gets that one. A pinch never pages the strip: the strip takes
sideways *scrolls*, and a pinch is a different gesture.

**Ads and trackers are blocked**, in every web pane and in the popups over
them, by WebKit's own content blocker: a rule list compiled once into bytecode
the network process runs on every request, with no script in the page and no
work per load. The list comes from `blocking_list_url` — WebKit
content-blocker JSON, the format a Safari content blocker ships — and is
compiled into the profile's rule-list store under Application Support, which
is the cache: the next launch looks the compiled list up by name and only
fetches again when the cache is missing, was built from another source, or is
a day old. A first launch with nothing cached opens its window at once and
adds the list to every open page when the compile lands; when the network is
down, the last compiled list stays. WebKit refuses a list past 150 000 rules
with an error that does not say so, so a bigger source is cut into several
lists, each carrying every exception rule, since an exception only reaches the
rules before it in its own list. The rule count and compile time are on the
debug log.

**Block Ads on This Site**, in the lane's `⋯` menu and the Navigate menu,
switches the blocker off for the site the page is on — by registrable domain,
so `youtube.com` covers `www.` and `m.` — and reloads. It is a decision like a
camera grant and is kept in the ledger, so a throwaway profile starts blocking
everywhere. On such a site the chrome bar wears an outlined `unblocked` chip
beside the address, which fades in and out with the rest of the row; a click
on it turns blocking back on. The tick in the menu means *blocking*, so the
common state reads as a tick and the exception as its absence; the item is
greyed out on a terminal lane and when `blocking = false` has turned the
blocker off everywhere. A popup follows its opener's site, because WebKit
keeps the opener's `WKUserContentController` for the popup's view. No key by
default; `keys` binds `toggleBlocking`.

**Print, and Save as PDF.** ⌃⌘P, or File › Print…, runs the system print
panel over the pane as a sheet — the standard one, whose PDF menu already has
Save as PDF, so the print key is also the everyday PDF key. It is ⌃⌘P rather
than ⌘P because ⌘P is the palette here and the keymap refuses two commands on
one chord; `keys` moves it. The page is fitted to the paper's width, and a
receipt in a sign-in popup prints from inside the popup. **Save as PDF…**, also
under File, is for the whole page in one file: a save panel named after the
page in `~/Downloads`, WebKit's own PDF of every fold rather than the one on
screen, and the result lands as a finished row in the pane's download bar, so it
appears where a download would and a click shows it in the Finder. Both are
greyed out on a terminal lane. Save as PDF ships without a key; `keys` binds
`savePDF`.

**Web notifications.** WebKit has no `window.Notification` on macOS, so Slack,
Gmail, Linear and every chat app in a pane could neither ask nor notify, and
their own feature detection turned the feature off without a word. The API is
the app's: a script in every frame of every page defines `Notification` before
the page runs, and the pane is the notification centre behind it. A site's
`requestPermission()` is the same question the camera asks — `example.com
WANTS TO SEND NOTIFICATIONS`, drawn in the pane, BLOCK or ALLOW, with a box to
remember the answer for that site in that cookie jar — and a remembered answer
is written into the script for the next page, since `Notification.permission`
is a read the page makes with no chance to ask back. Esc is *not now*: the
page's promise settles `default` and it may ask again on a later click. A
granted `new Notification()` goes through macOS's Notification Center with the
site's title, body and icon (fetched with a short deadline and dropped if it
is late), shows as a banner even while the app is in front, and a click on it
brings the app, the lane and the pane forward and fires the page's `click`;
`show`, `close` and `error` arrive as they do in a browser, a repeated `tag`
replaces the banner rather than stacking, and `close()` takes it down. Nothing
is posted for the pane you are looking at — the focused pane in the key window
of the active app — because a banner about the thing under the pointer is
noise; the page still hears `show` and `close`. macOS itself is asked whether
the app may notify the first time a site is allowed, not at launch. Two limits,
on purpose: only a page that is alive can notify, so a pane the memory policy
has evicted is quiet until it is back on screen and reloaded; and a service
worker's `showNotification` is not supported, so a site that notifies only
from its worker — with no page open — will not. A popup's page asks in its
dialog and notifies as its opener.

**Where you are.** `navigator.geolocation` is the same story one step on:
WebKit on macOS never answers a page's `getCurrentPosition` at all — not
denied, not a timeout; the page's spinner simply never stops — because it has
no public way for an app to grant it, and a grant to the app in System Settings
changes nothing about that. So the API is the app's too: a script in every
frame stands in for `navigator.geolocation`, built on WebKit's own
`Geolocation` and `GeolocationPosition` types so a page cannot tell, and the
pane is the location provider behind it. A site's first call is the camera's
question — `maps.example WANTS TO KNOW WHERE YOU ARE`, drawn in the pane, BLOCK
or ALLOW, with the box to remember it for that site in that cookie jar — and
two calls while the sheet is up are one sheet. Only a yes reaches CoreLocation,
which is when macOS asks about Max Pane itself, once, with the words in
`Info.plist`; a no from you or from System Settings is `PERMISSION_DENIED` to
the page at once rather than a wait, and Esc is *not now*, the same code with
nothing remembered. One location manager serves every lane: a fix goes to
every request and every `watchPosition` that is waiting, the manager stops
when nothing is, and a fix young enough for a page's `maximumAge` is answered
without starting it. A page's `timeout` runs from the yes, as the spec has it.
A popup's page asks in its dialog.

The default list is Adblock Plus's published WebKit conversion of EasyList,
which is the one maintained conversion of a list people actually use that is
served in this format; EasyPrivacy has none, and a converter from the ABP
filter syntax is a project of its own. `blocking_list_url` takes more than one
URL, separated by spaces, and joins them.

A load that fails says so where the address was — `⚠ server not found —
example.com`, for five seconds — and takes the hairline down with it. Stopping a
load with ✕ and starting a download are not failures and say nothing. Plain
`http://` loads, with an amber **⚠** before the address; the loopback gets no
warning, because `localhost:3000` twenty times a day is how a warning stops
being read.

A page with no `<title>` gets its host and path on the lane header rather than
keeping the last page's title — `localhost:3000/api/users`, which is what tells
six columns of raw JSON apart.

### A private lane

**⇧⌘N** opens a private web lane: a blank page, cursor in the address, marked
`PRIVATE` on its header, its chrome bar and its ⌘P rows. Its pages live in a
`WKWebsiteDataStore` that is never written to disk — one per private lane,
shared by every pane in it and by every lane a ⌘-click from it opens, and
dropped when the last of them closes. Nothing about them is kept: no visit
reaches history, no title correction, no session blob, and ⇧⌘L is greyed out
while ⌥⌘L still fills a saved password. A relaunch never brings a private lane
back, and quitting with one up, or a `kill -9`, is the same case: the ledger
deletes it at the next open.

It is for "log in to the other account once, then forget it", which used to
need a whole profile. It is not a profile: a profile is an instance with its
own ledger and its own persistent jars, chosen at launch and kept forever; a
private lane is one column, gone on close. While it stands it is a lane like
any other — placed, docked, gathered, evicted and rehydrated by the same code —
because the strip draws only what the ledger holds. How that squares with
"recorded nowhere" is [ADR-0016](docs/decisions/0016-private-lanes-live-in-the-ledger-until-open.md).

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

The **★** in a page's chrome bar keeps the page in the focused lane, and
lights. Clicking it on a page already kept opens the same little panel on it.
The panel is where the name and the folder are — nothing on it is a commit
button, because the page was kept the moment you clicked; **Remove** is the
undo, and it is there because *"I meant the other button"* is the other thing
that happens a second after a click.

There is no key for it. ⌘D is Split Right in every pane, page or terminal,
because a page is found again by ⌘Y and a search far more often than by a
bookmark. **Keep This Page…** is in the Navigate menu for anyone who wants to
bind it through `keys`.

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

**Green means the agent is actually working, and nothing else.** The rate on a
row, a lane header or a ⌘P row is green only while the session's state is
WORKING; otherwise it reads a dim `idle`, with no trickle numbers. That state is
derived once, in `AgentState.derived`, and every surface reads it — sidebar rows
and chips, lane headers, gallery tiles, ⌘P and the status bar's `N working`:

1. Relay's **BLOCKED** wins, whatever the title says — a permission prompt is
   the one thing that must never be hidden. So does **EXITED**.
2. A title that starts with Claude Code's spinner (`◐ ◓ ◑ ◒`) is **WORKING**,
   even when relay's file says `idle`.
3. A title that starts with `✳` is **idle** (or DONE, if relay says so).
4. Anything else — no recognised glyph, any other program — keeps relay's state.

**DONE is the app's verdict, not relay's.** pty-host's DONE exists only while
no client is attached — `(Working, 0 clients) → Done`, `(Done, >0 clients) →
Idle` — and a lane is a client, so for anything on the strip the file goes
WORKING → idle with nothing between, and the chip never showed. The registry
now notices the finish itself: a session whose shown state was WORKING and
whose file now says idle is DONE, and stays DONE until you focus its pane (a
click, the sidebar, ⌘P, the keyboard) or `doneHoldSeconds` runs out, thirty
minutes by default and never when set to 0. Merely having the lane on screen
does not clear it, because in the gallery every lane is on screen. Working
again, a prompt, or an exit clears it at once. Claude Code's title makes this
sharp: the spinner becomes `✳` on the turn's last frame, not between tool
calls, so there is nothing to debounce. A session that becomes DONE or BLOCKED
while the app is not in front bounces the Dock icon once.

Relay alone was not enough. Its rate, `bps1`, is a sixty-second average, and its
WORKING rule is that same rate, so the redraw every session does when a
relaunch reattaches it read as a minute of work on every idle agent. It has
also filed a session that was visibly working as `idle`. Claude Code's title
matched real activity for every Claude session measured. Separately, the
registry used to keep the larger of the old and new rate "because the wire is
fresher" — but nothing fed it from the wire, so an agent's peak rate stayed
green forever. Each session file now replaces the reading before it. What relay
could change to make the title rule unnecessary is in
[docs/proposals/relay-agent-state.md](docs/proposals/relay-agent-state.md).

**The green outline is around the pane with the keyboard, never the lane.** It
used to go around the whole column, with a short tick marking the pane inside —
which meant a two-pane lane outlined in the accent with the keystrokes going to the
pane at the bottom, and the tick the only thing on screen that disagreed. "Which
of these gets the next keystroke" has a real answer in a split lane, a terminal
only blinks a cursor, and a page looks identical either way.

The rule has no exceptions, including a lane of one pane: the outline stops
below the header, because the header is never where a keystroke goes. The
focused lane's header is lifted a shade instead, which is what still says
*which column* from across the strip. The lane's own border stays a neutral
hairline, and flashes green only for the ⌘P jump, which is a place to look
rather than a place to type.

### Folding a group puts its lanes away

Folding a directory in the sidebar, a server's directory, or a whole section
(`// LOCAL`, `// NAME`) means *I am not working on this right now*: its lanes
leave the strip and the gallery, and opening it brings them back where they
were, same order, same widths. With three projects and a remote server on one
strip, this is how the strip gets back to the lanes that matter this hour.

**Hidden is not closed.** Nothing is written to a lane or sent to a session.
The agents run on, the terminals stay attached and the pages stay loaded, so
coming back rebuilds nothing; a hidden page is treated by the memory policy as
a lane a long way off, first to be evicted under pressure and reloaded when it
is back. The folds and the hidden lanes are in the ledger, so a relaunch comes
back the same way.

**You can always tell.** A folded header that is holding lanes reads
`3 LANES HIDDEN`, grey and at rest, and when an agent under it is BLOCKED it
says `1 BLOCKED` beside that in the blocked green, breathing like every other
BLOCKED. The status bar reads `4 lanes · 3 hidden`, and its `N BLOCKED` and the
sidebar footer's count every session, folded or not. An empty strip that is
empty because everything is folded says that instead of offering to start
something.

**Which lanes.** The ones whose rows are under the header. A terminal files
under its session's directory, a web lane under its project tag beside the
agent that opened it. A split lane with panes in two groups goes only when
both are folded. An untagged web lane (`-` in `maxpane ls`, the `Web` group)
is never hidden, and neither is a docked lane: folding `Web` folds its rows,
as it always did. Folding the bookmarks section has nothing to do with any of
this. A page an agent in a hidden lane opens (`open`, through the shim) is not
hidden with it: it lands at the end of the strip, untagged, where you will see
it, because a page an agent opens is often one it needs you for.

**Reaching a hidden lane opens its group, and then you are there.** ⌘P, a
session picked in ⌘O, `maxpane attach`, a click on `N ASKING`, and a click on
`N BLOCKED` in the status bar — which goes to the next blocked agent with a
lane — all do it. So does focus arriving by any other road: the lane with the
keyboard is never hidden behind your back, so if the terminal you are typing
in does `cd` into a folded project, the project opens. Folding the group you
are *in* is the one thing that takes the focused lane away, and the keyboard
goes to the nearest lane still on the strip, to the right first, then the left
— the rule closing a lane follows.

Lanes leave and return by the strip's own column close and open, and the lane
you are in holds still while they do, wherever on the strip the folded project
was. In the gallery the tiles slide to their new places. Under Reduce Motion
everything lands at once.

`sidebar_collapse_hides_lanes = false` makes a fold what it was before: the
sidebar's rows fold and the strip is left alone. It applies as you save it.
Why the hidden lanes sit beside the gather filter rather than inside it is
[ADR-0024](docs/decisions/0024-a-folded-sidebar-group-hides-its-lanes.md).

### Moving a pane or a lane

**Drag a lane by its header** — anywhere on it except the `⋯` and the
`s | m | xl` switch — and hover over another pane. The half of that pane the
lane will take lights up:

- **its top or bottom**: the lane joins that pane's stack, above or below it. A
  lane of several panes goes in whole, in its own order.
- **its left or right**: the lane moves beside that pane's lane, as a column of
  its own. Past either end of the strip means that end.

Each pane is cut along its own diagonals, so the edge you are nearest is the
edge that lights, whatever shape the pane is — a whole-height column and a short
pane in a stack of four both give each edge a quarter of their area. The header
counts as the top of its lane's first pane, and a seam as the top of the pane
below it. A press that moves less than 4 pt is still a click.

**The gallery takes the same gesture**, and it is where it matters most: every
lane is on screen at once, so any lane can go into any other without scrolling
to find it. A tile's own edges are the targets; the gap between two tiles is not
a place. An expanded tile takes the pointer over the tiles it covers.

**Drag one pane out of a stack by its grip**, the three rules at the top-left of
each pane in a lane that holds more than one. The same four edges apply, so it
can go into another stack, to another place in its own, or out beside any lane
into a column of its own. Which is ⇧⌘D and ⌘D in the other direction, by hand.

Nothing slides while you drag. The half that lights is the answer, and the strip
moves once, on the drop: a pane changing stack mid-gesture would resize a live
terminal on every frame, which is a grid change per frame for a phone attached to
the same session (ADR-0007). A drop that would leave everything where it is
lights nothing and does nothing — including a lane onto itself, and a lane's only
pane onto its own lane, which would otherwise dissolve the lane and put the pane
into the column it had just destroyed.

**One level of nesting, still.** Lanes hold panes and panes hold nothing, so
above and below a pane is always its lane's stack and beside it is always the
strip. There is no drop that could make a tree, because there is no third place
to put anything.

A lane left with no panes goes with the pane that left it, for the reason ⌘W
already deletes one: an empty column is not a thing you can do anything with.
And a lane that was *only* that pane is **moved** rather than rebuilt, so the
width you dragged it to, its title, its tag and ⇧⌘P come with it — a lane of one
dropped between two lanes is ⌘⇧→ with a mouse, and the only difference is where
the pointer was.

A pane joining another lane takes the mean of that stack's heights, which is the
rule ⇧⌘D already follows: the newcomer gets an equal share of the enlarged lane
and every pane already there gives up height in proportion to what it had.
Reordering *inside* one lane changes no height at all. A lane of several panes
takes one mean share per pane between them and keeps its own split inside that,
so a 3:1 pair arrives as a 3:1 pair rather than being flattened on the way in.

A docked lane can be dragged by its header too. Dropped beside a lane, it leaves
its edge and takes that place in the strip; dropped into a stack, its panes join
it and the dock is gone with the lane.

The grip costs a stacked pane 14 × 14 pt of its top-left corner — about two
characters of a terminal's first row — because a pane has no chrome of its own
and the header picks up the whole lane. A lane of one pane has no grip, since
its header already is that pane's handle, and the corner goes back to the
terminal. A press on the grip that never moves is a click, and focuses the pane.

### Lane sizes

Every lane header carries a square **`s | m | xl`** switch, the current size lit
in the accent green, whenever the header has room for it. Every lane's `⋯` menu
(right-click on the header opens the same one) **always** lists **Small**,
**Medium** and **Extra Large**, ticked at the current size and ticked nowhere when
the lane is off all three. That holds however narrow the lane is and whether or
not it is docked, so the lanes where the switch gives way still have a way to
pick. The same three are **View › Lane Size: Small / Medium / Extra Large**.

**⌘\\** cycles the focused lane **s → m → xl → s**. A lane that is off every
size (dragged, zoomed, or left wide by the old Span Lane) goes to **m** on the
first press. It is `laneSizeCycle` in `[keys]` and in the ⌘/ sheet. The three
sizes have no keys of their own; bind `laneSizeSmall`, `laneSizeMedium` and
`laneSizeLarge` if you want some. The sizes are absolute, the same for every
lane:

- **m** is `lane_default_pt` (656 pt) at 100%: 80 columns of 13 pt text.
- **s** keeps **m**'s columns and draws them at 60% text. The width is computed
  from the terminal's real cell, which is a whole number of pixels, so it holds
  exactly those columns and not one more. That comes to 412 pt on a 1× panel and
  372 pt on Retina. A lane of pages alone goes to 60% of **m**'s width at the zoom
  that leaves the page's `innerWidth` where it was, so the page lays out as it did
  at **m**, only smaller. `s` may be narrower than `lane_min_pt`, because the
  preset is the point. Dragging a lane still stops at the minimum.
- **xl** is double wide (span 2) at 100%. A terminal gets the columns the wider
  lane holds.

A split lane applies the size to every pane in it. None of the three is lit when
you have dragged or zoomed the lane off them all. The lit size is worked out from
the lane's width, span and zoom, which the ledger already keeps, so it survives a
relaunch without a second copy that could disagree.

Changing size eases the lane's width on the strip's usual 0.22 s, with the text
or page zoom easing along with it, and lands at once under Reduce Motion. A
terminal keeps its columns while the lane moves. It is drawn scaling toward its
new text size, and reflows once when the lane arrives. The session is told the
new size once, and only if it changed: going **m → s** keeps every column but
fits more rows into the same height, and **s → m** gives them back.

**A docked lane** takes the sizes on its dock's width, and eases there the same
way. A dock is bounded at 240 to 900 pt, so a size outside that is clamped:
**xl** on a dock is 900 pt at 100%, not 1312. With the default config, **s** and
**m** fit as they are. The tick follows the width the dock really has. The lane's
own strip width and span are left alone, so undocking gives it back at the size
it had on the strip.

On a gallery tile the switch is hidden and the menu's sizes are greyed out,
because the gallery changes nothing but the layout and focus.

**Span Lane (2× Width) is gone**, from the lane menu, the View menu and the ⌘/
sheet. It made a lane 1800 pt wide, and **xl** makes it 1312: two ways to make a
lane wide, at two different widths, and the menu offered both. A lane you spanned
with it still loads at its width, with no size ticked, and ⌘\\ takes it to **m**.
A `toggleSpan` line left in `[keys]` is reported as a command that does not
exist.

### Maximizing a pane

**⇧⌘↩** gives the focused pane the whole visible strip, and **⇧⌘↩** again puts it
back exactly where it was. It is iTerm's Maximize Active Pane: a long diff, a wide
log or a dense page for a minute, without dragging a lane or cycling it to **xl**
and back. It is **View › Maximize Pane**, which reads **Restore Pane** while one is
up, and `toggleMaximizePane` in `[keys]` and the ⌘/ sheet.

The unit is the *pane*, not the lane: in a split lane only the focused pane
rises, and the panes it was stacked with keep their heights. It fills the strip's
visible window. The sidebar, both docks, the toolbar and the status bar stay
where they are and stay usable. A row across the top carries the lane's title and
a green `MAXIMIZED` chip with the key beside it; clicking the chip restores too.

Nothing about the lane changes and nothing is written. The lane keeps its width,
the `s | m | xl` switch does not move, the strip underneath keeps its scroll
offset, and a relaunch comes back with every pane in its lane. The pane's view is
lifted over the strip and a placeholder holds its slot, so "exactly where it was"
is true because that place was never given to anything else
([ADR-0019](docs/decisions/0019-maximize-pane-is-an-overlay.md)).

It eases out of the pane's own rect on the strip's 0.22 s and back into it, and
lands at once under Reduce Motion. A page lays out at the new width, with its
address bar, find bar and downloads bar. A terminal gets the columns the window
holds, and the session is told one size going up and one coming down, never one
per frame. A page that asks for full screen while maximized fills the maximized
pane, and leaving full screen leaves it maximized.

**A docked lane's pane** maximizes into the same window, the strip's and not the
dock's. Its dock stays at the wall with `maximized` in the slot.

**What puts it back without the key** is one rule: anything that moves focus off
the pane, or changes the shape of the strip, restores first. So ⌘[ ⌘] ⇧⌘[ ⇧⌘]
restore and then go where they say; a lane arriving from ⌘O restores (the picker
on its own does not, and Esc from it leaves the pane up); ⌘W closes the pane and
the overlay fades with it; a split, a dock, a lane resize, a move or a gather
restores; and ⌘G restores and then changes the layout, in either direction. A
session in a covered
lane that goes BLOCKED still shows in the sidebar, and clicking its row restores
and then goes to it. Zoom, reload, find, a navigation or a new title leave the
pane up. **Esc never restores**, because a terminal always has a use for Esc.

**In the gallery too.** ⇧⌘↩ maximizes the focused pane from a tile and from an
expanded tile, and there it fills the whole gallery: a dock is an ordinary tile in
that view, so there is no wall to stay clear of. The same key puts the pane back
in its tile, and an expanded tile is still expanded. A double click grows a tile
to the size of its lane; this is the step past that, to the size of the window. A
terminal in a tile is held at its strip size and drawn small, so it lets go of
that hold on the way up and the gallery takes it again on the way down, which is
one resize each way, the same as on the strip.

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
of a few points and leaving with a quicker one. ⌘P, ⌘O, ⌘/, ⇧⌘Y, the ★'s
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
as one band: a two-icon layout switch, **find a lane…** (⌘P), and on the right
the number of running sessions. The switch is pictures rather than words —
Lucide `columns-3` for the lanes and `layout-grid` for the gallery, the lit half
green — with the names in their tooltips (*Lanes (⌘G)*, *Gallery (⌘G)*) and
accessibility labels. It is there windowed and full screen alike —
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

**The switch is a motion, both ways.** Going in, every tile eases out of the place
its lane had on the strip, so the lane you were in is the tile your eye is already
on. A lane that was off screen comes in from its own side, from just past the
window's edge. Coming out, every lane eases out of its tile to its place on the
strip, and the ones bound for beyond the window slide out through its edge. It is
the strip's 0.22 s on the same ease-out, no lane changes size for the effect, and
under Reduce Motion the layouts simply change.

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
keeps its panes in their order and their proportions, an xl lane is a tile
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
pointer, the green outline goes around it, and every key without ⌘ — Esc and
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

Unexpanded tiles do not resize anything: no width handle and no seams to drag,
and no pane grips, which would be four points square at a tile's scale. **An
expanded tile's seams are the strip's**: drag the separator between two stacked
panes and their heights change exactly as they would on the strip, with one
ledger write on the drop, so leaving the gallery shows the panes where you left
them. The grips come back with it. If a lane is taller than the gallery and its
expanded tile is drawn below half size, the handles stay hidden rather than
become targets too small to hit. **Tiles do rearrange the strip.** Drag a tile's header onto the edge of a pane in another tile and it
lands there exactly as it would on the strip — see *Moving a pane or a lane*.
The ⋯ menu still works.

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

### Selecting and copying in a terminal

**Selecting text in a terminal does not copy it.** A highlight made by accident
leaves the clipboard exactly as it was. **⌘C**, Edit › Copy and the right-click
**Copy** item copy the selection. `copy_on_select = true` brings back copying on
every selection; see [Settings](#settings).

### The cursor

**Only the terminal that has the keyboard blinks its cursor.** Every other
terminal, on the strip, in a dock, in a gallery tile or behind a maximized pane,
shows Ghostty's unfocused cursor: hollow and still. With the keyboard somewhere
that is not a terminal (a web pane, a find bar, ⌘O, the sidebar's filter), or
with Settings, History or another app in front, nothing blinks, and the focused
terminal resumes when the keyboard comes back to it. `cursor_blink` changes
this; see [Settings](#settings).

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
maxpane server add NAME URL   # a remote relay-tty server, from its startup Auth URL; see "Remote servers"
maxpane server ls             # the configured servers, their colour and how they are doing
maxpane server color WSL violet   # the colour a server is known by: slate cyan blue violet magenta rose lemon ink
```

**Driving it without the screen.** The control socket reaches remote servers
too, which matters when the Mac is locked and you are talking to it over Relay
TTY:

```sh
maxpane sessions                  # every session, here and on each server
maxpane attach yorkshire:0368d543 # a running session becomes a lane
maxpane run @yorkshire claude     # start something there, as a lane here
maxpane ls                        # a remote lane reads pty:yorkshire:0368d543
```

`run @NAME` is ⌘O's grammar. It answers before the server does, so the lane
turns up in `maxpane ls` a moment later rather than in the reply.

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

### Remote servers

A relay-tty server on another machine can be a source of lanes: its sessions
appear in the sidebar and in ⌘O beside the local ones, and one of them attaches
as an ordinary terminal lane — the same libghostty rendering, resize, replay,
BLOCKED, DONE and reconnect as a local session — over a WebSocket to that
server's `/ws/sessions/:id` instead of the Unix socket. And you can start
things there: ⌘O, ⌘T and ⌘D beside a remote lane run on that lane's server.
Phases 1 to 3 of
[`docs/plans/remote-relay-servers.md`](docs/plans/remote-relay-servers.md);
[ADR-0020](docs/decisions/0020-a-session-belongs-to-a-server.md) says how a
session is identified once there is more than one server,
[ADR-0021](docs/decisions/0021-servers-are-a-pasted-url-and-a-keychain-item.md)
why a server is added by pasting one line and where its token lives, and
[ADR-0022](docs/decisions/0022-a-remote-spawn-sends-the-wrapper-and-the-cwd-is-the-root.md)
what a remote spawn sends and why,
[ADR-0023](docs/decisions/0023-one-truth-per-server-and-the-server-chip.md)
what happens when its server goes quiet, and
[ADR-0025](docs/decisions/0025-a-server-has-a-colour.md) how a remote session
is marked: by its server's colour.

**Adding one.** The server prints an auth URL when it starts:

```
Auth URL (1y): https://<slug>.relaytty.com/api/auth/callback?token=…
```

Open Settings (⌘,) › Servers and paste that line — the whole line, colour codes
and all, or just the URL, or a bare `http://host:port` for a server on the LAN
with no `JWT_SECRET`. The name defaults to the host's first label (`yourslug`
for `yourslug.relaytty.com`) and is a field you can type in first. Max Pane
splits the line: the base URL goes to `config.toml` as a `[[servers]]` table
and the token goes to the macOS Keychain as an internet password for the
server's host — the same space and the same rules as [Passwords](#passwords),
listed and deleted in System Settings → Passwords, never in the file and never
in a log or an error. The server is asked at once (`GET /api/sessions`, off the
main thread), and the row says what came back:

| the row | what it means |
|---|---|
| `connected · 3 sessions` | the list arrived; its sessions are in the sidebar |
| `refused` — *token refused — paste the Auth URL from the server's startup output* | 401: the token is wrong or the server minted a new secret; **paste token** takes a new line |
| `no token` — *paste the Auth URL…* | the table is in the file but the Keychain has no item for its host |
| `reconnecting` — *unreachable — host: why* | no answer; retried on `session_poll_seconds`; reads `unreachable` once it has gone on a minute |
| `disabled` | `enabled = false`: kept, ignored, not shown in the sidebar |

**Remove** asks first, then takes the table out of the file and the token out of
the Keychain (unless another server shares the host). **on | off** writes
`enabled`. The name is a field: type a new one and leave it to rename — the
lanes attached to that server and their `host:path` project tags follow, so
nothing detaches and nothing stops gathering. Under the name, **color** is a
row of eight square swatches, the current one framed (see *A server has a
colour*, below). `maxpane server add NAME '<line>'`, `maxpane server ls` and
`maxpane server color NAME COLOR` do the same from a shell, through the same
door.

**Everything applies live.** Adding, removing, enabling, disabling, renaming or
pasting a token takes effect the moment the file is written: the registry gains
or loses that server's source, the sidebar's group appears or goes, and a lane
attached to a server that is now gone stays where it is with a one-line banner
(`SERVER NOT CONFIGURED`) rather than vanishing — put the server back and it
attaches again. Editing `config.toml` by hand does exactly the same, through the
watch the settings window already uses. The file's shape:

```toml
[[servers]]
name = "yorkshire"                      # what the lane header shows
url = "https://yourslug.relaytty.com"   # https://<slug>.relaytty.com, or http://host:port
enabled = true                          # optional; false keeps the entry and ignores it
color = "violet"                        # optional; slate cyan blue violet magenta rose lemon ink
```

The local server is never listed; it is implicit, and with no `[[servers]]`
the app is exactly what it was before servers existed. A server with no name,
a URL that is not `http(s)://` with a host, or a name already used is skipped
with the reason on its row and on stderr. A `color` that is not one of the
eight costs only the colour: the server is kept and drawn in slate, and the
file's problems say which line and what the eight are.

**In the sidebar.** With at least one server configured the list is blocks:
`// LOCAL` and this Mac's project groups, then each enabled server as its own
`// NAME` section — its session count (or BLOCKED count), and its state as a
chip when it is anything but connected — with that server's project groups
under it. A refused or unreachable server is a header with its chip and
whatever it last held; a disabled one is not there. The header's `//` is in
the server's colour. A click on a server's header opens Settings › Servers on
that row, a right-click opens its menu (below), and its triangle folds the whole
server, as `// LOCAL`'s folds this Mac (see [Folding a group puts its lanes
away](#folding-a-group-puts-its-lanes-away)). BLOCKED counts in the footer and
the status bar include remote sessions, while their server is answering.

**A server has a colour, and the colour is the mark.** Each server is known
by one of eight colours, and a small solid square in that colour marks
everything that belongs to it. The name appears once per context, not once per
row:

| surface | what it shows |
|---|---|
| sidebar header `// WSL` | the `//` in the server's colour; the name, the count and the state chip as they were (the chip is state, so it is green) |
| sidebar rows under it | the 8 pt colour square on the second line, where the grey name chip used to be, and no name: the row is already under `// WSL`. Its tooltip is the server's name |
| lane header, and so the gallery tile | the name chip stays, outlined and lettered in the server's colour: nothing above a lane says which server it is. On a tile shrunk past reading (under 0.6×), or a header too narrow to keep ten characters of title, the square alone |
| ⌘O and ⌘P rows | the same tinted chip, because those lists mix servers |
| `// LOCAL` and everything local | unchanged: this Mac has no colour and no square |
| a server that is not answering | the square goes hollow, an outline in the same colour at reduced alpha, and the chip dims with it: still that server, visibly not live |

| colour | dark | light |
|---|---|---|
| `slate` | the at-rest grey | the at-rest grey |
| `cyan` | `#22D3EE` | `#006BA0` |
| `blue` | `#60A5FA` | `#1D4ED8` |
| `violet` | `#9F85FF` | `#6D28D9` |
| `magenta` | `#F06BE0` | `#B5179E` |
| `rose` | `#FB7185` | `#BE185D` |
| `lemon` | `#FDE047` | `#7A6200` |
| `ink` | `#F4F4F5` | `#18181B` |

The colour is identity and never state: state stays green and DONE stays
orange, and the status square, the focus outline, lane borders and the terminal
are never tinted. Each of the seven hues is at least ΔE 40 from every green and
from DONE's orange in both appearances, and 4.5:1 as text on a lane and on the
strip; `amber` and `teal` were tried and dropped because they read as DONE and
as working. A new server gets the first colour no other server is using, and a
`[[servers]]` table with no `color` line gets one the first time it is read,
written to the file once; a colour you chose, `slate` included, is never
changed for you.

**Picking it.** Right-click the server's header in the sidebar: **Color ▸** the
eight, each with its square and its name and the current one ticked, then
**Rename…**, **Disable** and **Server Settings…**, which are the actions of
Settings › Servers and go through the same code. The swatches on the server's
row in Settings and `maxpane server color WSL violet` are the other two ways,
and `maxpane server ls` prints the colour between the URL and the state.
A change cross-fades on every surface at once; nothing relaunches and no lane
re-attaches.

Past ten characters the chip's name is cut with an ellipsis; the tooltip is
the server's host. With the server marked, the path stops repeating it: the
group reads `/home/spierce` and the header `/home/spierce/m7out`, as the
server gave them and never as `~` for *this* Mac's home. Underneath, nothing
moved: the project tag is still `yorkshire:/home/spierce/m7out` —
`host:path`, never the result of walking this Mac's tree for a directory that
only exists over there — so a remote project gathers with itself and never
with a local path that happens to match.
[ADR-0025](docs/decisions/0025-a-server-has-a-colour.md), amending
[ADR-0023](docs/decisions/0023-one-truth-per-server-and-the-server-chip.md).

**When a server stops answering.** The relaytty.com tunnel usually dies
silently — the connection stays up and nothing answers — so Max Pane asks:
the session list gives up after 4 s, a failure is retried once, half a second later, before
it is believed (one slow response never flips anything), and a ping on
`/ws/events` every 5 s makes it ask sooner. From death to the sidebar saying
so is at most 13.5 s with the default `session_poll_seconds`; measured against
the real server frozen with `kill -STOP`, 10–12 s, and under a second to come
back. A much longer `session_poll_seconds` can slow that down. The verdict is
one truth per server, and everything shows it in the same turn:

| where | what it shows |
|---|---|
| the server's `// NAME` header | a green outlined chip: `RECONNECTING`, then `UNREACHABLE` once it has gone on a minute, or `TOKEN REFUSED`; the last error is the tooltip, and is on the row in Settings |
| every session row under it | at-rest grey, a hollow square, `—` for the state and `OFFLINE` where the rate was; no stale `working`, no BLOCKED chip; the group counts `N OFFLINE` |
| the lane header | the same chip where `BLOCKED`/`DONE` go, and a hollow status square |
| the pane | the banner: `RECONNECTING · INPUT IS NOT BEING SENT` |
| a gallery tile | dimmed |
| the status bar | `5 sessions · 3 offline`; a dead server's BLOCKED is not counted, and does not bounce the Dock |
| `maxpane sessions` / `server ls` | `offline`; `reconnecting` or `unreachable` with the error |

The lanes and the list tell each other: when the list goes quiet every lane
on that server tests its own connection within 4 s instead of waiting out its
45 s zombie timer, and a lane that loses its connection makes the list check
at once. Coming back is quiet: the chip goes, the rows take their state from
a fresh list, the lanes re-attach at once and replay from their offset.

**Typing into an offline lane is not sent**, and the banner says so. What
you type in the last five seconds before the connection returns is delivered,
so a blip loses nothing; anything older is dropped, and the pane says how
many bytes in one line when that happens. It is not queued for the length of
an outage on purpose: the other end is usually an agent at a prompt, and a
`y⏎` typed at one question must not land on another a minute later. If the
server came back with a new token (a restart mints one), Settings › Servers ›
paste token, or `maxpane server add NAME '<the new line>'` with the same
name, replaces it.

**Starting things there.** A line runs where the focused lane is. With a
remote lane focused, ⌘O `claude` ↩ starts Claude Code on that lane's server,
in that lane's directory, as a lane here — and it goes BLOCKED in the sidebar
when it asks something. ⌘T (a shell in a new lane) and ⌘D (a shell under this
pane) do the same. From anywhere, a word at the front of ⌘O's field says
where instead:

| typed in ⌘O | runs |
|---|---|
| `claude` | where the focused lane is: its server, its directory; this Mac with no lane |
| `@yorkshire claude` | on `yorkshire` — in the focused lane's directory if that lane is on `yorkshire`, else the server's home |
| `@local claude` | on this Mac, whatever lane is focused |
| `@nope claude` | as typed, here; the row says `@nope is not a server` |

The row's second line says where before you press Return — the server's chip
and the directory (`/home/spierce/proj`, or `~` for the server's home) — and
the ⌘/ sheet lists the grammar. A directory over there is never guessed from
this Mac: when Max Pane does not know one, it sends none, the server starts
the session in its own home and says which directory that was. A command
remembers where it last ran, server included, so ⌘O ⌘1 on `claude` goes back
to the same box and directory; a recent from a server that is not connected is
not offered. If the server refuses, the picker comes back with the line still
in the field and one line naming the server and its error.

What is sent is `POST /api/sessions` with the cookie, and never the program's
name as the command: the body is `{"command": "$SHELL", "args": ["-li", "-c",
"<line>\nexit $?"]}`, the same no-`exec` wrapper a local session gets, for the
same reason — relay-tty's own spawn `exec`s the program, an exec'd agent is
the session leader, and the classifier never calls a session leader BLOCKED.
A bare shell is `{"command": "$SHELL", "args": []}` and the server makes it a
login shell. `maxpane run` from a local terminal still starts things on this
Mac, even beside a remote lane; from a remote shell the CLI is not there
(Phase 4).

A remote lane's project is `server:` plus the session's directory as the
server reports it — the directory itself, not a git root, because the server
has no git-root answer and Max Pane does not type `git rev-parse` into your
session. Two lanes in the same directory gather; a lane in a subdirectory of
the same repository is its own project for now.

**What works, and not yet.** A session *already running* on a remote server:
listed, attached, typed into, resized, reconnected (with the whole scrollback
replaced rather than appended when the server answers a missed `RESUME` with
the full ring), shown with its agent state, and back after a relaunch. The
server's sessions are read from `GET /api/sessions` and kept current by
`/ws/events`, polled on `session_poll_seconds` as the fallback, and a server
that stops answering says so everywhere within seconds (above). **Not yet:**
⌘-clicking a path in a remote lane, which says so in one line — the path is a
path on the other machine, and the server's file API is Phase 4 — and
`maxpane` inside a remote shell.

**Against the relay-tty web app in a web lane** — the bar the plan sets. What
you get here that the page cannot give: every server's sessions in the one
sidebar and the one ⌘O, ranked with the local ones and BLOCKED pulsing the same
green; one paste per server, in one place, with the token in the Keychain
instead of a cookie per page; a session as a lane that splits, docks, gathers by
project, maximizes and survives eviction and relaunch; one connection per
server rather than a whole web app per pane; and starting a session from the
same ⌘O, ⌘T and ⌘D as a local one — on the focused lane's server, in its
directory, with the same recents — where the page's form starts it on that
page's server only and, because relay-tty `exec`s what the form names, starts
an agent that can never read BLOCKED, which a session started from here does.
What the page still does better: its form lists the server's projects and
installed agents to pick from, where ⌘O expects you to know the command; and
files and uploads go through its own viewer (Phase 4).

**Until relay-tty authenticates the tunnelled WebSocket.** Through relaytty.com
the session WebSocket is accepted with no credential at all — the tunnel client
opens it from loopback and the server grants the localhost bypass (spike M7
§4) — so a tunnelled server's sessions are attachable by anyone who knows the
slug and an eight-hex session id, until relay-tty accepts `?token=` on
`/ws/sessions/:id` and `/ws/events` (Phase 0b of the plan). As of relay-tty
1.23.0 it does not: `?token=` is read on `/ws/share` only, and `verifyWsAuth`
reads the cookie alone. Settings says so in one line on every relaytty.com row.
HTTP through the tunnel is authenticated, and LAN-direct both are; the token is
sent as the `session` cookie on every request, the upgrade included, so nothing
here changes when the server starts checking it.

### Colour

**One green family, and no orange** ([ADR-0015](docs/decisions/0015-one-green-family.md)).
Each green has a role, and the roles differ in form as well as shade, so they
stay tellable apart at a glance:

| Role | Dark | Light | Where |
|---|---|---|---|
| working | `#16A34A`, muted | `#4D7C5F` | the filled status square and terminal icon, a moving rate |
| focus / accent | `#22C55E`, mid | `#15773A` | the outline around the pane with the keyboard, default and `+ NEW` buttons, `//` slashes, the `$` marker, selection, drop indicators, the terminal cursor, the ⌘P flash |
| blocked | `#4ADE80`, brightest | `#166534` | BLOCKED chips (always filled), the `N BLOCKED` counts, the lane header's blocked mark |

**BLOCKED breathes.** It pulses slowly between full strength and 60 %, taking
1.8 s per breath, and never goes out. The pulse runs only while the mark is on
screen, and every blocked mark breathes in step. It stops the moment the agent
is no longer blocked. With Reduce Motion on it holds steady at full strength,
and the filled block is what sets it apart. EXITED is dim.

**Colour in the sidebar is for a change of state, and nothing else.** At rest
— idle, unknown, a web page, a session with no lane — a row's status square
and icon are grey. They go green while the agent is WORKING, and there is no
WORKING chip: the green mark and the moving rate already say it, and a chip
under every busy row was one more green word to read past. DONE is the one
hue outside the family: Signal Orange, `#E85D00` dark and `#B84800` light,
on the square, the icon and the DONE chip, so the lanes waiting for a
decision are findable across a gallery of ten without reading a word.

Light mode has its own greens because the dark ones fail on a light ground:
`#4ADE80` is 1.7:1 on white. There, BLOCKED is the strongest ink rather than the
lightest one. Two colours outside the family are kept on purpose. Amber marks
an insecure `http://` or a missing saved password in the web bars, because
green would read as *safe*. Red marks memory past the hard limit. And a remote
server has a colour of its own, which is identity and never state: see
[Remote servers](#remote-servers) and
[ADR-0025](docs/decisions/0025-a-server-has-a-colour.md).

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

The greens have a light value and a dark value each; see [Colour](#colour).

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
sidebar_collapse_hides_lanes = true
font_name = "JetBrains Mono"
font_size = 13
copy_on_select = false
cursor_blink = "focused"
```

The window writes one value at a time, in place: your comments, the order of
your keys and keys it does not know all survive
([ADR-0012](docs/decisions/0012-in-house-toml-line-editor.md)). **reveal in
finder** shows the file, and **open in editor** opens it in a terminal lane with
your `editor` setting, the same way ⌘-clicking a path does.

`theme` and `sidebar_collapse_hides_lanes` apply at once, and so does
everything under Servers — each `[[servers]]` table's `name`, `url`, `enabled`
and `color` (see [Remote servers](#remote-servers)). Every other
key, the keyboard included, applies on
the next launch, and the window marks a changed one `$ relaunch to apply` until
then.

A value of the wrong type is skipped and its default used. The window shows
which key was skipped and why, on that key's row. A line it cannot read at all,
or a key that is not a setting (the old JSON spelling `laneDefaultPt`, say), is
listed under the file's path and left exactly as it is.

**Coming from `config.json`:** the first launch that finds no `config.toml`
copies the old file's settings into one and leaves the JSON where it was. It is
not read after that, and the window says so. A value the JSON could not use
either comes across as a comment.

`theme` is `system`, `light` or `dark`. See [Light and dark](#light-and-dark).

`blocking` turns the ad and tracker blocker off everywhere when `false`, and
`blocking_list_url` is where its rules come from. See
[A web lane](#a-web-lane).

`copy_on_select` is whether selecting text in a terminal puts it on the
clipboard. It is `false` by default, so a selection is only a selection and ⌘C
is what copies; `true` copies every selection as it is made. Like the font, it
is read when the terminals' shared configuration is built, so a change takes the
next launch.

`cursor_blink` is which terminal cursors blink: `"focused"`, `"always"` or
`"never"`. `"focused"`, the default, blinks the one terminal that has the
keyboard and none when no terminal has it. `"never"` holds every cursor still,
the focused one included; it still turns hollow when its pane loses the
keyboard. `"always"` blinks every terminal, by telling every surface it is
focused, so a program that asked for focus events (mode 1004) is told it has
focus for as long as it runs. Under all three a program's own request wins
where Ghostty honours it: one that sets a steady cursor with DECSCUSR keeps it
steady while focused. Any other word is reported on the key's row and
`"focused"` is used. Read with the font, so a change takes the next launch.

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
range, and a lane you have dragged or sized keeps the width you gave it.
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

**When fewer than three lanes fit, the strip is a carousel.** A small window, a
dock eating the strip or an xl lane can leave room for only one or two lanes
across. Then focus, by whichever door it arrives (a click, ⌘[ / ⌘], the sidebar,
⌘P, a new lane), centres the focused lane exactly, and both neighbours peek in by
equal widths. Clicking either sliver focuses that lane, which centres it and
shows the next sliver, so you can click through the whole strip. "Fit" is
measured against the three lanes around the focused one, at their own widths,
in the part of the strip a dock leaves visible. The first and last lanes centre
too, with empty strip beyond them: an end lane pinned to the wall looked like
any other lane with a neighbour peeking, and the blank space is what says there
is nothing further. The snap agrees: it settles on the nearest lane centred,
with no peek nudge, and it leaves alone a strip that already rests where focus
centred it. With three or more lanes fitting, focus
still moves the strip as little as it can and the peek applies as above. A lane
at least as wide as the window is never centred, because its header would be
cut off. The threshold is fixed at three and has no config key.

`strip_edge_rails` is the other half: an 18 pt column at each end of the strip
with a count of the lanes hidden that way (`◀ 7`, `5 ▶`), and a plain wall when
there are none. A sliver says *there is more, this way*; it cannot say how many,
and at the ends of the strip there is nothing to show a sliver of. `false`
removes both rails and gives their 36 points back to the lanes.

`sidebar_collapse_hides_lanes` is whether folding a group in the session
sidebar takes its lanes off the strip and out of the gallery (see [Folding a
group puts its lanes away](#folding-a-group-puts-its-lanes-away)). On by
default; `false` folds the sidebar's rows and nothing else, and any lanes a
fold was holding come straight back.

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

Every web pane is inspectable: right-click a page and choose **Inspect
Element**, or pick the pane from Safari's Develop menu. It is always on, not
behind a switch, because the question "is that thing ours or the site's" has no
answer without it.

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
