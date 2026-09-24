# ADR 0038 — The update lane: a daily check, `↻` in the bar, brew in a lane, and a relaunch that inherits nothing

**Status:** Accepted · 2026-09-23
**Decides:** how the app learns a release is out and how often; where that
is shown; what Help › Update… runs and where; what happens when it exits;
how the app is relaunched and with what environment; what happens without
Homebrew; what relay-tty's minimum is checked against.
**Evidence:** the Omarchy critique [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F7;
the work item [`docs/work/omarchy-f7-update-lane.md`](../work/omarchy-f7-update-lane.md);
`AppUpdate.swift`, `Changelog.swift` (`SemanticVersion`), `Views/StatusBar.swift`,
`Views/ChangelogPopup.swift`, `Terminal/TerminalPaneController.swift`
(`ReconnectingBanner.action`), `Views/StripViewController.swift` (`holdExit`);
`AppUpdateTests.swift`; the project memory *Never launch MaxPane from Claude*.

## The problem

The corner knew what this build was (ADR for the version corner: it reads
the bundled changelog) and nothing knew what the newest release was. A
release was learnt of on GitHub, in a browser; the upgrade was typed
somewhere by hand; the relaunch was a Dock click — and the one place the
owner is usually typing is a terminal inside a Claude session, from which a
launch inherits `CLAUDE_CODE_CHILD_SESSION` into every pane and breaks
every `claude` started in one. Omarchy puts a circle arrow on the bar when a
release is ready and an *Update* entry in its menu that does the work.

## Decisions

**The feed is GitHub's `releases/latest`, read once a day and on Help ›
Check for Updates…, with an `ETag`.** No auth; the unauthenticated limit is
sixty an hour and a day needs one. The clock is looked at every hour so a
week-long session still rolls over. What came back — the release, the
`ETag`, the time — is kept in `UserDefaults`, not the ledger: it is a cache
of someone else's fact, and yesterday's answer is on screen from the first
frame. A failure (offline, metered, rate-limited, a body with no release) is
**one line in the log and nothing on screen**, and is not retried until
tomorrow or until asked; after an explicit Check for Updates… the popover
says the one line, because then the question was asked.

**Newer is decided by `SemanticVersion`, the ordering the changelog's
sections now share.** `0.10.0` is newer than `0.9.0`, a string sort is not
consulted, a `v` and build metadata are dropped, and a prerelease precedes
its release. A build from `main` past the release — the corner's `+N` —
reads as current: no `↻` for a release you are already ahead of.

**`↻ v0.8.0` at the right of the status bar, in the accent, and the same as
the first line of the version popover.** The accent is the corner's `+N`
colour: news about the build, not the state of anything, so not a green
that means BLOCKED and not the orange that means DONE. It fades in and out
like the speaker. A click is Help › Update…. The popover gets a
`// UPDATE` block above the changelog — the release as a clickable line, or
`up to date · v0.7.0 is the latest release · checked 3 hours ago`, or the
one error line — and the Help menu item reads `Update to v0.8.0…` once the
check has a name for it.

**Update… runs in a terminal lane the app spawns, beside the focused lane,
and the lane outlives its exit.** The line is `update_command` from
`config.toml` when set, else `brew upgrade --cask max-pane` — the shipped
path — through `LocalSpawner`'s shell-line door, the one ⌘O uses, in the
home directory. The owner watches it, and its output is where a failure is
explained. A terminal pane normally closes itself 0.45 s after its EXIT
frame; the update lane's session is **held** (`StripViewController.holdExit`,
placed before the lane exists, since `true` exits before a pane is built)
and its exit status is handed back instead. Exit 0 puts `UPDATED · EXIT 0`
with a `$ RELAUNCH` button on the pane's banner; anything else puts `UPDATE
FAILED · EXIT n · ⌘W closes this lane` and no button, with the output above
it. Nothing is exported first: the ledger is the truth and ADR-0036 brings
the window back.

**Relaunch is a detached `/bin/sh` with a built environment, then
`NSApp.terminate`.** The helper polls `kill -0 <pid>` every 0.2 s until this
process is gone — so there are never two instances on one ledger — then
`exec open -n <bundle>`, the same path brew has just replaced. It gives up
after sixty seconds rather than launching a minute later behind whatever the
owner is doing by then. **Its environment is not inherited.** `open` passes
its environment to the app it launches, and this process may carry
`CLAUDE_CODE_CHILD_SESSION` from a Claude session's Bash tool or
`ANTHROPIC_API_KEY` from an rc file; every pane of the new instance would
inherit them. The helper starts with `HOME`, `USER`, `LOGNAME`, `SHELL`,
`TMPDIR`, `LANG`, `SSH_AUTH_SOCK` and `__CF_USER_TEXT_ENCODING` when this
process has them, `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, and nothing else —
the orchestrator's own recipe for a clean launch. The quit goes through
`NSApp.terminate`, so pane state is flushed as for ⌘Q.

**Without Homebrew, the release page in a web lane, and one dialog saying
so.** `update_command` unset and no `brew` on the login shell's `PATH` is a
DMG install; Update… opens the release's own page (or the releases list
when no check has run) beside the focused lane and says why in one
`ConfirmPopup`, naming `update_command` as the way to make it a lane.

**relay-tty's minimum is checked on the same tick, from `relay --version`.**
README › Requirements says 1.22.0, the release that added agent state, and
an older one starts sessions and never says BLOCKED with nothing saying why.
The reading is taken off the main thread beside the feed; when it is short,
the bar reads `↻ relay-tty 1.22.0` if there is no release to name (a click
opens the popover), the `↻`'s tooltip carries the line, and the popover's
update block says `relay-tty 1.20.0 is installed · 1.22.0 or newer is needed
for BLOCKED`. Not found, or found and mute, is not "short": the spawner says
that, loudly, at the first lane.

**Refused.** Sparkle: a framework, a signing key and an appcast for what is
one HTTP GET and one brew line, in an app whose install path is Homebrew. A
background download: the upgrade is watched in a lane, where its output is,
and a download the owner did not see is a bundle he cannot vouch for. A
silent relaunch: the strip is his desk, with agents on it; it goes away when
he says. Sparkle's `SUFeedURL`-style autodiscovery of channels: one channel,
`latest`.

## Consequences

- Two Help-menu commands with no default key, `Check for Updates…` and
  `Update…`, rebindable under `[keys]`, in the ⌘/ sheet and ⌘E by name.
  `Update…` is always live; `Check for Updates…` greys with *no update
  check in this build* under `swift run`, where the app delegate that
  starts the checker has not.
- One config key, `update_command`, under Terminals & sessions, read when
  Update… is chosen.
- The checker is started by the app delegate after the window is shown,
  never by the window controller, so a window built in a test runner
  reaches no feed. Every test injects the feed, the clock and the memory.
- `ReconnectingBanner` gained an `action` state with a button; the strip
  wires `onSessionExit` for a terminal controller a test's factory built,
  so the hold is tested on the real path with a fake attachment.
- `SemanticVersion` lives in `Changelog.swift` and `Changelog.Section` reads
  its heading through it. Nothing in the popover's ordering changed — the
  file is already newest first — but the two can no longer disagree.
