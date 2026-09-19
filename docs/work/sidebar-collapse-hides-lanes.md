# Collapsing a sidebar group hides its lanes from the strip

The owner (2026-09-19): *"It would be nice to have an autohide feature if any
server or directory is collapsed in the session bar."*

## Reading of it (the orchestrator's; the owner has been asked to confirm)

The sidebar groups sessions by directory, and now by server, and each group has
a collapse chevron. Today collapsing only folds the rows in the sidebar. The ask
is that collapse means "I am not working on this right now": the lanes of a
collapsed directory or server leave the strip and the gallery, and come back
when the group is expanded. With several projects and a remote server on one
strip, this is how the strip gets back to the lanes that matter this hour.

**Check `docs/work/queue.md` and this file's history for a correction from the
owner before building; if the reading was wrong, the task line will say so.**

## Acceptance Criteria

- Collapsing a directory group, a server's group, or a whole server section in
  the sidebar hides every lane whose sessions belong to it from the strip and
  from the gallery. Expanding brings them back where they were (same order,
  same widths). Nothing is closed, detached, evicted differently, or written to
  a session: the sessions keep running and the lanes keep their place in the
  ledger.
- It is the existing gather machinery turned around, not a second filter
  system: read `Core::gather`, `StripStore.gather/ungather`, `isGathered` and
  ADR-0011's treatment of a gather filter in the gallery, and decide whether
  "hidden groups" is a generalisation of the gather filter (a set of excluded
  tags) or a sibling of it. One ADR (0024) says which and why. Whatever ⌘P,
  attach, a BLOCKED click and `maxpane attach` do today to reach a lane a
  gather hides (`leaveGather(ifItHides:)`), they do for a lane a collapse
  hides: the group expands, then you are there.
- **Persisted** with the collapse state itself (find where `collapsed` is
  stored; if it is not persisted today, it becomes so), so a relaunch comes
  back with the same groups hidden.
- **You can always tell something is hidden.** A collapsed group's header shows
  its lane count and, in the green family, its BLOCKED count, pulsing as any
  BLOCKED does: a hidden lane that needs you still calls for you. The status
  bar says how many lanes are hidden. A mixed lane (panes from two groups) is
  hidden only when every group it belongs to is collapsed.
- **A setting**, `sidebar_collapse_hides_lanes`, default **on** (the owner
  asked for the behaviour), in Settings and `config.toml`, applying live; off
  is today's behaviour exactly.
- Motion: lanes leave and return with the strip's existing column
  open/close (`Motion.lane`, ease-out, nothing under Reduce Motion), and in the
  gallery tiles re-lay themselves out with the existing tile motion. Focus: if
  the focused lane is hidden, focus moves to the nearest visible lane to its
  right, else left, the rule closing a lane uses.
- Web lanes belong to a directory group through their project tag and hide with
  it; an untagged web lane (`-`) is never hidden by a collapse.
- Bookmarks section collapse is unrelated and unchanged.
- Tests: the model (which lanes a set of collapsed groups hides, mixed lanes,
  untagged lanes), persistence, reach-through (attach/⌘P/BLOCKED click expands
  and reveals), the setting off, focus hand-off, counts on the header and the
  status bar. Driven over the control socket where a by-hand check is wanted;
  add `maxpane` ops only if needed and say so.
- README (the sidebar section and the settings reference), CHANGELOG, ADR-0024.

## Constraints

- Same as every task this week: do not quit, replace or launch the installed
  app; build to `MAXPANE_APP=build/verify.app` and do not run it.
- No instant transitions; greens for state, grey at rest.
