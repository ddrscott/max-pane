# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- The gallery has walls: a docked lane stays at the left or right edge there too, at full size, and the tiles are laid into what is left. ⌘G no longer throws the pin away — the lane does not move one point in either direction — and ⌃⌘[ ⌃⌘] ⌃⌘\ ⌃⌘= ⌃⌘- and a drag of the wall's inner edge all work in the gallery. A docked lane has no tile there: it can never be the expanded one, ⌘[ / ⌘] and the expansion cycle step over it, a drop cannot land on it, and ⇧⌘↩ maximizes clear of it
- In the gallery with a tile expanded, anything that focuses another lane now moves the expansion to it — ⌘J, ⌘P, ⌘O, ⌘E, an app chord, a sidebar row, a search hit, a single click on another tile — so a key that selects a lane also leaves it readable. ⌘G, a click on the background, a focus change inside the expanded lane, and focus landing on a docked lane leave it where it is; ⌘[ / ⌘] now step over a dock, as they do on the strip

## [0.8.0] - 2026-09-24

### Added
- ⌘E Run Command: every command by its menu name with the key it currently has, plus live settings and server switches, in one picker; ⌘⌫ on a row binds a chord
- An agent that stops calls you back: a macOS notification when Max Pane is not the frontmost app, and a click goes to that pane, opening a folded group on the way
- ⌘J and ⇧⌘J walk every session that wants you, BLOCKED first and then DONE; ⌥⌘J lists them, where ⌫ dismisses a DONE and ⌘⌫ dismisses all of them. The Dock icon carries the BLOCKED count
- A chord per web app: `[[apps]]` in `config.toml` takes a name, a URL and a key, and the key focuses the lane that app is already on, or opens it, docked if you asked for that
- A terminal palette of your own: `terminal_theme_dark` and `terminal_theme_light` name any of the 485 Ghostty themes, applied while you watch, with the app's own three colours still winning inside them. `font_size`, `font_name`, `copy_on_select` and `cursor_blink` apply live too
- ⌃⌘W End Session: a sheet naming the session, its program and its machine, then the program is killed, here or on its server, and the pane closes. Every other client attached to it loses it too
- ⌘K clears a terminal pane's scrollback. The session's own ring and any phone attached to it are untouched
- Rename Lane, by double-clicking the header, ⌃⌘R, or the ⋯ menu. A terminal lane's name is pinned on the session, so the program cannot take it back
- ⌃⌘S Capture Pane: a PNG of the focused pane with its quoted path typed at the nearest prompt, ⇧ for a whole page rather than the fold, uploaded first in a remote lane. `maxpane capture` asks from a shell
- ⇧⌘H Paste History keeps a ⌘C made in a web pane, so a token copied off a dashboard is still there after the next copy. Rows say `WEB` or `PTY`; nothing polls the clipboard
- The app knows when a release is out: a check once a day, `↻ v0.8.0` at the right of the status bar, and Help › Update… running the upgrade in a lane you can watch, with Relaunch when it succeeds
- The Mac's clock, battery and network at the right of the status bar while the window is fullscreen and the menu bar is away
- In the gallery with a tile expanded, ⌘[ and ⌘] put it back and expand the previous or next lane, so the strip reads through from the keyboard
- ⌃V in a remote lane with only a picture on the clipboard uploads it through the relay server and pastes the server's path, as ⌘V does

### Changed
- The window comes back where you left it: fullscreen, or its frame on its display, clamped onto a screen that still exists when one has been unplugged. A first launch is still fullscreen

### Fixed
- The app inside the DMG carries its own notarisation ticket, so it opens without asking Apple on a Mac that is offline the first time it runs

## [0.7.0] - 2026-09-22

### Added
- Remote relay-tty servers: sessions running on another machine appear in the sidebar and ⌘O beside the local ones and attach as ordinary lanes, rendered by libghostty. They split, dock, gather by project and survive a relaunch like any other lane
- Settings › Servers: paste the Auth URL a relay-tty server prints at startup and it connects. The token is kept in the Keychain, never in `config.toml`, and adding, removing, renaming or disabling a server applies without a relaunch
- Start sessions on a remote server: ⌘O runs on the focused lane's server in its directory, `@name command` picks a server, and ⌘T and ⌘D beside a remote lane start there. An agent started this way can read BLOCKED, which one started from relay-tty's web page cannot
- A server has a colour: a small square marks its sessions in the sidebar and a tinted name chip marks its lanes, ⌘O rows and gallery tiles. Pick one of eight from the right-click menu on the server's `// NAME` sidebar header, from Settings, or with `maxpane server color`
- A server that stops answering says so within about 15 seconds, everywhere: a `RECONNECTING`, `UNREACHABLE` or `TOKEN REFUSED` chip on its sidebar header and lane headers, its sessions shown `OFFLINE` instead of a stale state, dimmed gallery tiles, and a banner saying input is not being sent
- `maxpane sessions`, `maxpane attach [NAME:]ID`, `maxpane run @NAME COMMAND…`, `maxpane server add | ls | color`: the app can be driven from a shell, remote servers included, when nobody is at the screen
- Folding a sidebar group, directory or whole server, puts its lanes away: off the strip and out of the gallery until it is unfolded, and remembered across a relaunch. A folded group still shows its hidden count and pulses when something in it is BLOCKED; attaching or ⌘P to a hidden lane unfolds it. `sidebar_collapse_hides_lanes = false` keeps the old behaviour
- Maximize Pane, ⇧⌘↩: the focused pane fills the visible strip, or the whole gallery from a tile, and the same key puts it back exactly where it was. Nothing is resized or written; moving focus elsewhere restores it first
- A risky paste asks first: several lines, a tab, or more than 16 KB opens a sheet showing exactly what will be sent, with Paste, One Line and Tabs to Spaces. ↩ and Esc cancel. ⌥⌘V pastes without asking
- ⌘V of a screenshot pastes a path to it. An image on the clipboard is saved as a PNG and its quoted path pasted; in a remote lane it is uploaded through the relay server first and the remote path pasted
- Pasted commands are tidied, and the pane says what it did: curly quotes and long dashes straightened (`—force` becomes `--force`), a copied `$ ` prompt removed, stray whitespace trimmed. Prose is left alone. `paste_tidy = false` turns it off
- Dropping files onto a terminal types their quoted paths
- Middle-click pastes in a terminal: the pane's own selection first, without touching the clipboard, else the clipboard. A program with mouse reporting on keeps the click; ⌥ or ⇧ forces the paste
- Edit › Paste Special: Paste Escaped (⌃⌘V) as one shell word that runs nothing, Paste as Base64 and Base64-Decoded, Paste File as Base64 as a heredoc for boxes with no scp, and Paste Slowly
- Advanced Paste, ⌥⇧⌘V: every paste transform plus a regex substitution in one sheet, with a preview of the exact bytes that will be sent
- Paste History, ⇧⌘H: what was pasted into and copied out of terminals. It never reads the system clipboard, skips anything a password manager marks concealed and anything in a private lane, and masks text shaped like a token or key
- A program in a terminal can set the clipboard (OSC 52), so a yank in tmux or neovim over ssh or in a remote lane reaches this Mac; a `COPIED` chip shows when one does. A program asking to *read* the clipboard is asked about every time. `osc52_write` and `osc52_read` set the policy
- Copy with Styles, ⌥⌘C: a terminal selection as RTF and HTML in the terminal's font and colours, for a doc or a bug report
- Copy mode, ⇧⌘C: a keyboard cursor over the whole scrollback with vi keys, `v` and `V` to select, `/` to find, `y` or ↩ to copy. Nothing typed reaches the program while it is on
- Private web lanes, ⇧⌘N: pages in a store that is never written to disk, no history, and gone at relaunch. A ⌘-click from one opens its sibling in the same private session
- Ad and tracker blocking in every web pane, from EasyList by default, refreshed daily. Off for one site from the lane's ⋯ menu; `blocking = false` turns it off everywhere
- Web notifications: Slack, Gmail and chat apps in a pane can ask and notify through macOS's Notification Center, once per site, and a click brings the pane forward
- Geolocation in a web pane: a site asks in the pane's sheet, once per site, and only a yes reaches macOS's location permission
- Picture-in-picture in web panes, and a pane is not unloaded while its video is in PiP
- Print (⌃⌘P) and Save as PDF for a web pane; Save as PDF writes the whole page and lands as a row in the download bar
- Pinch to zoom in a web pane, the same persisted zoom as ⌘= and ⌘-
- Web Inspector on every web pane: right-click, Inspect Element
- Sound: a web lane's sidebar square becomes a speaker while its pane plays sound. Click it to mute, right-click for a per-pane volume slider. The same speaker is on the lane header, gallery tiles, a pane's address row, folded sidebar headers, ⌘P rows and the status bar, which counts audible panes and mutes them all on a click
- Mute Pane (⌃⌘M), Mute Other Panes and Mute All in the View and lane menus; `maxpane mute`, `unmute` and `volume` from a shell. Mute and volume are remembered per pane across a relaunch, and muting never pauses
- The build carries Apple's passkeys capability when a provisioning profile grants it, and is unchanged when none does
- The version in the sidebar's corner reads `v0.6.1+43` on an unreleased build, the `+N` counting the entries under Unreleased in the changelog the build now carries; its tooltip says the commit, date and whether the tree was clean. Click it, or Help › What's New…, for the changelog itself, newest first, with `copy` on each version for a release note

### Changed
- A folded sidebar group now shows what is under it, not only its hidden count: `1 BLOCKED · 2 DONE · 1 WORKING · 3 LANES HIDDEN`, loudest first, in the row's own colours, and its triangle takes the brightest state. Click `N BLOCKED` or `N DONE` on the header to go to that session; a DONE clears when the session is looked at, as a row's does
- Selecting text in a terminal no longer copies it; ⌘C does. `copy_on_select = true` brings it back
- ⌘C in a terminal copies clean text and no longer adds an HTML flavour no app reads. `copy_trim_trailing = false` keeps trailing spaces
- Only the terminal with the keyboard blinks its cursor; in the gallery every terminal used to. `cursor_blink = "always"` or `"never"` changes it
- ⌘G is a motion in both directions instead of a cut: tiles grow out of where their lanes stood, and lanes out of their tiles
- An expanded gallery tile's seams drag, resizing its panes exactly as on the strip
- Everything a terminal sends leaves in pieces of at most 1 000 bytes, so a long paste arrives whole on sessions whose pty-host predates relay-tty 1.23, and typing cannot land in the middle of one
- Web pages no longer start playing with sound by themselves: sound needs a click, as in Safari, so a strip restored at launch stays quiet. Muted video still autoplays. `web_autoplay = "allow"` brings the old behaviour back
- A pane that is playing sound is not unloaded to reclaim memory, so music in a lane you scrolled away from keeps playing

### Fixed
- Clicking a neighbouring lane and holding the button through the slide selected a swathe of text in it. A click that moves the strip now only focuses the lane, like the first click on an inactive window; the next click is the pane's
- A video whose player muted itself (m.youtube.com in a Mobile Layout pane) plays with sound on the click that starts it, instead of needing a second click on the video
- ⌘V of a file copied in Finder pasted only its name; it now pastes the full path, quoted when it needs to be, and several files space-separated
- A middle click in a terminal pasted through the emulator's own path, which could wrap the text in bracketed-paste markers the far end never asked for

## [0.6.1] - 2026-09-16

### Fixed
- The 0.6.0 download trapped at its first terminal pane on any Mac but the build machine: libghostty's resource bundle was only found through the build directory's absolute path. The bundle now ships inside the app, and the release script launches the built app with that path hidden before packaging

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

[Unreleased]: https://github.com/ddrscott/max-pane/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/ddrscott/max-pane/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/ddrscott/max-pane/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/ddrscott/max-pane/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/ddrscott/max-pane/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/ddrscott/max-pane/releases/tag/v0.5.0
