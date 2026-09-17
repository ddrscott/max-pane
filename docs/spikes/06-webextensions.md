# Spike M6 — WebExtensions through `WKWebExtension`, against the macOS 14 floor

**Question** ([`docs/work/web-extensions.md`](../work/web-extensions.md)): macOS 15.4
made WebKit's extension host public — `WKWebExtension`, `WKWebExtensionController`,
`WKWebExtensionContext`. The app promises macOS 14. Can a real extension run in a
656 pt pane without moving that promise, and what does it cost per pane when
ADR-0003 says every pane is its own WebContent process?

**Verdict: go, behind `#available(macOS 15.4, *)`. The floor stays at 14.**

- **Weak-linking works.** The spike binary is built with `-target arm64-apple-macos14.0`,
  and every `WKWebExtension*` class is an `(undefined) weak external` in `nm -m`.
  It runs on this machine; on macOS 14 the guard is the only thing that runs.
- **Dark Reader 4.9.132 (MV3) works in a pane**: parsed in 2–3 ms, loaded in 72–90 ms,
  and its content script has restyled the page **66–97 ms after the load starts**.
  Its popup renders complete in an `NSPopover` at **276 × 580 pt**, which fits a
  656 pt lane with room. Its ⌥⇧D command reaches it and toggles the theme.
  Refined GitHub 26.9.12 injects on github.com in the same harness.
- **It costs 5.2 MB per pane** (Dark Reader: 12.3 → 17.5 MB `phys_footprint` per
  WebContent process, six panes), **plus one extension process** of 15 MB idle,
  29 MB with six pages talking to it, 56 MB with the popup open. Popup and
  background share that one process.
- **Two things WebKit does not tell you**, each of which cost this spike a run:
  a `.nonPersistent()` data store is private browsing, and extensions do not
  inject there until `hasAccessToPrivateData` is set; and a non-persistent
  background worker is **not** started by a content script's first
  `runtime.sendMessage` — the host has to call `loadBackgroundContent`.
- **One prompt.** With the host pattern ungranted, WebKit raised
  `promptForPermissionToAccess urls:` for the page URL 32 ms into the load, and
  nothing else in any run. Granting it there was enough.

---

## Environment

| | |
|---|---|
| Machine | MacBook Pro, Apple M3 Pro, 36 GB |
| OS | macOS 26.6.2 (25G83) |
| Toolchain | Apple Swift 6.3.3, Command Line Tools SDK 26.5; no Xcode |
| Extensions | Dark Reader 4.9.132 `darkreader-chrome-mv3.zip` (MIT); Refined GitHub 26.9.12 `*-for-local-testing-only.zip` (MIT); both unpacked, loaded with `WKWebExtension(resourceBaseURL:)` |
| Pane | `WKWebView` 656 × 1000 pt, one per `NSWindow`, one level below the desktop picture |
| Page | `fixtures/page.html`, white, served by `python3 -m http.server` on 127.0.0.1 |
| Memory | `proc_pid_rusage` `ri_phys_footprint`, MiB, sampled 12 s after the last page load, WebKit processes alive before launch excluded — spike M1's method |

The spike app is an accessory (`LSUIElement`) and never activates. The window
landed on the 1× panel, so snapshots are 656 × 1000 px and `devicePixelRatio` is 1.

Panes get a **persistent identifier store**, as the app's do (ADR-0003), created
for the run and removed at exit. The extension controller's own configuration is
`nonPersistent()`, so every run is a first install. `MAXPANE_LEDGER` and
`MAXPANE_DATA_SALT` were not needed: nothing here touches the app or its profiles.

## How to re-run

```sh
cd spikes/m6-webextensions
EXT_DIR=/path/to/unpacked/darkreader RG_DIR=/path/to/unpacked/refined-github ./run.sh
```

`build.sh` alone answers the linking question: it prints the weak symbols and
`minos`. `run.sh` runs eight phases and leaves `report-*.json`, snapshots and the
console under `out/<stamp>/`. Nothing in `out/` is committed.

---

## 1. The floor

`swift/MaxPane/Package.swift` and `swift/MaxPaneCore/Package.swift` say
`.macOS(.v14)`; `Info.plist` says `LSMinimumSystemVersion 14.0`; the shipped
binary's `LC_BUILD_VERSION` says `minos 14.0`. The promise is written in six
more places: README (Install, and again under Requirements), CHANGELOG 0.6.0,
`packaging/Casks/max-pane.rb` (`depends_on macos: :sonoma`), and the Product
Hunt copy. Raising the floor to 15.4 means changing all of them and dropping
every Sonoma and pre-15.4 Sequoia Mac from the cask.

**None of that is necessary.** `build.sh` compiles the spike with
`-target arm64-apple-macos14.0`, the same target SwiftPM derives from `.v14`,
and the extension API compiles behind `if #available(macOS 15.4, *)`:

```
(undefined) weak external _OBJC_CLASS_$_WKWebExtension (from WebKit)
(undefined) weak external _OBJC_CLASS_$_WKWebExtensionContext (from WebKit)
(undefined) weak external _OBJC_CLASS_$_WKWebExtensionController (from WebKit)
(undefined) weak external _OBJC_CLASS_$_WKWebExtensionControllerConfiguration (from WebKit)
(undefined) weak external _OBJC_CLASS_$_WKWebExtensionCommand (from WebKit)
(undefined) weak external _OBJC_CLASS_$_WKWebExtensionMatchPattern (from WebKit)
minos 14.0
sdk 26.5
```

Ten weak imports in all; the other four are the Swift overlay's refinements
(`init(resourceBaseURL:) async throws`, `didActivateTab(_:previousActiveTab:)`),
weak too. The compiler enforces the guard: an unguarded reference is an error,
not a warning, under a 14.0 target. Conforming classes carry
`@available(macOS 15.4, *)`, and the app holds its controller as an
existential so the file compiles whole.

**Not run on macOS 14.** There is no such machine here. The claim rests on the
linkage above and on `#available` being the mechanism Apple documents for
exactly this; the risk is a missed guard, which the compiler catches.

## 2. Loading one real extension

Dark Reader, from `WKWebExtension(resourceBaseURL:)` on the unpacked directory:

| | Dark Reader 4.9.132 | Refined GitHub 26.9.12 |
|---|---|---|
| `manifest_version` | 3 | 3 |
| parse | 2–3 ms | 3 ms |
| `controller.load(context)` | 72–90 ms | 90 ms |
| `loadBackgroundContent` | 133–156 ms | 156 ms |
| `errors` | none | none |
| background | service worker (`hasPersistentBackgroundContent` false) | service worker |
| requested permissions | `alarms`, `scripting`, `storage` | `activeTab`, `alarms`, `contextMenus`, `scripting`, `storage` |
| requested host patterns | `*://*/*` | `https://github.com/*`, `https://api.github.com/*` |
| optional | `contextMenus` | `*://*/*` |
| commands | `toggle` ⌥⇧D, `addSite` ⌥⇧A, `switchEngine`, `_execute_action` | `_execute_action` |
| `hasContentModificationRules` | false | false |
| action | popup `ui/popup/index.html` | no popup; four `menuItems` |

Both are Chrome builds. WebKit read them as they are.

### Injection

The spike grants the manifest's `permissions` at load, the way every browser
does at install, and varies host access. Pane 0 is polled every 100 ms for
Dark Reader's own markers — `data-darkreader-mode` on `<html>` and its
`<style class="darkreader">` elements.

| panes' data store | `hasAccessToPrivateData` | host access | content script ran | after load began |
|---|---|---|---|---|
| persistent (identifier) | false | granted | **yes**: `mode=dynamic`, `scheme=dark`, 9 styles, body `rgb(24, 26, 27)` | **66–97 ms** |
| persistent | false | ungranted | yes, after WebKit's URL prompt was answered | 79 ms |
| `.nonPersistent()` | false | granted | **no**, in 10 s | — |
| `.nonPersistent()` | **true** | granted | yes | 66 ms |

The third row is a full run of this spike that looked like "content scripts do
not work". `hasAccess(to:)` said true, `hasInjectedContent(for:)` said true,
`permissionStatus` said granted, `errors` was empty, and the page stayed white.
An ephemeral session **is private browsing to WebKit**, and an extension has no
access to private data until the host says so — Safari's "Allow in Private
Browsing", with no UI here to hint at it. The app's private lanes are
`.nonPersistent()` by design, so this is the rule for them: **extensions stay
out of private lanes unless the setting says otherwise**, which is the behaviour
a browser user expects anyway.

The fourth column's "no" was confirmed with a 40-line extension of the spike's
own (`fixtures/mini-ext`), whose content script only stamps
`<html data-m6="content-script-ran">`, so that "WebKit did not inject" could be
told from "Dark Reader did not act".

### The background worker has to be woken

That mini extension's content script also does one `chrome.runtime.sendMessage`
and stamps the reply. Without `loadBackgroundContent`: **no reply, three runs
of three**, and a Dark Reader run in the same state ended with only its
`document_start` fallback stylesheet on the page (one `<style>`, no `mode`, a
dark body and nothing else — the theme never arrived). With
`context.loadBackgroundContent` called once after `load(_:)`: **five of five
replied**, and Dark Reader's full theme landed in under 100 ms every time.

WebKit does start a non-persistent worker for events it registered listeners
for — the ungranted run below proves the worker was alive, because it is what
asked for the URL — but a content script's first message is not one of them.
A browser calls `loadBackgroundContent` at launch; so must the app, once per
extension, 140 ms each.

### Prompts

The delegate implements all three prompt methods and logs each call.

| delegate method | called |
|---|---|
| `promptForPermissionToAccess urls:` | **once**, host pattern ungranted: the page URL, `tab: nil`, 32 ms after the load began |
| `promptForPermissions` | never |
| `promptForPermissionMatchPatterns` | never |

Before the prompt `permissionStatus(for: url)` was `-1`
(`requestedImplicitly`). Granting the URL from the completion handler was
enough: injection followed 47 ms later. WebKit asks per URL, which is the
per-origin grain the app already asks at for geolocation and notifications, so
the ask goes through `WebAskCenter` like the others.

## 3. The popup in a 656 pt lane

`context.action(for: tab)` returns a `WKWebExtension.Action` with `label`
"Dark Reader", a 16 pt icon, empty `badgeText`, `isEnabled`, and
`presentsPopup`. `performAction(for: tab)` calls the delegate's
`presentActionPopup`, which hands over both a `popupWebView` and a
`popupPopover`; both report zero size at that moment. The spike shows the
popover from a 24 pt rect at the pane's top-right, the way a toolbar button
would, and measures the document once it is `complete`:

| | |
|---|---|
| `NSPopover.contentSize` | **276 × 580 pt** |
| `popupWebView.frame` | 276 × 580 at (13, 13) inside the popover |
| popup document | 276 × 580, `<body>` 240 px wide, title "Dark Reader settings" |
| polls to settle | 0 — sized on first read |
| fits 656 | yes, 380 pt to spare |

The snapshot (`out/…/popup.png`) is the whole Dark Reader UI: On/Off, the
current site's host — so `tabs.query({active: true})` resolved through the
spike's `WKWebExtensionTab` — Filter, Site list, brightness and contrast
controls. Refined GitHub has no popup; its action exposes four `NSMenuItem`s
(Options, Enable on this domain, Reload without, Reload and identify feature),
which is the other shape a browser-action button needs to handle.

## 4. Commands

`context.commands` had all four, with ⌥⇧D and ⌥⇧A as `activationKey` and
`modifierFlags`. A synthesised `NSEvent` for ⌥⇧D went through
`context.command(for:)` — matched `toggle` — and `performCommand(for:)` returned
true; 1.5 s later the page was white again, `mode` gone, zero styles. So
extension shortcuts work, and they will collide with the app's own: Dark Reader
takes ⌥⇧D and ⌥⇧A globally by default. They need to be listed with the rest in
⌘/ and lose to the app's bindings.

## 5. Memory — the ADR-0003 question

`phys_footprint`, MiB, six panes on the fixture page, 12 s after load.

| stage | per pane WebContent | extension WebContent | Networking | GPU | app | **total** |
|---|---|---|---|---|---|---|
| baseline: no controller | 12.3, 12.4, 12.3, 12.4, 12.3, 12.3 (**12.3**) | — | 6.7 | 14.4 | 23.0 | **118.2** |
| controller + Dark Reader, 0 panes | — | 14.9 | 8.8 | 7.0 | 20.3 | 51.0 |
| Dark Reader, 6 panes, granted | 18.7, 18.5, 18.7, 16.4, 16.4, 16.4 (**17.5**) | 28.8 | 8.4 | 14.2 | 27.2 | **183.7** |
| Dark Reader, 1 pane, popup opened once | 21.7 | 56.3 | 8.2 | 13.0 | 41.5 | 140.7 |
| Refined GitHub, 1 pane on github.com | 149.0 | 14.9 | 11.0 | 16.4 | 22.2 | 213.3 |

- **+5.2 MB per pane** for Dark Reader on a trivial page. Its dynamic engine
  puts nine stylesheets and a MutationObserver in every page, so it is likely at
  the heavy end; the mini extension was not measured this way.
- **One extension process**, not one per extension page. The popup opened into
  the background worker's process: still exactly one non-pane WebContent, at
  56 MB instead of 29, measured 1.5 s after `closePopup`, so closing it does
  not give the memory back promptly.
- **The fixed cost is ~30 MB** for one loaded extension with pages talking to it.
- At spike M1's 130-pane extrapolation, Dark Reader alone is **~680 MB** of pane
  memory on top of the ~30 MB fixed. Extensions belong in ADR-0003's accounting:
  each enabled one raises the per-pane number the eviction thresholds were set
  from.
- Refined GitHub's 149 MB pane is github.com; a run of this spike where it did
  not inject (the private-store mistake) had the same page at 124 MB. One sample
  each, so read it as "on the order of 25 MB for that extension on that page".

## 6. Second sample: Refined GitHub

Loaded the same way, with its two host patterns granted. On
`https://github.com/ddrscott/max-pane` at 656 pt, `<html>` had class
`rgh-unread-anywhere` 440 ms after the page finished loading. Its content
script runs; whether each of its features survives a 656 pt layout is a
question for a feature, not this spike.

---

## What this decided

**Go**, in this shape:

- **Behind `#available(macOS 15.4, *)`**, floor unchanged. On macOS 14 the
  settings section says "Extensions need macOS 15.4" and nothing else exists.
- **One `WKWebExtensionController` per profile**, `Configuration(identifier:)`
  with a UUID derived from the profile's salt the way `DataStorePool` derives its
  stores, so extension storage is per profile and the default profile's is
  stable. Every pane's `WKWebViewConfiguration` gets `webExtensionController`;
  a popup's configuration is copied from its opener's and inherits it.
- **`<profile>/extensions/<dir>/`** holds unpacked extensions; each directory is
  one `WKWebExtension(resourceBaseURL:)`. No store, no installer: the user
  unzips a Chrome build there, which is what this spike did. `load` it, grant
  its manifest `permissions`, then `loadBackgroundContent`, at launch.
- **Each web pane is a `WKWebExtensionTab`; the strip is one
  `WKWebExtensionWindow`.** Docked lanes are tabs of the same window. The tab
  protocol is entirely optional methods; `webView(for:)`, `url(for:)`,
  `title(for:)`, `isLoadingComplete(for:)`, `size(for:)`, `indexInWindow(for:)`,
  `isSelected(for:)` and the window's `tabs`/`activeTab` were enough for Dark
  Reader's popup to know which site it was on.
- **Private lanes** report `isPrivate(for:)` true and the context keeps
  `hasAccessToPrivateData` false unless a per-extension setting says "Allow in
  private lanes".
- **Host access asks go through `WebAskCenter`** from
  `promptForPermissionToAccess urls:`, per origin, remembered like the others.
- **Browser actions live at the right end of the address bar**, one 16 pt button
  per enabled extension, `action.icon(for:)` with `badgeText` over it. Click →
  `performAction(for: tab)` → `presentActionPopup` → `popupPopover.show(relativeTo:
  button.bounds, of: button, preferredEdge: .maxY)`. An action without a popup
  shows its `menuItems`. 276 × 580 fits; a popover is its own window, so a wider
  popup overhangs the lane rather than being clipped.
- **Settings** gets an `// EXTENSIONS` section: each directory found, on/off,
  its host-access state, "Allow in private lanes", and the line "about 5 MB per
  open page each", because that is what was measured.
- **Commands** are matched with `context.command(for:)` after the app's own
  shortcuts, never before, and listed in ⌘/.

## What it did not measure

- Anything on macOS 14. The guard is the argument; the machine does not exist here.
- Safari-packaged extensions (`extensionWithAppExtensionBundle:`), Manifest V2,
  or `declarativeNetRequest` — neither sample has content-modification rules,
  and the blocking task already covers what those do.
- Extension storage persisting across launches; the controller configuration
  was `nonPersistent()` so each run was a first install.
- `promptForPermissionMatchPatterns` — never raised. Refined GitHub's optional
  `*://*/*` would be the way to provoke it, from its Options page.
- Per-pane cost with two or more extensions loaded, or with real pages; the
  fixture is a paragraph and two cards.
- Whether the popover, a separate window, survives the strip scrolling under it
  or the gallery transform. In a browser it dismisses on scroll; here it should.
