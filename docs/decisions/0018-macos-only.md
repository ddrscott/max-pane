# ADR 0018 — macOS only; Linux and Windows are not planned

**Status:** Accepted · 2026-09-16
**Concerns:** PRD §1 ("Why macOS first"), §3 Non-goals, §17 ("The Linux
question can wait until this answer is in").
**Evidence:** a survey of the source tree at v0.6.0, tabulated below.

## Decision

Max Pane is a macOS app and will stay one. **No Linux or Windows port is
planned**, and no work is taken on to prepare for one beyond what §4 of the PRD
already requires: the Rust core stays platform-agnostic and AppKit concepts do
not leak into it.

The owner is content supporting Mac users only. This ADR records why a port is
a rewrite rather than a build target, so the question does not get re-asked
from scratch every time someone opens an issue about it.

## What the app is made of

| Piece | Lines | Portable |
|---|---|---|
| `crates/laned-core`, the ledger | ~15 000 | Yes. One `std::os::unix` call, in a test. |
| `MaxPaneKit`, files with no AppKit or WebKit import (config, TOML editor, strip store, sidebar and header models, Relay spawner, password logic) | ~8 600 | Mostly. Needs Swift on the target, or a move into Rust. |
| `MaxPaneKit`, AppKit and WebKit (views, web lanes, terminal panes) | ~29 000 | No. |
| `RelayClient` | small | Unix domain sockets; fine on Linux. |
| `crates/maxpane-open` | small | Unix domain socket; a named pipe on Windows. |
| Tests | ~16 000 | Split the same way as what they test. |

The durable half carries over. The visible half does not, and the visible half
is two thirds of the Swift.

## The three dependencies that decide it

**AppKit is the whole shell.** Around 150 `NSView` sites plus tables, menus,
the pasteboard, `NSAnimationContext`, appearance, tracking areas. There is no
cross-platform Swift toolkit to substitute; each target gets its own view
layer, written from the models up.

**`WKWebView` is not a web view here, it is a browser.** The `Web/` directory is
7 600 lines against content rule lists, `WKDownload`, website data store
sharding (ADR-0003), user content controllers, popups as dialogs (ADR-0013),
full screen (ADR-0014), picture-in-picture, geolocation, notifications, and
the passkeys capability (ADR-0017). Linux has WebKitGTK: the same engine with
a different API and no platform passkeys. Windows has WebView2: a Chromium
engine, where every one of those features maps differently or not at all.

**libghostty ships for macOS and Linux, not Windows.** ADR-0009 chose it
because the emulator is the part you never want to maintain. A Windows build
either waits for Ghostty to get there or reopens ADR-0001, which rejected a
web terminal per pane on measured process cost. Neither is attractive.

## Smaller things that would also change

- `relay-tty` spawns ptys and speaks over Unix sockets. Linux is fine. Windows
  would need ConPTY on the daemon side, which has not been checked.
- The Keychain becomes libsecret on Linux and Credential Manager or DPAPI on
  Windows. Chromium password import reads Safe Storage, which differs per OS.
- Packaging: no DMG, no ad-hoc codesign, no cask. AppImage or Flatpak; MSIX or
  an installer.

## What a port would actually be

- **Linux** is plausible as a sibling app on the shared Rust core: GTK4 plus
  libghostty (Ghostty's own Linux stack) plus WebKitGTK, with the ~8 600 lines
  of UI-free Swift moved into Rust and the ~29 000 lines of views rewritten. It
  is a second application that shares a ledger, not a port.
- **Windows** is a different product decision. No libghostty, no WebKit, no
  Unix ptys. Every layer changes.
- **One shell for all three** means abandoning the Swift app for a Rust shell
  embedding each platform's web view (wry or similar) and libghostty over FFI.
  A GPU terminal surface inside such a window is untested, and the lane
  behaviour is exactly the part every platform does differently.

## What was rejected

**Preparing for a port now**, by pushing more of `MaxPaneKit` into the Rust
crate ahead of need. The PRD's boundary (§4: nothing durable in Swift, no
AppKit in Rust) is the right amount of preparation. Moving view models across
the FFI for a front end that does not exist would cost every current change a
uniffi round-trip for no user.

**A Tauri or Electron rewrite with xterm.js.** Rejected on the same evidence as
ADR-0001: a `WebContent`-class process per terminal pane, which spike M1
measured, is the wrong shape for a strip of a dozen live terminals.

## What would change this

- The owner wanting it, having found a reason that outweighs a second app's
  maintenance. Then Linux only, as the sibling app above, and this ADR is
  superseded by one that names the toolkit.
- Ghostty shipping on Windows, which removes the hardest of the three blockers
  there. The other two remain.
- A contributor turning up with the GTK app already written. The Rust core and
  the Relay protocol are the interface they would build against; nothing in
  this ADR stops that.
