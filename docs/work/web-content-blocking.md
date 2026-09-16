# Ad and tracker blocking in web panes

## Problem
Nothing in the app compiles a `WKContentRuleList`. YouTube, news sites and
most of the commercial web are unusable for long without blocking, and this is
the single biggest reason a web pane sends Scott back to Vivaldi (which runs
uBlock Origin). Found 2026-09-16 while surveying the browser half against a
daily-driver bar; see [gauntlet-browser.md](../gauntlet-browser.md) for the bar.

## Acceptance Criteria
- A rule list in WebKit's content-blocker JSON format is compiled through
  `WKContentRuleListStore` once, cached in the store's own directory, and added
  to every `WKWebViewConfiguration` the app builds — the pane's in
  `buildWebView` and the popup's (which inherits the pane's configuration;
  prove that the list is present on it rather than assume).
- The source list is fetched from a URL Scott can configure (default: a
  maintained EasyList + EasyPrivacy conversion in WebKit format), refreshed on
  a schedule, and falls back to the last compiled list when offline. First
  launch with no cache must not block the window; compile in the background
  and add the list to live views when ready.
- A per-site off switch: a lane's ⋯ menu item and a `Command` (`toggleBlocking`
  or similar, bindable through `keys`) that disables blocking for the current
  registrable domain, kept in the ledger like `mobile` is per pane, and shown
  on the address bar with a small indicator (an outline chip, no orange).
- A config key (`blocking = true|false`, plus the list URL) in `Config`,
  `ConfigField` and the settings popup, following the settings-ui conventions
  (a Mirror test fails on a `Config` property without a row).
- Tests: a real WebKit test in the style of `WebFullscreenTests` serves a page
  from a loopback port that requests a resource matching a rule, and asserts the
  request does not arrive; a second test proves the popup's view carries the
  list; a third proves the per-site switch lets it through.
- Blocking a resource must never break `PaneFullscreen` or `LinkHoverProbe`
  (both are user scripts, not resources, but the YouTube player is the case to
  drive by hand).

## Relevant Files
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift` (`buildWebView`)
- `swift/MaxPane/Sources/MaxPaneKit/Views/WebPopupDialog.swift`
- `swift/MaxPane/Sources/MaxPaneKit/Config.swift`, `ConfigSchema.swift`, `Views/SettingsWindow.swift`
- `swift/MaxPane/Sources/MaxPaneKit/Commands.swift`
- `crates/laned-core` if the per-site state lives in the ledger

## Constraints
- WebKit's compiled rule list has a 150,000-rule ceiling per list; split large
  lists rather than fail silently. Log the rule count and compile time at
  `Log.debug`.
- No network on the main thread; no compile on every launch (the compiled store
  is the cache).
- Do not ship a list inside the bundle as the only source — lists go stale.
  Shipping one as the offline fallback is fine.
- Animations and the visual identity rules in the README apply to any chrome
  added (indicator, menu item).
