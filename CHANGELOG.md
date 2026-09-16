# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Web Inspector on every web pane: right-click, Inspect Element, or attach from Safari's Develop menu. Always on, since the app is for people who build pages

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
