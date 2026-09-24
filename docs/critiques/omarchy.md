# Omarchy as the bar — what still pulls Scott out of Max Pane

A read-only critique, 2026-09-23, against Omarchy 3 (omarchy.org; the manual at
learn.omacom.io/2/the-omarchy-manual and omarchy.org/manual) and Max Pane at
`8984d0b` (README, `Commands.swift`, ADR index, CHANGELOG 0.7.0, the three earlier
critiques). Nothing was built or run.

## 1. Frame

Omarchy's "command center" is four things stacked: one modifier (Super) that
reaches every action from any window ("Everything in Omarchy happens via the
keyboard — EVERYTHING!", manual › Navigation); one launcher that opens apps, web
apps and clipboard history alike (Walker, `Super+Space`, `Super+Ctrl+V`); one
bar that carries ambient state and the *update-available* mark (Waybar: "a
circle arrow icon will appear to the right of your clock", manual › Updates); and
one menu that owns install, update, theme and settings without leaving the
keyboard (`Super+Alt+Space`, `omarchy menu`). Tiling and workspaces are the fifth
thing and they are the one Max Pane cannot have: it is one app, not a window
manager (ADR-0008 gates even multi-display; PRD §3), so nothing below asks it to
place other apps. What transfers is everything inside the window: a launcher
that also *runs commands*, a status band that answers the questions the macOS
menu bar answers when fullscreen has hidden it, an attention model that beats
Mako for agents, and a system menu whose update button works.

## 2. What Max Pane already does better than Omarchy for this owner

- **Agent state is a first-class colour.** WORKING green, BLOCKED brightest and
  breathing, DONE orange, promoted to group headers and the status bar
  (README › Colour, › Folding). Omarchy has no notion of "an agent is waiting";
  Mako shows whatever the app pushed.
- **One door, everything.** ⌘O offers commands, URLs, history, bookmarks and
  running sessions ranked together (README › Using it). Walker launches apps; it
  does not know a running tmux session from a bookmark.
- **The gallery.** Every lane live on one screen, answer `y` from the tile
  (README › The gallery). Hyprland's overview shows windows, not prompts.
- **Paste as an engineered surface.** Tidy, risky-paste sheet, Paste Special,
  Advanced Paste, screenshot-to-path, remote upload (ADR-0026..0032). Omarchy's
  `Super+V` is a plain paste.
- **⌘/ is generated from the enum** so it cannot drift; Super+K is a hand-kept
  list.
- **Remote sessions as peer lanes** with server colour and liveness in ≤ 13.5 s
  (ADR-0020..0025). Omarchy has ssh.

## 3. Findings, ranked by how hard each pulls him out

### F1. Nothing calls him back once he has left the window
**Omarchy.** Mako notifications with `Super+,` dismiss, `Super+Shift+,` dismiss
all, `Super+Ctrl+,` silence (manual › Hotkeys › Notifications).
**Max Pane.** A DONE or BLOCKED "while the app is not in front bounces the Dock
icon once" (README › The session browser). Web pages may post to Notification
Center (README › Web notifications); the app's own agents may not. There is no
"next thing that needs me" key; the only path is a *click* on `N BLOCKED` in the
status bar (README › Folding). DONE clears on look, so what finished while he was
in Slack is gone from the record.
**Gap.** The moment he is in another app, the one thing the product exists for
(an agent stopped) reaches him as a single bounce he can miss.
**Change (M).** (a) A `UNUserNotification` per session transition to BLOCKED or
DONE while the app is not frontmost, titled with the lane title and cwd,
body = last non-empty line; click focuses that pane (opening a fold, as ⌘P
does). Setting `agent_notify = "away" | "always" | "never"`, default `away`;
a dead server posts nothing (ADR-0023). (b) `⌘J` *Next Attention*: BLOCKED first
(strip order from the focused lane, wrapping), then DONE; `⇧⌘J` previous. (c) An
ATTENTION list, `⌥⌘J`, a square mono popover from the status bar: one row per
BLOCKED/DONE session, `↩` goes, `⌫` dismisses a DONE, `⌘⌫` dismisses all; a
Dock badge carries the BLOCKED count. Identity: rows grey, BLOCKED chip
brightest green pulsing, DONE the only orange; `// ATTENTION · 3` header.

### F2. Fullscreen hides the Mac's own bar, and the status bar does not replace it
**Omarchy.** Waybar is always there: workspaces, clock, battery, weather, tray,
update icon (manual › Overview, › Updates).
**Max Pane.** First launch is fullscreen, and the window comes back fullscreen if
left that way (ADR-0036). The status bar reads `4 lanes · 3 hidden`, `N BLOCKED`,
the speaker, `5 sessions · 3 offline` (README › Sound, › Remote servers). No
clock, no battery, no network, no update mark.
**Gap.** He leaves fullscreen (or the app) to learn the time or whether the
laptop is about to die.
**Change (S).** Right end of the status bar, only while the window is fullscreen:
`14:32 · 78% ⚡ · wifi` in JetBrains Mono, grey; battery under 15 % takes the
red that already means "past the hard limit" (README › Colour), never a green.
Windowed, nothing (the menu bar has it).
Setting `status_clock = true`. No weather, no tray.

### F3. Half the commands have no key and no launcher row
**Omarchy.** Walker runs anything by name; the menu reaches every setting with a
typed prefix (`omarchy menu summon style.theme`, manual › Omarchy CLI).
**Max Pane.** `Command` has 75 cases; `bookmarkPage`, `gather`, `ungather`,
`pasteAsBase64`, `pasteSlowly`, `clearPasteHistory`, `laneSize*`,
`toggleMobileLayout`, `toggleBlocking`, `muteOthers`, `muteAll`, `savePDF`,
`showChangelog` ship with `nil` (`Commands.swift` › `defaultChord`). They are
reachable only through the menu bar or a lane's `⋯`. ⌘O runs *things*; it does
not run *Max Pane*.
**Gap.** Anything unkeyed is a mouse trip up to the menu bar, which is what the
menu bar is for and exactly what an Omarchy user never does.
**Change (S).** `⇧⌘P` *Run Command*: the OmniPicker with a fourth scope
(⇥ cycles pages / commands / sessions / **app**) listing every `Command` by
title with its chord on the right, plus the live toggles from Settings
(`theme`, `copy_on_select`, `paste_tidy`, `blocking`) as rows that flip, plus
server actions (`connect`, `disable`, `color`). Typing `>` in ⌘O jumps to the
scope, as VS Code does. `⌘⌫` on a row binds it: the picker asks for a chord
(same recorder as Settings › Keyboard). Refused: rows that run a shell.

### F4. One modifier in Omarchy; six modifier flavours here
**Omarchy.** Every hotkey hangs off Super; the cheat sheet is one key
(`Super+K`).
**Max Pane.** `[` / `]` carry four meanings by modifier (`⌘` focus, `⇧⌘` pane
up/down, `⌃⌘` dock, `⌥⌘` focus dock) and the paste family spans `⌘V ⌥⌘V ⌃⌘V
⌥⇧⌘V ⇧⌘H`; `claimSession` is `⌃⇧⌘R` and `importBrowserPasswords` is `⌃⌥⌘Y`
(`Commands.swift`). ⌘/ lists them, but a list is not a vocabulary.
**Gap.** The chords are learnable, not guessable, and web pages contest several
of them (`Command.yieldsToPage`).
**Change (M).** A leader: `⌘;` opens a 300 ms-delayed which-key overlay at the
foot of the focused lane — square, mono, `// LEADER` — showing the next keys by
family (`d` dock, `p` paste…, `s` sessions, `l` lane size, `t` theme). Every
leader sequence is an alias for an existing `Command`, spelled in `[keys]` as
`"cmd+; d l"`; Esc cancels; a wrong key shows `? no such key` and stays. Web
panes never see the sequence. The overlay's rows reuse ⌘/'s renderer so the two
cannot drift. Not a replacement for any existing chord.

### F5. Clipboard history stops at the terminal's edge
**Omarchy.** `Super+Ctrl+V` opens Walker's clipboard history, images included
(manual › Coming from Mac).
**Max Pane.** Paste History (⇧⌘H) records "what terminals pasted and copied,
never the clipboard" (ADR-0031); a ⌘C in a web lane is not recorded, nor is a
picture copied from a page, and a screenshot only becomes a path at the moment
of ⌘V (ADR-0027).
**Gap.** Copy a token off a web dashboard, copy something else, and the first is
gone; he opens Raycast or Maccy.
**Change (S).** Keep ADR-0031's line (the pane writes, the app never polls) and
widen it: a ⌘C the *app* performs in a web pane (`WKWebView` copy through the
pane's responder, `copy:`) records to `clip` under source `web`, the same
secret-masking, never in a private lane. A picture copied by that route is saved
under `paste_image_*` rules and recorded as its path. ⇧⌘H rows carry a `web` /
`pty` chip and ↩ pastes into the focused terminal. Refused: reading
`NSPasteboard.changeCount` on a timer.

### F6. A screenshot of the agent's own work takes two apps
**Omarchy.** `Print Screen` screenshot, `Alt+Print` recording, `Super+Ctrl+C`
capture menu, `omarchy capture text` OCR (manual › Hotkeys, › Omarchy CLI).
**Max Pane.** A macOS screenshot on the clipboard pastes as a path (README ›
Pasting). Capture itself is `⇧⌘4`, outside the app, and a web lane's page
cannot be captured whole.
**Gap.** "Look at this rendering bug" is: leave, ⇧⌘4, drag, come back, ⌘V.
**Change (S).** `⌃⌘S` *Capture Pane*: PNG of the focused pane's contents (a
web pane through `takeSnapshot`, full page with ⇧; a terminal through the
emulator's layer), written under the profile's Caches like a pasted picture,
its quoted path typed into the nearest terminal in the same lane (or copied,
with the `COPIED` chip, when there is none); in a remote lane uploaded first
(ADR-0027 path). `maxpane capture LANE` from a shell so an agent can ask for it.
No recording, no OCR.

### F7. Update is a shell incantation the app never mentions
**Omarchy.** "Update › Omarchy" in the menu, an icon on the bar when a release is
ready, a snapshot taken first, four channels (manual › Updates).
**Max Pane.** `brew install --cask ddrscott/tap/max-pane` (README › Install), and
"the CLI and the app must be from the same build" (README › Profiles). The
version corner knows its commit and reads the changelog (README › The version in
the corner); it does not know the tap has moved on.
**Gap.** He learns of a release from GitHub, in a browser, then types the upgrade
somewhere and relaunches by hand — which the memory says must never be from a
Claude-driven terminal.
**Change (M).** A check against the release feed, once a day and on Help ›
Check for Updates; when newer, `↻ v0.8.0` at the right of the status bar and in
the version popover. *Update…* opens a terminal lane running `brew upgrade
--cask max-pane` (the shipped path; `update_command` overrides it), watches its
exit, and on 0 offers *Relaunch* in the same lane's footer (export strip first,
ADR-0036 restore after). Refused: Sparkle, a background download, silent
relaunch. The relay-tty minimum version is checked on the same tick and named
when short.

### F8. Web apps have chords in Omarchy; here they have a row number
**Omarchy.** `Super+Shift+E` HEY, `Super+Shift+A` ChatGPT… installed by "Install ›
Web App" with a name, URL and icon (manual › Web Apps).
**Max Pane.** A bookmark is a ★ row in ⌘O, `⌘4` opens the fourth row *of the
current ranking* (README › Using it); ⌘P finds an open one. Nothing is
"go to Gmail" whether or not it is open.
**Gap.** The muscle-memory key Omarchy gives an app does not exist; ⌘4 means
something different every hour.
**Change (S).** `[[apps]]` in `config.toml`: `name`, `url`, `key`, optional
`docked = "left"`. The chord *focuses* the lane whose pane is on that origin,
else opens it (docked if asked). Listed in ⌘/ under `// APPS`, in Settings ›
Apps with the chord recorder, in `⇧⌘P`, and `maxpane app NAME`. A key a web
page wants yields to `[keys]`' existing rule.

### F9. Theme means light or dark, and the terminal palette is fixed
**Omarchy.** 19 coordinated themes, `Super+Ctrl+Shift+Space` to pick, a
`colors.toml` for one's own (manual › Overview, › Themes).
**Max Pane.** `theme = system | light | dark`; terminals are Afterglow or
Alabaster and nothing else (README › Light and dark).
**Gap.** Small: he does not leave the app for this, but every other terminal
lets him pick a palette, and Ghostty ships hundreds.
**Change (S).** `terminal_theme = { dark = "...", light = "..." }` naming
Ghostty themes, live, with a picker in Settings and a `theme` row in `⇧⌘P`;
`font_size` becomes live with `⌘=`/`⌘-` in a terminal pane (they already zoom
a web pane). The chrome stays as ADR-0015 says; no app-wide theme packs.

### F10. Still unfixed from day-one: no way to end a session
Day-one #5 stands: no kill, clear-scrollback or rename command exists
(`Commands.swift`; `rg kill` finds only liveness probes). Omarchy's `Super+W`
closes; here ⇧⌘W detaches and the row lives on. **Change (S).** `⌃⌘W`
*End Session* with a sheet defaulting to Cancel; `⌘K` clears scrollback;
rename from the lane header. Still the cheapest win in this file.

## 4. Not worth doing

- **Tiling other apps or workspaces.** Ruled out (ADR-0008, PRD §3); the strip
  is the workspace.
- **Universal `Super+C/V`.** macOS already has one clipboard chord; the paste
  work is deeper than Omarchy's.
- **Nineteen themes.** ADR-0015 and the identity rules make the chrome one
  thing on purpose; the terminal palette is the only free variable (F9).
- **Screen recording, OCR, QR, webcam overlay.** Not on the path between him
  and an agent; macOS's own tools are one key away.
- **Update channels and boot snapshots.** One person, one tap; strip export
  is the snapshot.
- **A frameless web-app window.** A web lane already is one, in the place the
  agent's terminal sits.

## 5. The three to do first

1. **F1 — notifications and `⌘J`.** The only finding that reaches him *outside*
   the app, and the one Omarchy cannot match for agents.
2. **F3 — `⇧⌘P` Run Command.** Cheapest way to make every unkeyed command and
   setting keyboard-reachable; F8 and F9 then ride on it.
3. **F7 — the update lane.** Closes the last brew-in-another-terminal trip, and
   ties the version corner to something it can act on.
