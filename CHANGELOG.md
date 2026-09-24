# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- ⌃⌘S Capture Pane: a PNG of the focused pane, with its quoted path typed at the nearest prompt in that lane — the pane under or over it in a split, or the terminal itself — so "look at this rendering bug" no longer leaves the app. ⇧⌃⌘S is the whole web page, below the fold and not just the screen, and is greyed on a terminal, which has no fold. A lane with no terminal copies the path instead and says `COPIED`. The file lands where a pasted picture lands (`capture-….png`, same `paste_image_keep_days`), uploaded to the server first when the prompt that will read it is a remote session. A terminal is read through the view's own layer, so **no Screen Recording permission is asked for**; a pane that has not drawn yet says so rather than writing a blank PNG. `maxpane capture [LANE] [--full]` prints the path, so an agent can ask for its own screenshot (ADR-0040)
- The Mac's clock, battery and network at the right of the status bar while the window is fullscreen and the menu bar is away: `14:32 · 78% ⚡ · wifi` in the footer's mono grey, the battery in the hard-limit red under 15 % (never a green), `⚡` on power, no battery segment on a desktop, and only the interface kind for the network — no SSID. The clock ticks on the minute, the battery follows IOKit's power-source notification and the network `NWPathMonitor`; windowed, nothing runs. `status_clock = false` takes it away, live
- ⌃⌘W End Session, in File under Close Lane and last in the lane's ⋯ menu: a sheet naming the session, its program and its machine, ↩ on Cancel, then the session is killed — `SIGTERM` to pty-host's pid on this Mac, `DELETE /api/sessions/:id` on a remote server, what relay-tty's own *stop session* does — and its pane closes, the lane with it when the pane was its last. A refusal leaves the lane and says why. ⌘W and ⇧⌘W still only detach (ADR-0039)
- ⌘K Clear Scrollback in a terminal pane: Ghostty's `clear_screen`, the scrollback and every row above the cursor, in this pane's emulator only; relay's ring and the phone are untouched. In a web pane ⌘K stays the page's
- Rename Lane: double-click the header, ⋯ › Rename Lane…, or ⌃⌘R. The name goes to the ledger and, for a terminal lane, is pinned on the session with `SET_TITLE` (relay's `rename`), so the program's own titles stop replacing it and every client sees it; empty unpins. A web lane's name lasts until the page next sets a title
- The app knows when a release is out: GitHub's `releases/latest` is read once a day and on Help › Check for Updates…, and a newer one puts `↻ v0.8.0` at the right of the status bar and a `// UPDATE` block at the top of the version popover. Help › Update…, the `↻` or the popover's line runs `brew upgrade --cask max-pane` (or `update_command` from `config.toml`) in a terminal lane that stays open when it ends: exit 0 puts `$ RELAUNCH` on its banner, which starts the new build with a clean environment once this one has quit. Without Homebrew the release page opens in a web lane instead. relay-tty's version is checked on the same tick and named when it is under 1.22.0. A check that cannot reach github.com is one line on stderr and nothing on screen (ADR-0038)
- ⌘E Run Command: ⌘O's picker with an `APP` scope, also reached by typing `>` into ⌘O or by ⇥. Every command by its menu name with the key `[keys]` gives it on the right (`—` for none), greyed with the reason when the menu would grey it; the live boolean and choice settings with their value, which ↩ flips or cycles in `config.toml`; and Reconnect, Enable or Disable and the next Colour per server. ⌘⌫ on a command records the next chord into `[keys]` the way Settings › Keyboard does, refusing one macOS owns or another command already has, by name. Never a shell line
- An agent going BLOCKED or DONE while Max Pane is not the frontmost app posts a macOS notification — its title, `BLOCKED · ~/code/x`, and the last line on its screen — and a click goes to it, opening a fold or attaching the session on the way. Taken down again when the session moves on; never for a server that is not answering or at a relaunch. `agent_notify = "away" | "always" | "never"`, live. The Dock icon carries the BLOCKED count as a badge (ADR-0037)
- ⌘J Next Attention and ⇧⌘J Previous Attention: every BLOCKED session in strip order, then every DONE, walked from the lane you are in and wrapping, through a folded group or a gather like ⌘P
- ⌥⌘J Attention: a `// ATTENTION · N` list from the status bar, one row per BLOCKED or DONE session. ↩ goes, ⌫ dismisses a DONE (never a BLOCKED), ⌘⌫ dismisses every DONE
- In the gallery with a tile expanded, ⌘[ and ⌘] put it back and expand the previous or next lane, both tiles moving at once, so the lanes can be read through from the keyboard. ⇧⌘[ and ⇧⌘] do the same, walking a split lane's panes first and crossing at its top or bottom. The ends stop rather than wrap
- ⌃V in a remote lane with a picture and nothing else on the clipboard does what ⌘V does: uploads it through the relay server and pastes the server's path, with the pane saying `⌃V · uploading…`. Claude Code's own ⌃V reads the clipboard of the machine it runs on, which over there has no picture. Every other ⌃V — text or files on the clipboard, an empty one, a local lane, `paste_images_as_files = false` — is still the byte

### Changed
- The window comes back where you left it: fullscreen, or its frame on its display, remembered per profile in the ledger and restored at launch, clamped onto a screen that still exists when a display has gone or shrunk. The first launch, with nothing remembered, is fullscreen as before. `MAXPANE_WINDOWED` still forces windowed and remembers nothing (ADR-0036)

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

[Unreleased]: https://github.com/ddrscott/max-pane/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/ddrscott/max-pane/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/ddrscott/max-pane/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/ddrscott/max-pane/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/ddrscott/max-pane/releases/tag/v0.5.0
