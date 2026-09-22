# The version in the corner is true, says `+N` for unreleased changes, and opens the changelog

The owner (2026-09-22): *"the app version in the corner never updates … keep
that synced with the change log and add `+$number` for number of unreleased
features if we're running an unreleased version. Also would be nice to click
the version number to get a list of changes from the log."*

## What is true today

- The sidebar's bottom-left reads `v0.6.1 17/18 SESSIONS`; the version is
  `CFBundleShortVersionString` from `Info.plist`
  (`SidebarViewController.swift:380`). `Info.plist` and `Cargo.toml` say
  `0.6.1` by hand; `scripts/release.sh` reads the plist for the tag and the DMG
  name. Nothing reads `CHANGELOG.md`, and it is not in the bundle. So a build
  from main with forty unreleased entries says `v0.6.1`, same as the release.
- `CHANGELOG.md` is Keep a Changelog: `## [Unreleased]` with `### Added` /
  `### Changed` / `### Fixed`, then `## [0.6.1] - 2026-09-16` …, and compare
  links at the bottom. One line per entry, curated for users (commit
  `af42193` set that style).

## Acceptance Criteria

- **`build-app.sh` copies `CHANGELOG.md` into `Contents/Resources/`** and
  stamps the bundle with what it was built from: `MaxPaneBuild` keys in
  `Info.plist` for the short commit, the build date, and whether the tree was
  clean (`git describe --always --dirty`). Do it in the script, not by editing
  the checked-in plist; the plist's `CFBundleShortVersionString` stays the
  release number and stays hand-set (release.sh depends on it).
- **A small parser**, `Changelog.swift` in `MaxPaneKit`, pure and tested: reads
  the file into sections (`Unreleased`, then each version with its date), each
  with its categories and one-line entries; tolerant of a missing Unreleased
  section, empty categories, and the link block at the bottom. It does not
  render markdown; entries are plain text with backticks left as-is.
- **The corner reads the truth:**
  - a release build (Unreleased has no entries, or the commit is the tag's):
    `v0.6.1`, as today;
  - an unreleased build: `v0.6.1+40`, where `40` is the count of entries under
    Unreleased, all categories. The owner said "features"; count every entry,
    since a fix is a change he wants to know about too, and say so in the
    README. The `+40` part in the accent green, the version grey as now.
  - a dirty tree adds nothing visible; it is in the tooltip.
  - **Tooltip**: `0.6.1 · 40 unreleased changes · built 2026-09-22 from a8e73d6 (dirty)`.
- **Click the version to see the changes.** A popover anchored to the version,
  in the app's sheet vocabulary (square, mono, `// CAPS` section headers in the
  accent, no bubble), listing the changelog newest first: `// UNRELEASED · 40`
  then `// 0.6.1 · 2026-09-16` and so on, each with its `ADDED` / `CHANGED` /
  `FIXED` groups and their entries, scrollable, Esc or click-away closes.
  Unreleased is expanded; released versions are folded with a count and open on
  a click. Long entries wrap. A `copy` action on the section header copies the
  section as markdown for a release note. If the bundle has no changelog (a
  `swift run` from the package rather than a built app), the popover says so
  in one line instead of being empty.
- **A command**, `showChangelog` ("What's New…", in the Help menu next to the
  ⌘/ sheet, no default key), opens the same popover, so it is reachable from
  the keyboard and the ⌘/ sheet lists it.
- **Sync with release:** a line in the README's release section and in
  `scripts/release.sh`'s comments stating the contract: the changelog's top
  released version must equal the plist version, and `release.sh` refuses if
  it does not (it already refuses on a dirty tree; add this check beside it).
  That is what keeps the corner and the changelog in step at release time.
- Tests: the parser on the real `CHANGELOG.md` (entry counts per section match
  a hand count of the current file at the time of writing; do not hard-code a
  number that will rot, count the file in the test) and on synthetic edge
  cases; the corner text for release/unreleased/dirty; the popover's model
  (order, fold state, copy text); the release.sh check via a shell test in
  `scripts/tests/` if that directory has the pattern.
- README (the sidebar section's version paragraph, the release section),
  CHANGELOG (Added).

## Constraints

- No instant transitions; identity rules; no new colour.
- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it.
