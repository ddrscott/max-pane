# Acceptance tests (PRD §15)

Where each of the eight acceptance tests is verified, and by what. A test that is
only ever checked by hand is written down here so it is at least checked
deliberately.

| # | Test | Verified by | Status |
|---|---|---|---|
| 1 | 20 lanes, reorder randomly, `kill -9` → order identical on relaunch | `crates/laned-core/tests/durability.rs::strip_order_survives_an_unclean_exit` — drops `Core` with no shutdown path and reopens the file | **automated** |
| 2 | `open https://example.com` in a pty pane in `~/src/foo` → web pane immediately right, tagged `foo` | ledger half: `durability.rs::a_url_from_a_terminal_lands_right_of_it_and_inherits_the_tag`; shim half: `crates/maxpane-open` tests + manual | **partial** |
| 3 | `cd ~/src/bar` → tag updates within 10 s; lane does not move | `durability.rs::retagging_never_moves_a_lane`; the ≤5 s bound comes from pty-host's flush cadence ([ADR-0005](decisions/0005-cwd-for-relay-sessions.md)) | **automated** |
| 4 | Sleep, wake → no web pane reloads; terminals reattached; scroll unchanged | manual round, 2026-09-14: a `--profile sleep` instance with three local pages beaconing load id, `scrollY` and `visibilityState` every 2 s to a request-logging server, plus two relay terminals. `pmset sleepnow` on a docked Mac on AC gives a DarkWake and a 64-minute display-off lock, not a true sleep — which is the sleep a docked MacBook actually gets. Across it: the server saw no page load after setup, all three load ids and scroll offsets (900/1800/2700) survived, visibility went `hidden` and back to `visible` on wake, heartbeats never gapped past 2.7 s, and the relay adapter logged no reconnect. Not visual: window capture of the throwaway instance was refused. Battery sleep, where WebKit may suspend processes, is still unmeasured | **passed (functional, AC only)** |
| 5 | 150 lanes → idle CPU < 2%, RSS within target, scrolling smooth | spikes [M1](spikes/01-m1-webkit-memory.md) + [M4](spikes/04-m4-strip-scroll.md) | **measured** — idle CPU 0.015–0.18% of one core; 0.00% dropped frames at 150 lanes; RSS ~27 MB/pane on light pages and ~95 MB on real ones, which puts 130 real panes above the hard eviction mark on a 32 GB Mac (see [ADR-0003](decisions/0003-website-data-store-sharding.md)) |
| 6 | Evict a lane, ⌘P its URL → rehydrates, strip scrolls to it, border flashes | ledger half: `durability.rs::eviction_round_trips_through_the_ledger` + `search_covers_titles_urls_and_scrollback`; the scroll and flash are manual | **partial** |
| 7 | ⌘G shows only that project's lanes contiguous; Esc restores exactly | `durability.rs::gather_filters_without_writing_an_ordinal` — asserts the restored ordinals are byte-identical | **automated** |
| 8 | Quit with Relay host down → relaunch shows all lanes, pty panes "reconnecting", ordinals intact | ordinals: covered by test 1, which never involves Relay at all; the reconnecting state is manual | **partial** |

## Why some of these can only be partial

Tests 2, 6 and 8 each have a half that is a claim about *pixels* — "immediately
right", "border flashes", "shows reconnecting". The ledger half is where the
actual risk lives (wrong ordinal, lost URL, dropped scroll position) and that half
is automated. The visual half is checked by using the app, which is what Phase 1's
two-week exit criterion is for.

Test 5 is a measurement, not an assertion; it belongs to the spikes.

## Running the automated half

```sh
source scripts/env.sh
cargo test
```

## Where the PRD and reality disagree

Recorded here as well as in the ADRs, because §0.6 asks for conflicts to be
surfaced rather than quietly reinterpreted.

| PRD says | Measured | Where |
|---|---|---|
| §9: "one `WKProcessPool` for the whole app (WebKit does process-per-site under it)" | `WKProcessPool` is a deprecated no-op since macOS 12; 100 views across 20 origins gave 100 processes, and 101 for 100 on real sites | [ADR-0003](decisions/0003-website-data-store-sharding.md) |
| §10.2: unparenting is how memory stays down | Unparenting reclaims 3.5 MB; eviction reclaims 24.7–90.8 MB. Unparenting is a CPU strategy | [ADR-0003](decisions/0003-website-data-store-sharding.md) |
| §10.1: 150 lanes (~130 web) "before eviction engages" on a 32 GB Mac | 130 real web panes ≈ 11.34 GiB ≈ 36% of 32 GB — above the hard mark. Eviction will be engaged at that target | [ADR-0003](decisions/0003-website-data-store-sharding.md) |
| §7.3: poll foreground cwd with `proc_pidinfo` every 5 s | RelayTTY's pty-host already does exactly this, and does not strip OSC 7 from the stream. Observe instead of duplicating | [ADR-0005](decisions/0005-cwd-for-relay-sessions.md) |
| §11: "resize → propagate to Relay" | Measured: every size flip forces a full TUI redraw on every other attached client — 6 671 bytes for `htop` — and the last writer owns the PTY for everyone | [ADR-0007](decisions/0007-terminal-panes-never-resize-the-pty.md) |
| §9: "`WKUIDelegate` popups/new-window requests → new web pane right of the requesting pane" | An OAuth popup as a lane landed wherever its opener was — off screen, docked, under the gallery — took the focus, multiplied with every click on "Sign in", and was restored on relaunch without its opener. A popup is now a dialog over the window; `target=_blank` still makes a lane | [ADR-0013](decisions/0013-web-popups-are-dialogs.md) |
| §12 M4: "scroll at 120 Hz" | Not verifiable on this machine — the panel is 60 Hz, and the built-in display reported 120 but delivered exactly 16.667 ms | [ADR-0004](decisions/0004-strip-view-strategy.md) |

None of these were reinterpreted silently. Each has an ADR saying what was built
instead and why.

## Passkeys and picture-in-picture in a web pane

Checked 2026-09-16 in a throwaway `verify` profile (`MAXPANE_APP=build/verify.app`,
signed with the Developer ID, the hardened runtime and the three entitlements in
`MaxPane.entitlements`, exactly as a shipped build is), driven with a local probe
page on `localhost:18923` that beaconed every result to a request-logging server,
and with real mouse events from a small `CGEvent` helper. System Events' AX
"click" was not enough: WebKit answered it with `NotAllowedError: The document
is not focused` for WebAuthn and `The request is not triggered by a user
activation` for PiP, which is worth knowing before anyone automates either again.

**Passkeys / WebAuthn: fails, and the fix is not ours to type.**
`window.PublicKeyCredential` exists, but
`isUserVerifyingPlatformAuthenticatorAvailable()` and
`isConditionalMediationAvailable()` both return `false`. A real click on
`navigator.credentials.create()` for `rp.id = "localhost"` was refused at once,
with no sheet and no QR code: `NotAllowedError: The request is not allowed by
the user agent or the platform in the current context, possibly because the
user denied permission.` On `webauthn.io`, Register for a throwaway username
(`maxpane-verify-1`) put the same sentence in the page's red banner. To measure
the entitlement rather than assume it, a copy of the bundle was re-signed with
`com.apple.developer.web-browser.public-key-credential` added: `codesign
--verify --deep --strict` passes, and the app exits 137 (SIGKILL) before writing
a byte to stderr or opening a window. No kernel, `amfid` or `syspolicyd` line
named the reason in the unified log, so the cause is inferred from Apple's
documentation for the key, not observed: it is a *managed capability* — the
Account Holder files a request form, Apple reviews the app against its
web-browser criteria (macOS 13.3+), and once granted it has to arrive through a
provisioning profile embedded in the bundle. Scoped as its own queue item; the
entitlements file alone cannot do it.

*Plumbing done 2026-09-16, proof pending on Apple.* `scripts/entitlements.sh`
now decides the signing entitlements: the shipped file unchanged unless a
profile at `packaging/MaxPane.provisionprofile` (or
`MAXPANE_PROVISIONING_PROFILE`) grants the key for this team and this bundle
id, in which case the key and the profile's identifier entitlements go in and
the profile is embedded. Checked here in both states with a *decoded fixture*
profile for team `DH6NDWAQQ2` against a throwaway bundle
(`build/wq-passkeys.app`): off is byte-identical to today's signature; on
signs, `codesign --verify --deep --strict` passes, and
`Contents/embedded.provisionprofile` is in place. That bundle was deleted at
once — a fixture profile is not a grant, so it too would be killed at launch —
and it was **not** launched. `scripts/tests/entitlements.sh` pins every branch
in the default test run. Still to do, by the Account Holder: the request form,
the profile, ADR-0017 with the outcome, and the webauthn.io proof (README,
"Passkeys and the provisioning profile"). Until then this section's finding
stands: no passkeys in a pane.

**Picture-in-picture: failed, for a one-line reason that was ours; now on.**
As found: `document.pictureInPictureEnabled` was `true` and
`requestPictureInPicture` a function, but
`video.webkitSupportsPresentationMode('picture-in-picture')` was `false`, a real
click on `requestPictureInPicture()` rejected with `NotSupportedError: The video
element does not support the Picture-in-Picture mode.`, and the native controls
showed no PiP glyph. Traced in WebKit `main`:
`HTMLVideoElement::supportsFullscreen(VideoFullscreenModePictureInPicture)`
requires `mediaSession().allowsPictureInPicture()`, which is the page setting
`allowsPictureInPictureMediaPlayback`; `UnifiedWebPreferences.yaml` gives it
status `embedder` with a WebKit default of `false` on everything but the iOS
family; `WKWebView.mm` copies the configuration's value into the preferences
only under `#if PLATFORM(IOS_FAMILY)`; the public
`WKWebViewConfiguration.allowsPictureInPictureMediaPlayback` is
`API_AVAILABLE(ios(9.0))`; and WebKit's own macOS MiniBrowser turns it on with
`configuration.preferences._allowsPictureInPictureMediaPlayback = YES`
(`WKPreferencesPrivate.h`, `macos(10.13)`). `WebPaneController.enablePictureInPicture`
now does the same through KVC, guarded on the setter existing.

Re-checked 2026-09-16 with the switch in, in a throwaway `pip` profile
(`MAXPANE_APP=build/pip.app`, a release bundle signed as a shipped one is) on a
loopback page (`127.0.0.1:18931`) with a 64×64 h264 `<video controls>` that
beaconed its answers: at `loadedmetadata` (`readyState` 1)
`webkitSupportsPresentationMode('picture-in-picture')` is still **false**, and
2.5 s later, at `readyState` 4, it is **true** — the answer needs the player to
have a frame, not just metadata, which is why `WebPictureInPictureTests` waits
for `readyState >= 2`. The glyph and YouTube's and Vimeo's buttons sit on the
same call. Not hovered for a picture of the glyph, because the native controls
only show it under the pointer and the pointer is the owner's.

Entering PiP and what follows was measured by `WebPictureInPictureTests`'
`MAXPANE_PIP=1` test rather than by hand, because a real click activates the
throwaway's window and a `swift test` process can enter PiP through
`evaluateJavaScript`, which WebKit runs with a user gesture (the gesture covers
the call's synchronous part only: `await v.play()` ahead of the request spends
it, `NotAllowedError`). Against real WebKit, on a `WebPaneController` in a
window off every screen:

- `requestPictureInPicture()` resolves, `webkitPresentationMode` is
  `picture-in-picture`, the page gets `webkitpresentationmodechanged` then
  `enterpictureinpicture`, and one new window owned by **Picture in Picture**
  (macOS's agent, not the app) is on the display with the video playing.
- The page's first `requestFullscreen()` while PiP is up fills the pane
  (`isPaneFullscreen`), and the video stays in PiP through it and back.
- **Eviction closed the window.** `evict()` destroyed the web view and the PiP
  window went with it, mid-video, no crash. The window is the page's, so
  `evict()` now declines while the page reports a video in PiP
  (`WebPictureInPicture`, the same shape as the `isAsking` guard): asked while
  in PiP, the web view is kept and the window stays; once the video is back
  inline the next `evict()` reclaims it and the window count returns to what
  it was.
- **Closing the lane closes the window.** `closeLane` + `tearDown()` under a
  PiP video takes the window with the page and nothing else: no crash, no
  orphaned window. That is WebKit's behaviour and is left as is — keeping a
  closed lane's page alive for its PiP window, as Safari does for a closed tab,
  would be its own piece of work.
