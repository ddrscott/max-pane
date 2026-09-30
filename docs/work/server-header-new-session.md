# An expanded server header offers `+ NEW`, opening the picker aimed at that server

## Problem
After Scott connects a new relay-tty server that has no sessions, its sidebar header (`// WSL  0 SESSIONS`)
is a dead end. Nothing on screen starts a session there. The picker (⌘R, or the sidebar's top `NEW`)
already runs a line on a named server when it starts with `@wsl `
(`OmniServerPrefix` in `Views/OmniPicker.swift`), but nothing tells you that. Scott expected expanding the
server's header to offer a way in.

## Acceptance Criteria
- An **expanded** server header shows a `+ NEW` control at its right end, next to the `⋯` added by the
  server-header-click-folds task (`queue.md`, line 93). This covers each remote server and also `// LOCAL`. It
  stays visible, not only on hover, because the empty-server case is the one that matters. A folded
  header doesn't show it. Showing and hiding follow the fold on `Motion` timing and respect Reduce Motion.
- A click on it opens the same picker as `.openAnything`, with `@<server> ` already typed and the caret
  after it, so the first row runs on that server. For `// LOCAL`, it's the plain picker or `@local `,
  whichever reads better in the picker. Say which one you picked in the commit.
- A click on `+ NEW` never folds the group, and it doesn't open the `⋯` menu.
- On a disabled or unreachable server, hide or grey it the same way `⋯` handles the offline state, and
  give it a tooltip that says why. It must never start something that silently fails.
- Tooltip: "New session on <server> (⌘R, then @<server>)" or similar.
- Visual: square corners, the same button style as the sidebar's top `NEW` (`look: .accent`, `.plus` icon,
  about 11pt), and no bubble. Accent colors follow the Max Pane identity memory, which uses greens for accents.
- Tests: an expanded server header has the control and a folded one doesn't. A hit opens the picker
  pre-filled with `@<name> `. A hit doesn't fold. Directory-group headers (e.g. `~/life`) don't get it.
- README sidebar section and a CHANGELOG Unreleased entry.

## Relevant Files
- swift/MaxPane/Sources/MaxPaneKit/Views/SidebarRowViews.swift (group header view, ~460–640)
- swift/MaxPane/Sources/MaxPaneKit/Views/SidebarViewController.swift (`newButton` ~197, header clicks, `onNewSession` ~76)
- swift/MaxPane/Sources/MaxPaneKit/StripWindowController.swift (`sidebar.onNewSession` ~277, `.openAnything` ~1178)
- swift/MaxPane/Sources/MaxPaneKit/Views/OmniPicker.swift (`OmniServerPrefix`, picker's initial text)

## Constraints
- Server headers only. Directory/cwd groups and bookmark folders don't change.
- Don't spawn anything directly. The control only opens the picker, so the person still chooses what runs.
- Folded-header roll-up reach-through (ADR-0024) and the header-click-folds behavior stay as they are.
- Workers must not launch, quit or replace the installed app.
