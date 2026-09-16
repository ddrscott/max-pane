# A private (ephemeral) web lane

## Problem
There is no `WKWebsiteDataStore.nonPersistent()` anywhere. Profiles isolate
everything, but "log in to the other account once, then forget it" has no
answer short of a whole profile. Vivaldi's private window is the thing used.

## Acceptance Criteria
- `Command.newPrivateWebLane` (⇧⌘N by default, File menu, bindable) opens a web
  lane whose panes share one non-persistent data store for the life of that
  lane. Closing the lane drops the store. Nothing about its pages — history,
  session blob, passwords save prompts, downloads location aside — reaches the
  ledger; history recording is skipped for these panes and a test proves the
  `pages` table has no row for a private visit.
- The lane header and the address bar mark it clearly with a label chip
  (`PRIVATE`), no colour change beyond the existing grey, per the visual identity
  rules. The ⌘O picker shows the same chip on its lanes.
- ⌘-click from a private pane opens the sibling lane in the same private store,
  not in the profile's store.
- Password fill still works (reads from the store) but never offers to save.
- Relaunch: a private lane is not restored; the ledger never learned it. Record
  the decision in an ADR if `create_lane` in `laned-core` needs a flag for it.
- `DataStorePool` gains a keyed non-persistent store per private lane and
  releases it on lane close; a test asserts the release.

## Relevant Files
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift` (`DataStorePool`, `buildWebView`)
- `swift/MaxPane/Sources/MaxPaneKit/StripStore.swift`, `crates/laned-core`
- `swift/MaxPane/Sources/MaxPaneKit/Commands.swift`, `Views/LaneHeader*.swift`
- History recording path (see README "History")

## Constraints
- Do not model this as a profile; profiles are process-wide and relaunch.
- The pane's eviction/rehydrate path (ADR-0006) must not try to restore a
  private pane from a session blob that was never written.
