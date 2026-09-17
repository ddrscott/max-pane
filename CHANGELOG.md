# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- The build carries Apple's passkeys capability when a provisioning profile grants it, and behaves exactly as before when none does. WebAuthn in a web pane needs `com.apple.developer.web-browser.public-key-credential`, a managed capability Apple grants per team and delivers as a provisioning profile; signed with the key and no profile the app is killed at launch, so the key is never in `MaxPane.entitlements`. `scripts/entitlements.sh` decides at signing time: the shipped file byte for byte with no profile, an ad-hoc signature, or a profile for another bundle id; the file plus the key and the profile's identifier entitlements when `packaging/MaxPane.provisionprofile` (or `MAXPANE_PROVISIONING_PROFILE`) grants it for this team and bundle, with the profile embedded; a hard stop for a profile that is present but ungranted, expired or another team's. `make-dmg.sh` refuses a bundle where the key and the embedded profile disagree, and `scripts/tests/entitlements.sh` pins every branch in the default test run. Passkeys themselves still do not work in a pane: the request to Apple, the profile and the webauthn.io proof need the Account Holder's account, and the README ("Passkeys and the provisioning profile") says exactly what to file and where to put the result
- Picture-in-picture in a web pane. WebKit keeps it off on macOS unless the embedder turns on a private preference — the public switch is iOS-only — so no site could offer it: the glyph was missing from the native controls, YouTube's and Vimeo's buttons said no, and `requestPictureInPicture()` rejected with `NotSupportedError`. Every pane's configuration now sets it the way WebKit's own MiniBrowser does, popups inherit it, and the call is guarded so a WebKit that drops the key leaves PiP off rather than crashing the app. A PiP window is the page's — destroying the web view closes it, measured — so eviction (ADR-0003) now leaves a pane alone while one of its videos is in PiP, and reclaims it once the video is back inline. `WebPictureInPictureTests` proves it on a real `<video>`; the one test that puts a PiP window on the display is behind `MAXPANE_PIP`
- Geolocation in a web pane. WebKit on macOS never answers `navigator.geolocation` — no denial, no timeout, a spinner forever — so the API is now a page-world script in every frame, built on WebKit's own `Geolocation` types, and the pane answers it: the first call from a site asks in the pane's sheet (`WANTS TO KNOW WHERE YOU ARE`), once per site per cookie jar, remembered in the ledger like a camera grant, and two calls during one sheet are one sheet. Only a yes reaches CoreLocation, where macOS asks about the app itself the first time; a no from you or from System Settings is `PERMISSION_DENIED` at once, and Esc is *not now*. One location manager serves every lane, `watchPosition` hears every fix, `maximumAge` is honoured from the last one, and `timeout` runs from the yes. `NSLocationUsageDescription` and the hardened-runtime location entitlement are in the bundle
- Private web lanes. ⇧⌘N (File › New Private Web Lane) opens a lane on a blank page with the cursor in the address, marked `PRIVATE` on its header, its chrome bar and its ⌘P rows. Its pages live in a `WKWebsiteDataStore` that is never written to disk and is dropped when the lane closes; no visit reaches history, no title correction, no session blob, and ⇧⌘L is greyed out while ⌥⌘L still fills. A ⌘-click from a private page opens the sibling lane in the same private store, signed in. A relaunch never brings a private lane back: the ledger deletes it at open, and a `kill -9` with the lane up is the same case. See ADR-0016
- Pinch to zoom in a web pane. A trackpad pinch drives the same persisted page zoom as ⌘= and ⌘-, reflowing the page live, and settles on the nearest rung of the zoom ladder when the fingers lift (eased on the pane's 0.16 s, at once under Reduce Motion), so it survives a relaunch and ⌘0 resets it. A two-finger double tap goes to 150% from actual size and back to 100%. A popup's page gets WebKit's own transient pinch. `upgradeKnownHostsToHTTPS` is set explicitly on every pane's configuration, and a test pins both
- Print, and Save as PDF, for a web pane. ⌃⌘P (File › Print…) runs the system print panel as a sheet over the pane, fitted to the paper's width, with the panel's own Save as PDF in its PDF menu; a popup's page prints from inside the popup. File › Save as PDF… writes the whole page — every fold, not the one on screen — to a file chosen in a save panel named after the page, and the result lands as a finished row in the pane's download bar. Both are greyed out on a terminal lane. ⌃⌘P rather than ⌘P because ⌘P is the palette; `keys` moves it and binds `savePDF`
- Web notifications. WebKit has no `window.Notification` on macOS, so Slack, Gmail and every chat app in a pane could neither ask nor notify; now the API is a page-world script in every frame, and the pane is the centre behind it. `requestPermission()` asks in the pane's own sheet, once per site per cookie jar, remembered in the ledger like a camera grant; `Notification.permission` reads the remembered answer before the page runs. A granted `new Notification()` posts through macOS's Notification Center with the site's title, body and icon, and a click brings the app, the lane and the pane forward and fires the page's `click`. Nothing is posted for the pane you are looking at. macOS is asked for permission the first time a site is allowed, not at launch. Only a live page can notify — an evicted pane's cannot — and a service worker's `showNotification` is not supported
- Ad and tracker blocking in every web pane and the popups over them, with WebKit's own content blocker. The rule list is fetched from `blocking_list_url` (default: Adblock Plus's WebKit-format conversion of EasyList; several URLs are joined), compiled once into the profile's rule-list store, looked up from there on later launches and refreshed daily; a list past WebKit's 150 000-rule ceiling is cut into several with the exception rules in every part. Off for one site from the lane's ⋯ menu or Navigate › Block Ads on This Site, by registrable domain, kept in the ledger; the chrome bar wears an `unblocked` chip on such a site, and a click on it turns blocking back on. `blocking = false` turns it off everywhere; `keys` binds `toggleBlocking`
- Web Inspector on every web pane: right-click, Inspect Element, or attach from Safari's Develop menu. Always on, since the app is for people who build pages

### Changed
- An expanded gallery tile's seams drag. The separator between two stacked panes in the expanded tile resizes them exactly as on the strip — same arithmetic, same grab band, one ledger write on the drop, and the terminals hear the same live-resize word — so leaving the gallery shows the panes where the drag left them, and a relaunch keeps them. The pane grips come back on the expanded tile too. Unexpanded tiles are as handle-free as before, and their seams now let the click through and never show a resize cursor over a seam that will not move. A tile clamped below half size keeps its handles hidden. ADR-0011 amended

### Fixed
- Save as PDF… has a deadline. Neither the page-height measurement nor `createPDF` is promised a completion — asked of a page mid-navigation, or whose content process goes away, WebKit drops it — and the pane was waiting on it forever: no row, no error, nothing to click. The render now runs under a 30 s deadline and a miss is a failed row in the download bar with the reason (`the page did not render as PDF within 30 s`). The same hang stuck `./scripts/test.sh` in about half of runs, because the `WebPrintTests` failure test asked for the PDF before its page had started loading (`isLoading == false` is true before `load` begins); it now waits for the page by title and fails the write against a regular file in the path rather than a missing directory, which is a failure on every filesystem
- `scripts/test.sh` forces `MAXPANE_PROFILE=tests` and unsets the four path overrides (`MAXPANE_SOCKET`, `MAXPANE_LEDGER`, `MAXPANE_CONFIG`, `MAXPANE_DATA_SALT`) instead of defaulting the profile. A shell inside a live Max Pane pane inherits `MAXPANE_PROFILE=default` and the app's socket, so a run from there saw the empty default salt, every real-WebKit suite printed `SKIPPED`, and the run went green having proved less than it said. The default run now ends with a count of the real-WebKit suites in the tree, how many ran, which were opted out by `--skip` (now passed through to `swift test`), and how many the profile guard skipped; any of the last fails the run

## [0.6.0] - 2026-09-16

### Added
- DONE: a session that finishes a turn is marked DONE in the sidebar, on its lane header and in ⌘P, until you focus its pane or `doneHoldSeconds` (30 min) runs out. relay-tty's own DONE only exists while nothing is attached, so it never showed for a lane
- The Dock icon bounces once when a session becomes DONE or BLOCKED while the app is in the background
- Mobile Layout, in a lane's ⋯ menu and the View menu: the lane's pages ask their sites for the phone layout with an iPhone user agent and reload. Per pane, kept in the ledger, off by default; `keys` binds `toggleMobileLayout`
- A notarized DMG and a Homebrew cask — the app signs with hardened runtime and `scripts/make-dmg.sh` staples Apple's ticket, so a download opens with no Gatekeeper warning. Apple silicon, macOS 14 or newer

### Changed
- Opening a lane with no relay-tty installed says what to install and how, instead of naming a config key
- Sidebar colour marks a change of state only: grey at rest, green working, Signal Orange done, BLOCKED as before. The WORKING chip is gone; the green mark and the rate carry it

### Fixed
- A lane centred in the carousel lost its `s | m | xl` switch and `⋯` menu to clicks: the end-lane margins were scroll-view content insets, which AppKit covers with an invisible view that takes the press. The margins are document padding now

## [0.5.0] - 2026-09-15

### Added
- Lanes: terminals and web pages as peer panes, in portrait columns on an infinite horizontal strip
- Gallery layout — every lane on one screen, live, switched with two icons in the toolbar
- Lane size presets s | m | xl in every lane's menu, docks included; ⌘\ cycles them
- Drag a lane by its header onto any edge of a pane, on the strip and in the gallery
- Pick a pane up and drop it in another column
- ⌘D splits any pane to the right, the way iTerm does
- Carousel: the focused lane centres when fewer than three lanes fit, first and last lanes included
- One lane per agent session, with a session sidebar that reveals and focuses the lane
- Web panes with address-bar completion and a find bar that counts matches
- A page's popup opens as a dialog over the window, never as a new lane
- A page's full screen fills its pane; ⇧ or a second request takes the whole display
- Kept pages: the ★ in a page's chrome bar keeps it, on a bookmark bar you can reorder; Keep This Page is in the Navigate menu and bindable through `keys`
- History with no limit, in a window with room for it; another browser's history imports interleaved by date
- Passwords live in the Keychain and go nowhere else
- ⌘-click a file path in a terminal to open it in your editor
- ⌘O runs a command line rather than pretending to be a shell
- Keymap as a config file, with Esc doing something at last
- Every setting editable in Settings, stored as comment-preserving TOML
- Follows the system light/dark mode live, with a theme override
- Lucide icons across the chrome, and a globe on web rows
- One green family for status; BLOCKED is the brightest green and pulses slowly
- Panes never inherit Claude session markers from the process that launched the app, so `claude` inside a pane saves its transcript
- The core is linked statically, so a rebuild in the checkout cannot break the installed app

[Unreleased]: https://github.com/ddrscott/max-pane/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/ddrscott/max-pane/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/ddrscott/max-pane/releases/tag/v0.5.0
