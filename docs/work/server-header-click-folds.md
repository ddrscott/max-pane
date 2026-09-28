# A click on a server's sidebar header folds it; a ⋯ button holds the server menu

## Problem
Clicking a remote server's header in the sidebar (`// WSL`) opens Settings › Servers. Scott expects a
header click to fold and unfold the group, like `// LOCAL` and every other header. Only the little
triangle folds a server today (`SidebarViewController.swift` ~line 552, `onOpenServer`), which is a
small target and a surprise. The server's actions should live behind a visible `⋯` instead.

## Acceptance Criteria
- A click anywhere on a server header (triangle, name, status text, counts) folds/unfolds it, exactly
  like `// LOCAL`. Keep the existing exception: on a *folded* header, a click on its `N BLOCKED` /
  `N DONE` roll-up still reaches through to that session (ADR-0024).
- The header gets a `⋯` button at its right end, opening the same menu right-click opens today
  (`serverMenuItems(for:)`: Color ▸, Rename…, Disable, Server Settings…). Right-click keeps working.
  The `⋯` shows on hover and while the header's server is unreachable/offline (so the way to fix it is
  visible when it matters), fades on `Motion` timing, reduce-motion aware. Square, no bubble.
  A click on `⋯` never folds the group.
- Tooltips on server headers stop saying "click for Settings › Servers" and describe the new behaviour.
- The offline/unreachable state still offers a one-click route to Settings › Servers through the `⋯`
  menu (Server Settings… stays in it).
- Tests: header click folds a server group (not triangle-only); `⋯` hit opens the menu and does not
  fold; folded roll-up reach-through still works; right-click menu unchanged.
- README sidebar section, CHANGELOG Unreleased, and an amendment note on ADR-0023 (it said the header
  body is the way to Settings › Servers).

## Relevant Files
- swift/MaxPane/Sources/MaxPaneKit/Views/SidebarViewController.swift (~540–560 click, ~980 server menu)
- swift/MaxPane/Sources/MaxPaneKit/Views/SidebarRowViews.swift (~352 header view, ~580/607 tooltips)
- docs/decisions/0023-one-truth-per-server-and-the-server-chip.md

## Constraints
- Don't change `// LOCAL` or bookmark folder behaviour.
- The comment at ~982 says headers have no `⋯` "so none was invented"; this task invents one on purpose
  for server headers only. Update that comment.
- Workers must not launch, quit or replace the installed app.
